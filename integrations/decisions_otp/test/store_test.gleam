//// The process-safe store's own guarantees beyond the conformance suite:
//// lock waits that end, deadlocks refused, savepoints, restart, rows.

import decisions
import decisions/fact
import decisions/policy.{SomeoneElseHolding}
import decisions/store as port_types
import decisions/vocabulary.{Manifest, Recommendation, RuleFired, Rules, Trigger}
import decisions_otp/store
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import support/lab
import support/policies

pub fn a_lock_wait_longer_than_the_timeout_is_refused_test() {
  lab.quiet()
  let assert Ok(s) =
    store.start(
      store.Config(..store.defaults(), lock_timeout: duration.milliseconds(50)),
    )
  let holding = process.new_subject()
  let holder =
    process.spawn_unlinked(fn() {
      store.transaction(s, fn(tx) {
        let assert Ok(Nil) = store.lock(tx, "row")
        process.send(holding, Nil)
        process.sleep_forever()
        Ok(Nil)
      })
    })
  let assert Ok(Nil) = process.receive(holding, 1000)
  let refused = store.transaction(s, fn(tx) { store.lock(tx, "row") })
  let assert Error(port_types.Contended(reason)) = refused
  assert string.starts_with(reason, "lock wait")
  // The holder dies: its lock goes with it.
  lab.kill(holder)
  assert store.transaction(s, fn(tx) { store.lock(tx, "row") }) == Ok(Nil)
}

pub fn a_wait_that_would_deadlock_is_refused_at_once_test() {
  let s = lab.start()
  let first_holds = process.new_subject()
  let second_holds = process.new_subject()
  let outcome = process.new_subject()
  process.spawn(fn() {
    let go = process.new_subject()
    let result =
      store.transaction(s, fn(tx) {
        let assert Ok(Nil) = store.lock(tx, "a")
        process.send(first_holds, go)
        let assert Ok(Nil) = process.receive(go, 5000)
        store.lock(tx, "b")
      })
    process.send(outcome, #("first", result))
  })
  let assert Ok(go) = process.receive(first_holds, 1000)
  process.spawn(fn() {
    let result =
      store.transaction(s, fn(tx) {
        let assert Ok(Nil) = store.lock(tx, "b")
        process.send(second_holds, Nil)
        process.sleep(50)
        store.lock(tx, "a")
      })
    process.send(outcome, #("second", result))
  })
  let assert Ok(Nil) = process.receive(second_holds, 1000)
  process.send(go, Nil)
  // One of them closes the cycle and is refused; the other then proceeds.
  let assert Ok(#(_, first)) = process.receive(outcome, 2000)
  let assert Ok(#(_, second)) = process.receive(outcome, 2000)
  let refused = case first, second {
    Error(port_types.Contended(reason)), Ok(Nil) -> reason
    Ok(Nil), Error(port_types.Contended(reason)) -> reason
    _, _ -> panic as "expected one deadlock and one success"
  }
  assert string.starts_with(refused, "deadlock")
}

pub fn a_restart_keeps_only_what_was_committed_test() {
  let s = lab.start()
  let assert Ok(Nil) =
    store.transaction(s, fn(tx) {
      store.put(tx, "accounts", "ana", "10")
      Ok(Nil)
    })
  let _ =
    store.transaction(s, fn(tx) {
      store.put(tx, "accounts", "bia", "20")
      Error(Nil)
    })
  store.advance(s, duration.hours(1))
  let before = store.now(s)
  let assert Ok(again) = store.restart(s, store.defaults())
  assert lab.within(again, store.get(_, "accounts", "ana")) == Ok("10")
  assert lab.within(again, store.get(_, "accounts", "bia")) == Error(Nil)
  // The clock carries its offset over.
  let after = store.now(again)
  assert duration.to_milliseconds(timestamp.difference(before, after)) < 1000
}

pub fn a_raise_inside_a_transaction_keeps_nothing_and_raises_again_test() {
  let s = lab.start()
  let raised =
    process.spawn_unlinked(fn() {
      store.transaction(s, fn(tx) {
        store.put(tx, "accounts", "ana", "10")
        raise()
      })
    })
  let monitor = process.monitor(raised)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  assert lab.within(s, store.get(_, "accounts", "ana")) == Error(Nil)
}

pub fn rows_added_come_back_in_order_test() {
  let s = lab.start()
  let assert Ok(Nil) =
    store.transaction(s, fn(tx) {
      store.add(tx, "outbox", "first")
      store.add(tx, "outbox", "second")
      store.add(tx, "outbox", "third")
      Ok(Nil)
    })
  let assert [#(_, "first"), #(_, "second"), #(_, "third")] =
    lab.within(s, store.rows(_, "outbox"))
}

fn raise() -> Result(Nil, Nil) {
  panic as "the body raised"
}

/// A card the person who asked may not decide is left out of their own
/// queue, and stays in everyone else's.
pub fn the_asker_does_not_see_their_own_card_test() {
  let s = lab.start()
  let desk =
    lab.desk(
      lab.point("billing.fee_refund", None),
      policies.checked(
        version: 1,
        rules: [],
        otherwise: SomeoneElseHolding("finance"),
      ),
    )
  let assert Ok(_) =
    store.transaction(s, fn(tx) {
      decisions.recommend_once(
        desk,
        tx,
        key: "refund-1",
        proposal: decisions.proposal(
          trigger: Trigger("lab", "refund-1"),
          about: lab.ana,
          context: Manifest(refs: [], renderer: "lab-1"),
          recommending: Recommendation(
            output: "80.00",
            by: Rules("rules", "1"),
            explanation: RuleFired("r"),
            signals: [fact.set(lab.score(), 0.5)],
            reads: [],
          ),
        )
          |> decisions.asked_by("bia"),
      )
    })
  assert store.queue(s, "finance") == ["refund-1"]
  assert store.queue_for(s, lab.bia) == []
  assert store.queue_page_for(s, lab.felipe, 50) == ["refund-1"]
}
