//// The owner's round: `expect`, a precondition that can say "could not
//// check", a failed model with its evidence, and a lone worker that does
//// not loop on a redelivered trigger.

import decisions
import decisions/entry
import decisions/learning
import decisions/model
import decisions/occurrence
import decisions/store as port_types
import decisions/vocabulary.{
  Manifest, Recommendation, Ref, RuleFired, Rules, Subject, Trigger,
}
import decisions/wire
import decisions_otp/backlog
import decisions_otp/isolated
import decisions_otp/replay
import decisions_otp/runtime
import decisions_otp/store
import decisions_otp/telemetry
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import sinal
import support/lab

fn request(key: String) -> isolated.Request {
  isolated.Request(
    source: "owner_round",
    key:,
    trigger: Trigger("lab", key),
    about: Subject("person", key),
    context: Manifest(refs: [], renderer: "lab-1"),
    sources: model.recorded(context: [], reads: []),
  )
}

fn sound() -> model.Model(String) {
  model.new(fn(_, _) {
    Ok(Recommendation("ok", Rules("r", "1"), RuleFired("r"), [], []))
  })
}

fn calls(counter: store.Store, name: String) -> Int {
  lab.within(counter, store.add(_, "calls", name))
  lab.within(counter, store.rows(_, "calls"))
  |> list.count(fn(pair) { pair.1 == name })
}

/// Issue 01. "Skip this" and "could not check" are told apart.
pub fn a_precondition_says_skip_or_could_not_check_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("owner.skip", None), lab.asking("finance"))
  let assert Ok(isolated.Skipped("a later trigger arrived")) =
    isolated.recommend_when(
      desk,
      in: store.transaction(s, _),
      request: request("k-1"),
      model: sound(),
      holds: fn(_) { Error(isolated.Skip("a later trigger arrived")) },
    )
  let assert Error(decisions.StoreFailed(port_types.Contended("busy"))) =
    isolated.recommend_when(
      desk,
      in: store.transaction(s, _),
      request: request("k-2"),
      model: sound(),
      holds: fn(_) {
        Error(isolated.CouldNotCheck(port_types.Contended("busy")))
      },
    )
  // Neither wrote anything.
  assert store.occurrences_of(s, "owner.skip", after: None, limit: 10).ids == []
}

/// Issue 01, in the runtime: a precondition that could not check is
/// delivered again without counting and then recommends; one that says
/// skip ends its trigger as done.
pub fn the_runtime_retries_a_precondition_that_could_not_check_test() {
  let s = lab.start()
  let counter = lab.start()
  let desk = lab.desk(lab.point("owner.check", None), lab.asking("finance"))
  let work = fn(submitted: backlog.Submitted) {
    let holds = fn(_) {
      case submitted.key, calls(counter, submitted.key) {
        "skip-1", _ -> Error(isolated.Skip("not wanted"))
        _, n if n <= 2 ->
          Error(isolated.CouldNotCheck(port_types.Contended("busy")))
        _, _ -> Ok(Nil)
      }
    }
    case
      isolated.recommend_when(
        desk,
        in: store.transaction(s, _),
        request: request(submitted.key),
        model: sound(),
        holds:,
      )
    {
      Ok(_) -> Ok(Nil)
      Error(refusal) -> Error(decisions.DeskRefused(refusal))
    }
  }
  let assert Ok(Nil) =
    store.transaction(s, fn(tx) {
      use Nil <- result.try(store.backlog(s).submit(tx, "check-1", ""))
      store.backlog(s).submit(tx, "skip-1", "")
    })
  let tree =
    lab.start_runtime(
      runtime.Config(
        ..runtime.config(store.backlog(s), points: [], work:),
        poll: duration.milliseconds(5),
        attempts: 2,
      ),
    )
  assert lab.wait_until(
    fn() {
      store.occurrences_of(s, "owner.check", after: None, limit: 10).ids
      == ["check-1"]
      && store.backlog(s).claim_trigger() == Ok(None)
    },
    within: 5000,
  )
  lab.stop_runtime(tree)
  // Two contended checks with two attempts allowed: not counted, so not
  // set aside.
  assert store.backlog(s).aside() == Ok([])
}

/// Issue 02. A failed model's evidence travels to the attempt on the
/// record.
pub fn a_failed_model_s_evidence_is_on_the_attempt_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("owner.evidence", None), lab.asking("finance"))
  let exchange = Ref("provider.exchange", "e-1", "1")
  let undecodable =
    model.new(fn(_, _) {
      Error(model.with_evidence(model.Undecodable("not json"), [exchange]))
    })
  let assert Ok(isolated.Failed(failure:, attempts: [attempt])) =
    isolated.recommend(
      desk,
      in: store.transaction(s, _),
      request: request("ev-1"),
      model: isolated.model(
        undecodable,
        within: duration.seconds(1),
        heap: lab.heap(),
      ),
    )
  assert model.evidence_of(failure) == [exchange]
  assert attempt.evidence == [exchange]
  let assert Error(decisions.NotRecommended(attempts: [recorded])) =
    store.transaction(s, decisions.read(desk, _, occurrence: "ev-1"))
  assert recorded.evidence == [exchange]
}

/// `expect` with `isolated.recommend`: a key superseded before its model
/// answered is `Superseded`, and nothing is written.
pub fn a_key_superseded_before_it_is_recommended_is_superseded_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("owner.expect", None), lab.asking("finance"))
  let about = Subject("person", "ex-1")
  let assert Ok(Nil) =
    store.transaction(s, decisions.expect(
      desk,
      _,
      key: "ex-1",
      trigger: Trigger("lab", "ex-1"),
      about:,
    ))
  let assert Ok(_) =
    store.transaction(s, decisions.happened(desk, _, "superseded", about:))
  let assert Ok(isolated.Superseded(event: "superseded")) =
    isolated.recommend(
      desk,
      in: store.transaction(s, _),
      request: isolated.Request(..request("ex-1"), about:),
      model: sound(),
    )
  assert store.queue(s, "finance") == []
}

/// `expect_until` with `isolated.recommend`: after the key's own deadline a
/// failed model is `Lapsed` and nothing is written; a model that answers
/// late is recorded, already expired.
pub fn a_key_past_its_own_deadline_is_lapsed_or_recorded_expired_test() {
  let s = lab.start()
  let desk =
    lab.desk(lab.point("owner.own-deadline", None), lab.asking("finance"))
  let deadline =
    timestamp.add(store.now(s), duration.minutes(1))
    |> wire.milliseconds
    |> wire.from_milliseconds
  list.each(["od-1", "od-2"], fn(key) {
    let assert Ok(Nil) =
      store.transaction(s, decisions.expect_until(
        desk,
        _,
        key:,
        trigger: Trigger("lab", key),
        about: Subject("person", key),
        valid_until: deadline,
      ))
  })
  store.advance(s, duration.minutes(2))
  let before = store.transaction(s, decisions.read_record(desk, _, key: "od-1"))
  let failing = model.new(fn(_, _) { Error(model.Raised("down")) })
  let assert Ok(isolated.Lapsed(deadline: at)) =
    isolated.recommend(
      desk,
      in: store.transaction(s, _),
      request: request("od-1"),
      model: failing,
    )
  assert at == deadline
  // Nothing was written for the late failure.
  assert store.transaction(s, decisions.read_record(desk, _, key: "od-1"))
    == before
  let assert Ok(isolated.Recommended(late)) =
    isolated.recommend(
      desk,
      in: store.transaction(s, _),
      request: request("od-2"),
      model: sound(),
    )
  assert late.status == occurrence.Expired(vocabulary.DeadlinePassed)
  assert store.queue(s, "finance") == []
}

/// A record shaped expected, expired, recommended (the wake-up came before
/// the late model) exports as an example and replays in parallel: it
/// starts expired, so nothing was let through and it is not judged.
pub fn a_late_recommendation_replays_as_unjudged_test() {
  let s = lab.start()
  let desk =
    lab.desk(lab.point("owner.late-replay", None), lab.asking("finance"))
  let deadline =
    timestamp.add(store.now(s), duration.minutes(1))
    |> wire.milliseconds
    |> wire.from_milliseconds
  let assert Ok(Nil) =
    store.transaction(s, decisions.expect_until(
      desk,
      _,
      key: "lr-1",
      trigger: Trigger("lab", "lr-1"),
      about: Subject("person", "lr-1"),
      valid_until: deadline,
    ))
  store.advance(s, duration.minutes(2))
  let assert Ok(decisions.LapsedBefore(_)) =
    store.transaction(s, decisions.wake(desk, _, occurrence: "lr-1"))
  let assert Ok(isolated.Recommended(late)) =
    isolated.recommend(
      desk,
      in: store.transaction(s, _),
      request: request("lr-1"),
      model: sound(),
    )
  let assert ["expected", "expired", "recommended"] =
    list.map(late.entries, fn(e) { entry.kind(e.event) })
  let archive =
    learning.Archive(
      render: fn(_) { Ok("prompt") },
      reads: fn(_) { [] },
      content: fn(_) { Ok("") },
    )
  let assert Ok(example) =
    learning.example(late, as_of: store.now(s), from: archive)
  assert replay.replay(
      [example, example],
      sound(),
      same: fn(a, b) { a == b },
      across: 2,
    )
    == learning.Replay(tally: learning.nothing, unanswered: [])
}

/// A worker whose `recommend_once` meets `SupersededBefore` drops the
/// trigger as done, and the event says why.
pub fn a_worker_drops_a_trigger_superseded_before_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("owner.dropped", None), lab.asking("finance"))
  let about = Subject("person", "dr-1")
  let assert Ok(Nil) =
    store.transaction(s, fn(tx) {
      use Nil <- result.try(
        decisions.expect(
          desk,
          tx,
          key: "dr-1",
          trigger: Trigger("lab", "dr-1"),
          about:,
        )
        |> result.map_error(decisions.describe),
      )
      store.backlog(s).submit(tx, "dr-1", "")
      |> result.map_error(port_types.describe)
    })
  let assert Ok(_) =
    store.transaction(s, decisions.happened(desk, _, "superseded", about:))
  let dropped = process.new_subject()
  let attachment =
    sinal.observe(telemetry.job_dropped(), fn(_, metadata) {
      // The superseded record's settlement notice goes to the follower,
      // as `NotBegun`; this test is about the trigger.
      case metadata.queue {
        telemetry.TriggerQueue -> process.send(dropped, metadata)
        _ -> Nil
      }
    })
  let work = fn(submitted: backlog.Submitted) {
    store.transaction(s, lab.recommend(
      desk,
      _,
      submitted.key,
      about:,
      output: "late",
      by: Rules("r", "1"),
      score: 0.5,
    ))
    |> result.replace(Nil)
    |> result.map_error(decisions.DeskRefused)
  }
  let tree =
    lab.start_runtime(
      runtime.Config(
        ..runtime.config(
          store.backlog(s),
          points: [runtime.point(desk, settled: runtime.nothing_follows)],
          work:,
        ),
        poll: duration.milliseconds(5),
      ),
    )
  let assert Ok(metadata) = process.receive(dropped, 5000)
  lab.stop_runtime(tree)
  let _ = sinal.detach(attachment)
  assert metadata.occurrence == "dr-1"
  assert metadata.queue == telemetry.TriggerQueue
  assert string.contains(metadata.reason, "superseded")
  assert store.backlog(s).claim_trigger() == Ok(None)
  assert store.backlog(s).aside() == Ok([])
}

/// Issue 16. One worker, one trigger that keeps ending `Redeliver`: the
/// other triggers are worked, and the stuck one's deliveries are spaced
/// by at least two polls.
pub fn a_lone_worker_does_not_loop_on_a_redelivered_trigger_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("owner.lone", None), lab.proceeding())
  let tries = process.new_subject()
  let work = fn(submitted: backlog.Submitted) {
    case submitted.key {
      "stuck" -> {
        process.send(tries, monotonic_us() / 1000)
        Error(
          decisions.DeskRefused(
            decisions.StoreFailed(port_types.Contended("busy")),
          ),
        )
      }
      key ->
        store.transaction(s, lab.recommend(
          desk,
          _,
          key,
          about: lab.ana,
          output: "ok",
          by: Rules("r", "1"),
          score: 1.0,
        ))
        |> result.replace(Nil)
        |> result.map_error(decisions.DeskRefused)
    }
  }
  let assert Ok(Nil) =
    store.transaction(s, fn(tx) {
      use Nil <- result.try(store.backlog(s).submit(tx, "stuck", ""))
      list.try_each(lab.numbers(1, 5), fn(n) {
        store.backlog(s).submit(tx, "t-" <> int.to_string(n), "")
      })
    })
  let tree =
    lab.start_runtime(
      runtime.Config(
        ..runtime.config(
          store.backlog(s),
          points: [runtime.point(desk, settled: runtime.nothing_follows)],
          work:,
        ),
        workers: 1,
        poll: duration.milliseconds(20),
      ),
    )
  assert lab.wait_until(fn() { lab.effects(s, desk) == 5 }, within: 5000)
  // Watch a few more redeliveries of the stuck one.
  let times = collect(tries, 4, [])
  lab.stop_runtime(tree)
  assert list.length(times) == 4
  list.window_by_2(list.reverse(times))
  |> list.each(fn(pair) {
    assert pair.1 - pair.0 >= 40
  })
  assert store.backlog(s).aside() == Ok([])
}

fn collect(
  subject: process.Subject(Int),
  count: Int,
  so_far: List(Int),
) -> List(Int) {
  case count {
    0 -> so_far
    _ ->
      case process.receive(subject, 5000) {
        Ok(at) -> collect(subject, count - 1, [at, ..so_far])
        Error(Nil) -> so_far
      }
  }
}

@external(erlang, "decisions_otp_ffi", "monotonic_us")
fn monotonic_us() -> Int
