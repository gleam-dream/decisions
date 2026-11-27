//// Condition E6, live: two validators have the same card open and one
//// decides. And what a subscription promises.

import decisions
import decisions/occurrence
import decisions/vocabulary.{Approve, Rules}
import decisions_otp/live.{Changed, Missed}
import decisions_otp/store
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import support/lab

fn refund(s: store.Store, key: String) -> Nil {
  let desk =
    lab.desk(lab.point("billing.fee_refund", None), lab.asking("finance"))
  let assert Ok(_) =
    store.transaction(s, lab.recommend(
      desk,
      _,
      key,
      about: lab.ana,
      output: "80.00",
      by: Rules("rules", "1"),
      score: 0.5,
    ))
  Nil
}

pub fn the_other_validator_is_told_when_the_card_is_decided_test() {
  let s = lab.start()
  let desk =
    lab.desk(lab.point("billing.fee_refund", None), lab.asking("finance"))
  refund(s, "refund-1")
  // Felipe's page: a process that has the card open and listens.
  let report = process.new_subject()
  process.spawn(fn() {
    let hints = process.new_subject()
    let assert Ok(subscription) =
      store.subscribe(s, live.ToOccurrence("refund-1"), hints)
    let assert Ok(_) =
      store.transaction(
        s,
        decisions.open(
          desk,
          _,
          occurrence: "refund-1",
          by: lab.felipe,
          latest: fn(ref) { ref.revision },
        ),
      )
    process.send(report, "open")
    let told = wait_for(hints, "released")
    store.unsubscribe(s, subscription)
    // A hint is a reason to read again. The truth is the record.
    let assert Ok(now) =
      store.transaction(s, decisions.read(desk, _, occurrence: "refund-1"))
    process.send(report, case told, now.status {
      True, occurrence.Released(by: occurrence.ByValidator(who), ..) ->
        "decided by " <> who
      _, _ -> "not told"
    })
  })
  let assert Ok("open") = process.receive(report, 1000)
  let assert Ok(_) =
    store.transaction(s, lab.open_and_decide(
      desk,
      _,
      "refund-1",
      lab.bia,
      Approve,
    ))
  assert process.receive(report, 1000) == Ok("decided by bia")
  // Someone who was not listening lost nothing: the record says the same.
  let assert Ok(late) =
    store.transaction(s, decisions.read(desk, _, occurrence: "refund-1"))
  let assert occurrence.Released(by: occurrence.ByValidator("bia"), ..) =
    late.status
}

fn wait_for(hints: process.Subject(live.Hint), status: String) -> Bool {
  case process.receive(hints, 1000) {
    Ok(Changed(status: found, ..)) if found == status -> True
    Ok(_) -> wait_for(hints, status)
    Error(Nil) -> False
  }
}

pub fn a_transaction_that_rolls_back_tells_nobody_test() {
  let s = lab.start()
  let desk =
    lab.desk(lab.point("billing.fee_refund", None), lab.asking("finance"))
  let hints = process.new_subject()
  let assert Ok(_) =
    store.subscribe(s, live.ToPoint("billing.fee_refund"), hints)
  let _ =
    store.transaction(s, fn(tx) {
      let assert Ok(_) =
        lab.recommend(
          desk,
          tx,
          "refund-2",
          about: lab.ana,
          output: "10.00",
          by: Rules("rules", "1"),
          score: 0.5,
        )
      Error("the caller changed its mind")
    })
  // Seen positively: the next hint is for a later commit, not for the
  // rolled-back one.
  refund(s, "refund-after")
  let assert Ok(Changed(occurrence: "refund-after", ..)) =
    process.receive(hints, 1000)
}

pub fn a_queue_subscriber_is_told_when_a_card_enters_and_leaves_test() {
  let s = lab.start()
  let desk =
    lab.desk(lab.point("billing.fee_refund", None), lab.asking("finance"))
  let hints = process.new_subject()
  let assert Ok(_) = store.subscribe(s, live.ToQueue("finance"), hints)
  refund(s, "refund-3")
  assert process.receive(hints, 500)
    == Ok(Changed("billing.fee_refund", "refund-3", "awaiting"))
  let assert Ok(_) =
    store.transaction(s, lab.open_and_decide(
      desk,
      _,
      "refund-3",
      lab.bia,
      Approve,
    ))
  // The verdict takes the occurrence out of the queue: its subscribers
  // hear that too.
  assert wait_for(hints, "released")
  // A finance card is not in the support queue: its subscriber hears the
  // support card that comes after it, and nothing before.
  let other = process.new_subject()
  let assert Ok(_) = store.subscribe(s, live.ToQueue("support"), other)
  refund(s, "refund-4")
  let support =
    lab.desk(lab.point("support.ticket", None), lab.asking("support"))
  let assert Ok(_) =
    store.transaction(s, lab.recommend(
      support,
      _,
      "ticket-1",
      about: lab.ana,
      output: "x",
      by: Rules("rules", "1"),
      score: 0.5,
    ))
  let assert Ok(Changed(occurrence: "ticket-1", ..)) =
    process.receive(other, 1000)
}

pub fn a_subscriber_that_falls_behind_is_told_how_much_it_missed_test() {
  lab.quiet()
  let assert Ok(s) =
    store.start(store.Config(..store.defaults(), hint_capacity: 2))
  // A subscriber that reads its mailbox only when asked to report.
  let subscribed = process.new_subject()
  let reports = process.new_subject()
  let subscriber =
    process.spawn_unlinked(fn() {
      let hints = process.new_subject()
      let asks = process.new_subject()
      let assert Ok(_) =
        store.subscribe(s, live.ToPoint("billing.fee_refund"), hints)
      process.send(subscribed, asks)
      report(hints, asks, reports)
    })
  let assert Ok(asks) = process.receive(subscribed, 1000)
  list.each(["r-1", "r-2", "r-3", "r-4", "r-5"], refund(s, _))
  process.send(asks, Nil)
  let assert Ok([Changed(occurrence: "r-1", ..), Changed(occurrence: "r-2", ..)]) =
    process.receive(reports, 1000)
  refund(s, "r-6")
  process.send(asks, Nil)
  let assert Ok([Missed(3), Changed(occurrence: "r-6", ..)]) =
    process.receive(reports, 1000)
  lab.kill(subscriber)
}

/// Wait to be asked, then send every hint received so far.
fn report(
  hints: process.Subject(live.Hint),
  asks: process.Subject(Nil),
  reports: process.Subject(List(live.Hint)),
) -> Nil {
  let assert Ok(Nil) = process.receive(asks, 5000)
  process.send(reports, drain(hints, []))
  report(hints, asks, reports)
}

fn drain(
  hints: process.Subject(live.Hint),
  so_far: List(live.Hint),
) -> List(live.Hint) {
  case process.receive(hints, 0) {
    Ok(hint) -> drain(hints, [hint, ..so_far])
    Error(Nil) -> list.reverse(so_far)
  }
}

pub fn a_subscriber_that_dies_is_forgotten_test() {
  let s = lab.start()
  let told = process.new_subject()
  let subscriber =
    process.spawn_unlinked(fn() {
      let hints = process.new_subject()
      let assert Ok(_) =
        store.subscribe(s, live.ToPoint("billing.fee_refund"), hints)
      process.send(told, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(told, 1000)
  lab.kill(subscriber)
  // The store goes on committing and telling the living.
  let hints = process.new_subject()
  let assert Ok(_) =
    store.subscribe(s, live.ToPoint("billing.fee_refund"), hints)
  refund(s, "after")
  let assert Ok(Changed(occurrence: "after", ..)) = process.receive(hints, 500)
}
