//// The runtime's kill table: each child killed in the middle of its
//// work. What is lost, and what restarts it.

import decisions
import decisions/occurrence
import decisions/store as decisions_store
import decisions/vocabulary.{Approve, Person, Rules}
import decisions_otp/backlog
import decisions_otp/runtime.{Dispatcher, Sweeper, Worker}
import decisions_otp/store.{type Store}
import decisions_otp/telemetry
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration
import sinal
import sinal/correlation
import support/lab

/// Calls of a step, counted outside any transaction in a store of its
/// own, so that a rolled-back transaction does not undo the count.
fn calls(counter: Store, name: String) -> Int {
  store.add(store.handle(counter), "calls", name)
  store.rows(store.handle(counter), "calls")
  |> list.count(fn(pair) { pair.1 == name })
}

fn quick(config: runtime.Config(tx)) -> runtime.Config(tx) {
  runtime.Config(..config, poll: duration.milliseconds(5))
}

/// Killed: the sweeper, inside the transaction that delivers a wake-up,
/// after the gated tool wrote. Lost: that transaction, so the reply is not
/// sent and the wake-up stays due. Restarted by: the supervisor; the new
/// sweeper delivers the wake-up once.
pub fn the_sweeper_killed_mid_delivery_loses_nothing_test() {
  let s = lab.start()
  let counter = lab.start()
  let inside = process.new_subject()
  let desk =
    lab.desk_with(
      lab.point("reply.draft", Some(duration.minutes(2))),
      lab.proceeding(),
      fn(_) {
        case calls(counter, "tool") {
          1 -> {
            process.send(inside, Nil)
            process.sleep_forever()
          }
          _ -> Nil
        }
      },
    )
  let assert Ok(_) =
    store.transaction(s, lab.recommend(
      desk,
      _,
      "reply-1",
      about: lab.ana,
      output: "Olá",
      by: Person("bia"),
      score: 1.0,
    ))
  store.advance(s, duration.minutes(3))
  let tree =
    lab.start_runtime(
      runtime.config(
        store.backlog(s),
        points: [runtime.point(desk, settled: runtime.nothing_follows)],
        work: fn(_) { Ok(Nil) },
      )
      |> quick,
    )
  let assert Ok(Nil) = process.receive(inside, 5000)
  let sweeper = lab.child(tree, Sweeper)
  lab.kill(sweeper)
  assert lab.wait_until(fn() { lab.effects(s, desk) == 1 }, within: 5000)
  assert lab.child(tree, Sweeper) != sweeper
  // The tool ran twice: once in the killed transaction, which left
  // nothing, and once in the new sweeper's. This call is the third.
  assert calls(counter, "tool") == 3
  lab.stop_runtime(tree)
  assert store.wakes(store.handle(s)) == []
  assert lab.effects(s, desk) == 1
}

/// Killed: the dispatcher, inside what follows a settlement. Lost: that
/// transaction; the notice stays undelivered. Restarted by: the
/// supervisor; the notice is delivered once.
pub fn the_dispatcher_killed_mid_delivery_loses_nothing_test() {
  let s = lab.start()
  let counter = lab.start()
  let inside = process.new_subject()
  let desk = lab.desk(lab.point("lab.auto", None), lab.proceeding())
  let follow = fn(tx, known: occurrence.Occurrence(String)) {
    case calls(counter, "follow") {
      1 -> {
        process.send(inside, Nil)
        process.sleep_forever()
      }
      _ -> Nil
    }
    store.add(tx, "followed", known.id)
    Ok(Nil)
  }
  let assert Ok(_) =
    store.transaction(s, lab.recommend(
      desk,
      _,
      "auto-1",
      about: lab.ana,
      output: "done",
      by: Rules("rules", "1"),
      score: 1.0,
    ))
  let tree =
    lab.start_runtime(
      runtime.config(
        store.backlog(s),
        points: [runtime.point(desk, settled: follow)],
        work: fn(_) { Ok(Nil) },
      )
      |> quick,
    )
  let assert Ok(Nil) = process.receive(inside, 5000)
  let dispatcher = lab.child(tree, Dispatcher)
  lab.kill(dispatcher)
  assert lab.wait_until(
    fn() { store.count(store.handle(s), "followed") == 1 },
    within: 5000,
  )
  assert lab.child(tree, Dispatcher) != dispatcher
  let assert Ok([]) = store.backlog(s).undelivered(10)
  process.sleep(30)
  lab.stop_runtime(tree)
  assert store.count(store.handle(s), "followed") == 1
}

/// Killed: a worker, while its model computes. Lost: nothing; the claim
/// on the trigger dies with the worker. Restarted by: the supervisor;
/// another worker takes the trigger, and there is one occurrence.
pub fn a_worker_killed_while_it_works_loses_nothing_test() {
  let s = lab.start()
  let counter = lab.start()
  let inside = process.new_subject()
  let desk = lab.desk(lab.point("lab.auto", None), lab.proceeding())
  let work = fn(submitted: backlog.Submitted) {
    case calls(counter, "work") {
      1 -> {
        process.send(inside, process.self())
        process.sleep_forever()
      }
      _ -> Nil
    }
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
  }
  let assert Ok(Nil) =
    store.transaction(s, fn(tx) { store.backlog(s).submit(tx, "t-1", "") })
  let tree =
    lab.start_runtime(
      runtime.Config(
        ..runtime.config(store.backlog(s), points: [], work:),
        workers: 2,
      )
      |> quick,
    )
  let assert Ok(worker) = process.receive(inside, 5000)
  assert list.any(runtime.children(tree), fn(pair) {
    pair.1 == worker
    && case pair.0 {
      Worker(_) -> True
      _ -> False
    }
  })
  lab.kill(worker)
  assert lab.wait_until(fn() { lab.effects(s, desk) == 1 }, within: 5000)
  process.sleep(30)
  lab.stop_runtime(tree)
  assert store.backlog(s).claim_trigger() == Ok(None)
  assert lab.effects(s, desk) == 1
}

/// Killed: the store's owner. Lost: everything the store held. Restarted
/// by: nobody inside the runtime; its children crash on every start until
/// the supervisor gives up and exits, which hands the decision to the
/// application's supervisor.
pub fn the_store_owner_killed_takes_the_runtime_down_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("lab.auto", None), lab.proceeding())
  let tree =
    lab.start_runtime(
      runtime.config(
        store.backlog(s),
        points: [runtime.point(desk, settled: runtime.nothing_follows)],
        work: fn(_) { Ok(Nil) },
      )
      |> quick,
    )
  let monitor = process.monitor(tree)
  process.unlink(store.owner(s))
  lab.kill(store.owner(s))
  let down =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(10_000)
  assert down == Ok(Nil)
}

/// A verdict while the runtime runs: the settlement is delivered to what
/// follows, after the verdict committed.
pub fn a_verdict_is_followed_once_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("refund", None), lab.asking("finance"))
  let tree =
    lab.start_runtime(
      runtime.config(
        store.backlog(s),
        points: [
          runtime.point(desk, settled: fn(tx, known) {
            store.add(tx, "followed", known.id)
            Ok(Nil)
          }),
        ],
        work: fn(_) { Ok(Nil) },
      )
      |> quick,
    )
  let assert Ok(_) =
    store.transaction(s, lab.recommend(
      desk,
      _,
      "refund-1",
      about: lab.ana,
      output: "80.00",
      by: Rules("rules", "1"),
      score: 0.5,
    ))
  let assert Ok(_) =
    store.transaction(s, lab.open_and_decide(
      desk,
      _,
      "refund-1",
      lab.bia,
      Approve,
    ))
  assert lab.wait_until(
    fn() { store.count(store.handle(s), "followed") == 1 },
    within: 5000,
  )
  lab.stop_runtime(tree)
}

/// The runtime reports what it delivered and what it set aside, with the
/// occurrence's correlation.
pub fn the_runtime_reports_through_sinal_test() {
  let s = lab.start()
  let held =
    lab.desk(
      lab.point("reply.draft", Some(duration.minutes(1))),
      lab.proceeding(),
    )
  let wakes = process.new_subject()
  let settlements = process.new_subject()
  let set_aside = process.new_subject()
  let attachments = [
    sinal.observe(telemetry.wake_delivered(), fn(_, metadata) {
      process.send(wakes, metadata)
    }),
    sinal.observe(telemetry.settlement_delivered(), fn(_, metadata) {
      process.send(settlements, metadata)
    }),
    sinal.observe(telemetry.job_set_aside(), fn(_, metadata) {
      process.send(set_aside, metadata)
    }),
  ]
  let assert Ok(_) =
    store.transaction(s, lab.recommend(
      held,
      _,
      "reply-9",
      about: lab.ana,
      output: "Olá",
      by: Person("bia"),
      score: 1.0,
    ))
  let assert Ok(Nil) =
    store.transaction(s, fn(tx) { store.backlog(s).submit(tx, "t-9", "") })
  store.advance(s, duration.minutes(2))
  let tree =
    lab.start_runtime(
      runtime.Config(
        ..runtime.config(
          store.backlog(s),
          points: [runtime.point(held, settled: runtime.nothing_follows)],
          work: fn(_) { Error(decisions.ApplicationFailed("no model today")) },
        ),
        attempts: 3,
      )
      |> quick,
    )
  let assert Ok(wake) = process.receive(wakes, 5000)
  let assert Ok(settled) = process.receive(settlements, 5000)
  let assert Ok(aside) = process.receive(set_aside, 5000)
  lab.stop_runtime(tree)
  list.each(attachments, fn(attachment) {
    let _ = sinal.detach(attachment)
    Nil
  })
  assert wake.occurrence == "reply-9"
  assert wake.outcome == telemetry.WakeActed
  assert wake.correlation == correlation.from_key("reply-9")
  assert settled.occurrence == "reply-9"
  assert aside.queue == telemetry.TriggerQueue
  assert aside.occurrence == "t-9"
  assert aside.attempts == 3
  let assert Ok([backlog.Aside(job: backlog.TriggerJob(_), reason:, ..)]) =
    store.backlog(s).aside()
  assert reason == "no model today"
}

/// A transient store failure is delivered again without counting toward
/// setting the job aside: five contended reads, three attempts allowed,
/// and the settlement is still delivered.
pub fn a_contended_store_is_retried_without_counting_test() {
  let s = lab.start()
  let counter = lab.start()
  let healthy = lab.desk(lab.point("lab.contended", None), lab.proceeding())
  let port = store.port()
  // The same point over a port whose loads are contended five times.
  let flaky =
    decisions.desk(
      decisions.point_of(healthy),
      drives: fn(_) {
        decisions.Gated(
          name: "none",
          guard: fn(_, _) { Ok([]) },
          execute: fn(_, _) { Ok(Nil) },
        )
      },
      under: fn(_) { Ok(lab.proceeding()) },
      over: decisions_store.Port(..port, load: fn(tx, id) {
        case calls(counter, "load") <= 5 {
          True -> Error(decisions_store.Contended("the row is busy"))
          False -> port.load(tx, id)
        }
      }),
    )
  let assert Ok(_) =
    store.transaction(s, lab.recommend(
      healthy,
      _,
      "c-1",
      about: lab.ana,
      output: "done",
      by: Rules("rules", "1"),
      score: 1.0,
    ))
  let tree =
    lab.start_runtime(
      runtime.config(
        store.backlog(s),
        points: [
          runtime.point(flaky, settled: fn(tx, known) {
            store.add(tx, "followed", known.id)
            Ok(Nil)
          }),
        ],
        work: fn(_) { Ok(Nil) },
      )
      |> quick,
    )
  assert lab.wait_until(
    fn() { store.count(store.handle(s), "followed") == 1 },
    within: 5000,
  )
  lab.stop_runtime(tree)
  assert store.backlog(s).aside() == Ok([])
}
