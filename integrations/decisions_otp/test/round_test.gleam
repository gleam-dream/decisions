//// What three applications asked of the package: one test per item.

import decisions
import decisions/model
import decisions/occurrence
import decisions/policy
import decisions/store as port_types
import decisions/vocabulary.{
  Approve, Manifest, Person, Recommendation, RuleFired, Rules, Trigger,
}
import decisions/wire
import decisions_otp/backlog
import decisions_otp/isolated
import decisions_otp/live
import decisions_otp/runtime
import decisions_otp/store
import decisions_otp/telemetry
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/set
import gleam/string
import gleam/time/duration
import sinal
import support/lab

fn quick(config: runtime.Config(tx)) -> runtime.Config(tx) {
  runtime.Config(..config, poll: duration.milliseconds(5))
}

fn calls(counter: store.Store, name: String) -> Int {
  store.add(store.handle(counter), "calls", name)
  store.rows(store.handle(counter), "calls")
  |> list.count(fn(pair) { pair.1 == name })
}

fn recommend(s: store.Store, desk, key: String) -> Nil {
  let assert Ok(_) =
    store.transaction(s, lab.recommend(
      desk,
      _,
      key,
      about: lab.ana,
      output: "done",
      by: Rules("rules", "1"),
      score: 1.0,
    ))
  Nil
}

/// Item 1. A desk refusal that is transient is retried without counting;
/// an application failure is counted, waits out its backoff, and is set
/// aside when it keeps failing.
pub fn a_handler_failure_is_acted_on_by_kind_test() {
  lab.quiet()
  let assert Ok(s) =
    store.start(
      store.Config(
        ..store.defaults(),
        retry_backoff: duration.milliseconds(100),
      ),
    )
  let counter = lab.start()
  let busy = lab.desk(lab.point("item1.busy", None), lab.proceeding())
  let broken = lab.desk(lab.point("item1.broken", None), lab.proceeding())
  recommend(s, busy, "busy-1")
  recommend(s, broken, "broken-1")
  // The backoff is kept on the store's clock in whole milliseconds, so the
  // gaps are measured on that clock: a gap read on another clock can be
  // a millisecond short through rounding.
  let times = process.new_subject()
  let tree =
    lab.start_runtime(
      runtime.config(
        store.backlog(s),
        points: [
          runtime.point(busy, settled: fn(tx, known) {
            case calls(counter, "busy") <= 6 {
              True ->
                Error(
                  decisions.DeskRefused(
                    decisions.StoreFailed(port_types.Contended("busy")),
                  ),
                )
              False -> {
                store.add(tx, "followed", known.id)
                Ok(Nil)
              }
            }
          }),
          runtime.point(broken, settled: fn(_, _) {
            process.send(times, wire.milliseconds(store.now(s)))
            Error(decisions.ApplicationFailed("the mail server is down"))
          }),
        ],
        work: fn(_) { Ok(Nil) },
      )
      |> fn(config) { runtime.Config(..config, attempts: 3) }
      |> quick,
    )
  assert lab.wait_until(
    fn() { store.count(store.handle(s), "followed") == 1 },
    within: 5000,
  )
  let assert Ok(first) = process.receive(times, 2000)
  let assert Ok(second) = process.receive(times, 2000)
  let assert Ok(third) = process.receive(times, 2000)
  assert lab.wait_until(
    fn() { list.length(result.unwrap(store.backlog(s).aside(), [])) == 1 },
    within: 2000,
  )
  lab.stop_runtime(tree)
  // Six transient refusals did not set the busy notice aside; the broken
  // one waited 100 ms, then 200 ms, between its attempts, on the store's
  // clock (each attempt started at least the backoff after the previous
  // one's failure was counted, which came after that attempt started).
  assert second - first >= 100
  assert third - second >= 200
  let assert Ok([backlog.Aside(job: backlog.NoticeJob(_), attempts: 3, ..)]) =
    store.backlog(s).aside()
}

/// Item 2. A point's occurrences, and those settled since a time, in
/// pages.
pub fn occurrences_are_read_in_pages_test() {
  let s = lab.start()
  let automatic = lab.desk(lab.point("item2.auto", None), lab.proceeding())
  let asked = lab.desk(lab.point("item2.asked", None), lab.asking("finance"))
  list.each(lab.numbers(1, 25), fn(n) {
    recommend(s, automatic, "a-" <> pad(n))
  })
  recommend(s, asked, "q-1")
  let all =
    pages(
      fn(after) {
        store.occurrences_of(store.handle(s), "item2.auto", after:, limit: 10)
      },
      None,
      [],
    )
  assert list.length(all) == 25
  assert list.unique(all) == all
  store.advance(s, duration.seconds(1))
  let midway = store.now(s)
  store.advance(s, duration.seconds(1))
  let assert Ok(_) =
    store.transaction(s, lab.open_and_decide(asked, _, "q-1", lab.bia, Approve))
  let since =
    pages(
      fn(after) {
        store.settled_since(
          store.handle(s),
          "item2.asked",
          since: midway,
          after:,
          limit: 1,
        )
      },
      None,
      [],
    )
  assert since == ["q-1"]
  let all_settled =
    pages(
      fn(after) {
        store.settled_since(
          store.handle(s),
          "item2.auto",
          since: midway,
          after:,
          limit: 7,
        )
      },
      None,
      [],
    )
  assert all_settled == []
}

fn pages(
  read: fn(option.Option(store.Cursor)) -> store.Page,
  after: option.Option(store.Cursor),
  so_far: List(String),
) -> List(String) {
  let page = read(after)
  let so_far = list.append(so_far, page.ids)
  case page.next {
    Some(next) -> pages(read, Some(next), so_far)
    None -> so_far
  }
}

fn pad(n: Int) -> String {
  case n < 10 {
    True -> "0" <> int.to_string(n)
    False -> int.to_string(n)
  }
}

/// Item 4. The runtime's events carry its name.
pub fn events_carry_the_runtime_s_name_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("item4.auto", None), lab.proceeding())
  let seen = process.new_subject()
  let attachment =
    sinal.observe(telemetry.settlement_delivered(), fn(_, about) {
      process.send(seen, about)
    })
  let tree =
    lab.start_runtime(
      runtime.Config(
        ..runtime.config(
          store.backlog(s),
          points: [runtime.point(desk, settled: runtime.nothing_follows)],
          work: fn(_) { Ok(Nil) },
        ),
        name: "moderation",
      )
      |> quick,
    )
  recommend(s, desk, "n-1")
  let assert Ok(about) = wait_for(seen, "n-1")
  let _ = sinal.detach(attachment)
  lab.stop_runtime(tree)
  assert about.source == "moderation"
}

fn wait_for(
  seen: process.Subject(telemetry.About),
  occurrence: String,
) -> Result(telemetry.About, Nil) {
  case process.receive(seen, 2000) {
    Ok(about) if about.occurrence == occurrence -> Ok(about)
    Ok(_) -> wait_for(seen, occurrence)
    Error(Nil) -> Error(Nil)
  }
}

/// Item 5. The store as a child of the application's tree, reached by
/// name. Its exit restarts an empty store, and a fresh handle reaches it.
pub fn the_store_is_a_supervised_child_test() {
  lab.quiet()
  let name = store.new_name("item5_store")
  let reply = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(started) =
      supervisor.new(supervisor.RestForOne)
      |> supervisor.add(store.supervised(store.defaults(), named: name))
      |> supervisor.start
    process.send(reply, started.pid)
    process.sleep_forever()
  })
  let assert Ok(tree) = process.receive(reply, 5000)
  let assert Ok(s) = store.named(name)
  store.put(store.handle(s), "t", "k", "v")
  assert store.get(store.handle(s), "t", "k") == Ok("v")
  lab.kill(store.owner(s))
  assert lab.wait_until(
    fn() {
      case store.named(name) {
        Ok(again) -> store.owner(again) != store.owner(s)
        Error(_) -> False
      }
    },
    within: 2000,
  )
  let assert Ok(again) = store.named(name)
  assert store.get(store.handle(again), "t", "k") == Error(Nil)
  lab.stop_runtime(tree)
}

/// Item 6. The application pauses and resumes its runtime through a
/// control, and finds its children without knowing their numbers.
pub fn the_runtime_is_paused_and_resumed_through_its_control_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("item6.auto", None), lab.proceeding())
  let control = runtime.new_control("item6_runtime")
  let tree =
    lab.start_runtime(
      runtime.Config(
        ..runtime.config(store.backlog(s), points: [], work: fn(submitted) {
          store.transaction(s, lab.recommend(
            desk,
            _,
            submitted.key,
            about: lab.ana,
            output: "done",
            by: Rules("rules", "1"),
            score: 1.0,
          ))
          |> result.replace(Nil)
          |> result.map_error(decisions.DeskRefused)
        }),
        control: Some(control),
        intensity: 10,
        period: 1,
      )
      |> quick,
    )
  let assert Ok(Nil) = runtime.pause(control)
  assert runtime.is_paused(control) == Ok(True)
  let assert Ok(Nil) =
    store.transaction(s, fn(tx) { store.backlog(s).submit(tx, "p-1", "") })
  process.sleep(50)
  assert lab.effects(s, desk) == 0
  let assert Ok(Nil) = runtime.resume(control)
  assert lab.wait_until(fn() { lab.effects(s, desk) == 1 }, within: 2000)
  assert runtime.supervisor_of(control) == Ok(tree)
  let assert Ok(children) = runtime.children_of(control)
  assert list.map(children, fn(pair) { pair.0 })
    |> set.from_list
    == set.from_list([
      runtime.Sweeper,
      runtime.Dispatcher,
      runtime.Worker(1),
      runtime.Worker(2),
      runtime.Worker(3),
      runtime.Worker(4),
    ])
  lab.stop_runtime(tree)
}

/// Item 7. A model's process dies with its caller.
pub fn an_isolated_model_dies_with_its_caller_test() {
  let started = process.new_subject()
  let hangs =
    model.new(fn(_, _) {
      process.send(started, process.self())
      process.sleep_forever()
      Error(model.Declined("unreachable"))
    })
  let caller =
    process.spawn_unlinked(fn() {
      model.run(
        isolated.model(hangs, within: duration.minutes(5)),
        Manifest(refs: [], renderer: "lab-1"),
        model.recorded(context: [], reads: []),
      )
    })
  let assert Ok(model_pid) = process.receive(started, 1000)
  lab.kill(caller)
  assert lab.wait_until(fn() { !process.is_alive(model_pid) }, within: 1000)
}

/// Item 8. A precondition checked inside the recommending transaction.
pub fn a_precondition_that_fails_recommends_nothing_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("item8.auto", None), lab.proceeding())
  let request = fn(key) {
    isolated.Request(
      source: "item8",
      key:,
      trigger: Trigger("lab", key),
      about: lab.ana,
      context: Manifest(refs: [], renderer: "lab-1"),
      sources: model.recorded(context: [], reads: []),
    )
  }
  let sound =
    model.new(fn(_, _) {
      Ok(Recommendation("ok", Rules("r", "1"), RuleFired("r"), [], []))
    })
  // The precondition reads the store in the same transaction.
  let latest = fn(key) {
    fn(tx) {
      case store.get(tx, "latest", "ana") {
        Ok(found) if found == key -> Ok(Nil)
        _ -> Error("a later trigger arrived about ana")
      }
    }
  }
  store.put(store.handle(s), "latest", "ana", "t-2")
  let assert Ok(isolated.Skipped(_)) =
    isolated.recommend_when(
      desk,
      in: store.transaction(s, _),
      request: request("t-1"),
      model: sound,
      holds: latest("t-1"),
    )
  let assert Ok(isolated.Recommended(_)) =
    isolated.recommend_when(
      desk,
      in: store.transaction(s, _),
      request: request("t-2"),
      model: sound,
      holds: latest("t-2"),
    )
  assert store.occurrences_of(
      store.handle(s),
      "item8.auto",
      after: None,
      limit: 10,
    ).ids
    == ["t-2"]
}

/// Item 9. A subscriber that dropped hints is told so, even when nothing
/// changes after.
pub fn missed_hints_are_reported_without_another_change_test() {
  lab.quiet()
  let assert Ok(s) = store.start(store.Config(..lab.config(), hint_capacity: 2))
  let desk = lab.desk(lab.point("item9", None), lab.asking("finance"))
  let subscribed = process.new_subject()
  let reports = process.new_subject()
  let subscriber =
    process.spawn_unlinked(fn() {
      let hints = process.new_subject()
      let asks = process.new_subject()
      let assert Ok(_) = store.subscribe(s, live.ToPoint("item9"), hints)
      process.send(subscribed, asks)
      let assert Ok(Nil) = process.receive(asks, 5000)
      // Read the two that fitted, then wait for the report of the rest.
      let assert Ok(_) = process.receive(hints, 100)
      let assert Ok(_) = process.receive(hints, 100)
      process.send(reports, process.receive(hints, 1000))
    })
  let assert Ok(asks) = process.receive(subscribed, 1000)
  list.each(["m-1", "m-2", "m-3", "m-4"], fn(key) { recommend(s, desk, key) })
  process.send(asks, Nil)
  assert process.receive(reports, 2000) == Ok(Ok(live.Missed(2)))
  lab.kill(subscriber)
}

/// Item 10. A trigger is handed out once when nothing fails: 300
/// triggers, eight workers, 300 deliveries and 300 `trigger_worked`.
pub fn a_trigger_is_worked_once_test() {
  let s = lab.start()
  let counter = lab.start()
  let worked = process.new_subject()
  let attachment =
    sinal.observe(telemetry.trigger_worked(), fn(_, about) {
      process.send(worked, about.occurrence)
    })
  let assert Ok(Nil) =
    store.transaction(s, fn(tx) {
      list.try_each(lab.numbers(1, 300), fn(n) {
        store.backlog(s).submit(tx, "w-" <> int.to_string(n), "")
      })
    })
  let tree =
    lab.start_runtime(
      runtime.Config(
        ..runtime.config(store.backlog(s), points: [], work: fn(_) {
          let _ = calls(counter, "work")
          Ok(Nil)
        }),
        workers: 8,
      )
      |> quick,
    )
  let reported = collect(worked, 300, [])
  process.sleep(50)
  lab.stop_runtime(tree)
  let _ = sinal.detach(attachment)
  assert list.length(reported) == 300
  assert list.length(list.unique(reported)) == 300
  assert calls(counter, "work") == 301
}

fn collect(
  subject: process.Subject(String),
  count: Int,
  so_far: List(String),
) -> List(String) {
  case count {
    0 -> so_far
    _ ->
      case process.receive(subject, 5000) {
        Ok(key) -> collect(subject, count - 1, [key, ..so_far])
        Error(Nil) -> so_far
      }
  }
}

/// Item 11. The review queue is indexed and has a topic.
pub fn the_review_queue_has_a_topic_and_an_index_test() {
  let s = lab.start()
  // Proceed and sample every one.
  let desk = lab.desk(lab.point("item11", None), lab.scoring(100))
  let hints = process.new_subject()
  let assert Ok(_) = store.subscribe(s, live.ToReviews("item11"), hints)
  recommend(s, desk, "r-1")
  let assert Ok(live.Changed(occurrence: "r-1", ..)) =
    process.receive(hints, 500)
  assert store.review_queue_of(store.handle(s), "item11", 10) == ["r-1"]
  assert store.review_queue(store.handle(s)) == ["r-1"]
}

/// The default attempt limit is the PostgreSQL runtime's.
pub fn the_default_attempt_limit_is_twenty_test() {
  let s = lab.start()
  let config =
    runtime.config(store.backlog(s), points: [], work: fn(_) { Ok(Nil) })
  assert config.attempts == 20
}

/// A wake-up whose policy step consults a point the desk has no handler
/// for is counted and set aside, not delivered for ever.
pub fn a_wake_up_that_cannot_consult_is_set_aside_test() {
  let s = lab.start()
  let desk =
    lab.desk(
      lab.point("review.consulting", None),
      policy.Policy(
        version: 1,
        rules: [policy.When(policy.waited(60), policy.Consult("other.point"))],
        otherwise: policy.Ask(policy.AnyoneHolding("finance")),
      ),
    )
  recommend(s, desk, "c-1")
  store.advance(s, duration.minutes(61))
  let tree =
    lab.start_runtime(
      runtime.Config(
        ..runtime.config(
          store.backlog(s),
          points: [runtime.point(desk, settled: runtime.nothing_follows)],
          work: fn(_) { Ok(Nil) },
        ),
        attempts: 3,
      )
      |> quick,
    )
  assert lab.wait_until(
    fn() { result.unwrap(store.backlog(s).aside(), []) != [] },
    within: 5000,
  )
  lab.stop_runtime(tree)
  let assert Ok([
    backlog.Aside(job: backlog.WakeJob(_), attempts: 3, reason:, ..),
  ]) = store.backlog(s).aside()
  assert string.contains(reason, "other.point")
}

/// A wake-up whose gated tool answers `Unsure` is delivered again after a
/// backoff, and releases once the tool can tell.
pub fn a_wake_up_meeting_an_unsure_tool_is_backed_off_and_releases_test() {
  let s = lab.start()
  let counter = lab.start()
  let point = lab.point("review.unsure", Some(duration.minutes(1)))
  let desk =
    decisions.desk(
      point,
      drives: fn(_) {
        decisions.Gated(
          name: "send",
          guard: fn(_, _) { Ok([]) },
          execute: fn(tx, released) {
            case calls(counter, "send") <= 2 {
              True -> Error(decisions.Unsure("the provider did not answer"))
              False -> {
                store.add(tx, "review.unsure", decisions.key(released))
                Ok(Nil)
              }
            }
          },
        )
      },
      under: fn(_) { Ok(lab.proceeding()) },
      over: store.port(),
    )
  let assert Ok(_) =
    store.transaction(s, lab.recommend(
      desk,
      _,
      "u-1",
      about: lab.ana,
      output: "Olá",
      by: Person("bia"),
      score: 1.0,
    ))
  store.advance(s, duration.minutes(2))
  let failed = process.new_subject()
  let attachment =
    sinal.observe(telemetry.job_failed(), fn(_, metadata) {
      case metadata.occurrence == "u-1" {
        True -> process.send(failed, metadata.attempts)
        False -> Nil
      }
    })
  let tree =
    lab.start_runtime(
      runtime.config(
        store.backlog(s),
        points: [runtime.point(desk, settled: runtime.nothing_follows)],
        work: fn(_) { Ok(Nil) },
      )
      |> quick,
    )
  assert lab.wait_until(fn() { lab.effects(s, desk) == 1 }, within: 5000)
  lab.stop_runtime(tree)
  let _ = sinal.detach(attachment)
  // Two counted failures, each backed off, then the release.
  assert process.receive(failed, 1000) == Ok(1)
  assert process.receive(failed, 1000) == Ok(2)
  assert store.backlog(s).aside() == Ok([])
  let assert Ok(known) =
    decisions.read(desk, store.handle(s), occurrence: "u-1")
  let assert occurrence.Released(..) = known.status
}
