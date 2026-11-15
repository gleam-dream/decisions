//// Live notifications: an append that commits reaches the subscribers of
//// its occurrence and its point; one that rolls back reaches nobody; a
//// subscriber whose process exits is forgotten; a subscriber can tell
//// that the listener went away; the listener reconnects.

import decisions
import decisions/vocabulary.{Approve}
import decisions_postgres/live
import decisions_postgres/queue
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import kit
import pog

pub fn a_committed_append_notifies_its_subscribers_test() {
  let #(name, store) = kit.store()
  let spec = kit.spec("live")
  let other = kit.spec("live_other")
  let desk = kit.desk(store, spec)
  let other_desk = kit.desk(store, other)
  use env <- kit.run(name, store, kit.options(), [], [])
  let assert Ok(started) = live.start(env.config)
  let listener = started.data
  let by_point = process.new_subject()
  // The subscription is acknowledged: it is in place when this returns.
  let assert Ok(_) =
    live.subscribe(listener, by_point, to: live.Point(spec.name))
  let assert Ok(made) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert Ok(change) = process.receive(by_point, 5000)
  assert change.occurrence == made.id
  assert change.point == spec.name
  assert change.status == "awaiting"
  assert change.seq == 2
  // Another point's change does not reach it: the next change it receives
  // is the one about its own point made afterwards. Notifications reach
  // the listener in commit order.
  let assert Ok(_) =
    kit.tx(env, decisions.recommend(
      other_desk,
      _,
      kit.proposal(other.name, kit.ana),
    ))
  let assert Ok(after_other) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert Ok(next) = process.receive(by_point, 5000)
  assert next.occurrence == after_other.id
  // An occurrence's subscriber hears of its verdict.
  let by_occurrence = process.new_subject()
  let assert Ok(_) =
    live.subscribe(listener, by_occurrence, to: live.Occurrence(made.id))
  let assert Ok(_) =
    kit.tx(env, kit.open_and_decide(
      desk,
      _,
      made.id,
      kit.finance("bia"),
      Approve,
    ))
  let assert Ok(opened) = process.receive(by_occurrence, 5000)
  assert opened.occurrence == made.id
  drain_until(by_point, made.id, "released")
  // A transaction that rolls back notifies nobody: the next change the
  // point's subscriber receives is the one committed after it.
  let assert Error(_) =
    pog.transaction(env.db, fn(tx) {
      let assert Ok(rolled) =
        decisions.recommend(desk, tx, kit.proposal(spec.name, kit.ana))
      Error(rolled.id)
    })
  let assert Ok(committed) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert Ok(next) = process.receive(by_point, 5000)
  assert next.occurrence == committed.id
  process.unlink(started.pid)
  process.kill(started.pid)
}

/// Receive until the change that put `id` in `status` arrives.
fn drain_until(
  subject: process.Subject(live.Change),
  id: String,
  status: String,
) -> Nil {
  let assert Ok(change) = process.receive(subject, 5000)
  case change.occurrence == id && change.status == status {
    True -> Nil
    False -> drain_until(subject, id, status)
  }
}

/// A subscriber learns that the listener went away by monitoring the
/// process `subscribe` returned.
pub fn a_subscriber_can_tell_the_listener_went_away_test() {
  let #(name, store) = kit.store()
  use env <- kit.run(name, store, kit.options(), [], [])
  let assert Ok(started) = live.start(env.config)
  let changes = process.new_subject()
  let assert Ok(pid) =
    live.subscribe(started.data, changes, to: live.Everything)
  assert pid == started.pid
  let monitor = process.monitor(pid)
  process.unlink(started.pid)
  process.kill(started.pid)
  let assert Ok(process.ProcessDown(..)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(5000)
}

/// A subscriber whose process exits is dropped; the listener goes on.
pub fn a_subscriber_that_exits_is_forgotten_test() {
  let #(name, store) = kit.store()
  let spec = kit.spec("live_exit")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let assert Ok(started) = live.start(env.config)
  let listener = started.data
  let done = process.new_subject()
  let gone =
    process.spawn_unlinked(fn() {
      let mine = process.new_subject()
      let assert Ok(_) = live.subscribe(listener, mine, to: live.Everything)
      process.send(done, Nil)
    })
  let assert Ok(Nil) = process.receive(done, 1000)
  // Its process has ended; the listener sends nothing to it again.
  assert !process.is_alive(gone)
  let still = process.new_subject()
  let assert Ok(_) = live.subscribe(listener, still, to: live.Everything)
  let assert Ok(_) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert Ok(_) = process.receive(still, 5000)
  process.unlink(started.pid)
  process.kill(started.pid)
}

/// The listening connection is lost (its backend terminated). The
/// listener reconnects by itself and listens again, and later changes
/// reach the subscriber; a change made while it was disconnected is not
/// delivered, and the documented fallback, polling `queue.positions`,
/// shows it.
pub fn the_listener_reconnects_and_polling_shows_what_was_missed_test() {
  let #(name, store) = kit.store()
  let spec = kit.spec("live_lost")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let assert Ok(started) = live.start(env.config)
  let changes = process.new_subject()
  let assert Ok(_) =
    live.subscribe(started.data, changes, to: live.Point(spec.name))
  let assert Ok(first) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert Ok(_) = process.receive(changes, 5000)
  // Terminate the listener's backend: its last statement was LISTEN.
  let terminated =
    kit.scalar(
      env.db,
      "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity
       WHERE query LIKE 'LISTEN %decisions_changed%' AND pid <> pg_backend_pid()",
      [],
      decode.int,
    )
  assert terminated >= 1
  // A verdict while it is disconnected.
  let assert Ok(decided) =
    kit.tx(env, kit.open_and_decide(
      desk,
      _,
      first.id,
      kit.finance("bia"),
      Approve,
    ))
  // The listener reconnects and hears later changes.
  let heard =
    kit.eventually(10_000, fn() {
      let assert Ok(_) =
        kit.tx(env, decisions.recommend(
          desk,
          _,
          kit.proposal(spec.name, kit.ana),
        ))
      case process.receive(changes, 200) {
        Ok(_) -> True
        Error(Nil) -> False
      }
    })
  assert heard
  // Polling the positions of the cards a client holds shows the change it
  // may have missed: the last sequence number moved past what it saw.
  let assert Ok([#(_, seq)]) = queue.positions(env.db, [first.id])
  assert seq == list.length(decided.entries)
  assert seq > 2
  process.unlink(started.pid)
  process.kill(started.pid)
}
