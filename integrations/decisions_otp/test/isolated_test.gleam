//// Model calls in processes of their own, and replay over processes.

import decisions
import decisions/learning.{Archive}
import decisions/model
import decisions/vocabulary.{
  type Manifest, Approve, Classifier, Manifest, Recommendation, Ref, RuleFired,
  Rules, Trigger, Validator,
}
import decisions_otp/isolated
import decisions_otp/replay
import decisions_otp/store
import decisions_otp/telemetry
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/time/duration
import sinal
import sinal/correlation
import support/lab

fn context() -> Manifest {
  Manifest(refs: [], renderer: "lab-1")
}

pub fn a_model_that_raises_is_raised_and_the_caller_lives_test() {
  let raises = model.new(fn(_, _) { panic as "the model raised" })
  let assert Error(model.Raised(_)) =
    model.run(
      isolated.model(raises, within: duration.seconds(1)),
      context(),
      model.recorded(context: [], reads: []),
    )
}

pub fn a_model_that_hangs_is_killed_at_its_deadline_test() {
  let started = process.new_subject()
  let hangs =
    model.new(fn(_, _) {
      process.send(started, process.self())
      process.sleep_forever()
      Error(model.Declined("unreachable"))
    })
  let before = now_ms()
  let outcome =
    model.run(
      isolated.model(hangs, within: duration.milliseconds(50)),
      context(),
      model.recorded(context: [], reads: []),
    )
  let took = now_ms() - before
  assert outcome == Error(model.Deadline(duration.milliseconds(50)))
  // Not before the deadline. How long after it depends on the machine's
  // load; what holds whatever the load is that the model is gone.
  assert took >= 50
  // The model's process is gone, not left running: `run` returned only
  // after it was seen to exit.
  let assert Ok(pid) = process.receive(started, 0)
  assert !process.is_alive(pid)
}

pub fn the_reads_a_model_received_are_on_its_recommendation_test() {
  let reading =
    model.new(fn(_, sources: model.Sources) {
      use captured <- result.try(sources.read("customer", "ana"))
      Ok(
        Recommendation(
          output: captured.body,
          by: Rules("r", "1"),
          explanation: RuleFired("r"),
          signals: [],
          reads: [],
        ),
      )
    })
  let ref = Ref("customer", "ana", "7")
  let assert Ok(recommendation) =
    model.run(
      isolated.model(reading, within: duration.seconds(1)),
      context(),
      model.recorded(context: [], reads: [#(ref, "Ana")]),
    )
  assert recommendation.output == "Ana"
  assert recommendation.reads == [ref]
}

pub fn a_failed_model_is_recorded_and_reported_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("lab.modelled", None), lab.proceeding())
  let reports = process.new_subject()
  let attachment =
    sinal.observe(telemetry.model_failed(), fn(_, metadata) {
      process.send(reports, metadata)
    })
  let request =
    isolated.Request(
      source: "isolated_test",
      key: "m-1",
      trigger: Trigger("lab", "m-1"),
      about: lab.ana,
      context: context(),
      sources: model.recorded(context: [], reads: []),
    )
  let hangs =
    model.new(fn(_, _) {
      process.sleep_forever()
      Error(model.Declined("unreachable"))
    })
  let assert Ok(isolated.Failed(failure: model.Deadline(_), attempts: [_])) =
    isolated.recommend(
      desk,
      in: store.transaction(s, _),
      request:,
      model: isolated.model(hangs, within: duration.milliseconds(20)),
    )
  let _ = sinal.detach(attachment)
  let assert Ok(report) = process.receive(reports, 100)
  assert report.failure == telemetry.ModelDeadline
  assert report.occurrence == "m-1"
  assert report.correlation == correlation.from_key("m-1")
  let assert Error(decisions.NotRecommended(attempts: [_])) =
    store.transaction(s, decisions.read(desk, _, occurrence: "m-1"))
}

pub fn a_parallel_replay_tallies_as_the_sequential_one_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("lab.replayed", None), lab.asking("support"))
  let dora = Validator("dora", ["support"])
  let known =
    list.map(lab.numbers(1, 400), fn(n) {
      let key = "e-" <> int.to_string(n)
      let assert Ok(_) =
        store.transaction(s, lab.recommend(
          desk,
          _,
          key,
          about: lab.clinica,
          output: case n % 3 {
            0 -> "spam"
            _ -> "ok"
          },
          by: Classifier("moderation", "v1"),
          score: 0.5,
        ))
      let assert Ok(decided) =
        store.transaction(s, lab.open_and_decide(desk, _, key, dora, Approve))
      decided
    })
  let archive =
    Archive(
      render: fn(_) { Ok("prompt") },
      reads: fn(_) { [] },
      content: fn(ref) { Ok(ref.id) },
    )
  let assert Ok(examples) =
    list.try_map(known, learning.example(_, as_of: store.now(s), from: archive))
  // A candidate that says "ok" for every post, and raises on a few.
  let candidate =
    model.new(fn(context: Manifest, _) {
      case context.refs {
        [Ref(id: "e-7", ..)] | [Ref(id: "e-250", ..)] ->
          panic as "the candidate raised"
        _ ->
          Ok(
            Recommendation(
              "ok",
              Rules("candidate", "1"),
              RuleFired("r"),
              [],
              [],
            ),
          )
      }
    })
  let same = fn(a, b) { a == b }
  let sequential = learning.replay(examples, candidate, same:)
  let parallel = replay.replay(examples, candidate, same:, across: 8)
  assert parallel == sequential
  assert sequential.tally.judged == 398
  assert list.map(sequential.unanswered, fn(pair) { pair.0 })
    == ["e-7", "e-250"]
}

pub fn a_bounded_map_keeps_order_and_reports_a_death_test() {
  let results =
    replay.map(lab.numbers(1, 20), 3, fn(n) {
      case n {
        13 -> {
          process.kill(process.self())
          0
        }
        _ -> n * 2
      }
    })
  assert list.length(results) == 20
  let assert Ok(Ok(2)) = list.first(results)
  let assert [Error(_)] = list.filter(results, result.is_error)
}

@external(erlang, "decisions_otp_ffi", "monotonic_us")
fn monotonic_us() -> Int

fn now_ms() -> Int {
  monotonic_us() / 1000
}
