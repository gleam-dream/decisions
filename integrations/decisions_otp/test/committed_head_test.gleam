//// An application reads where an occurrence stands, to route a card or
//// say whether it still waits, from its committed head: without a lock,
//// without waiting for a transaction that holds the occurrence, and
//// without the test-only inspection.

import decisions
import decisions/store as port_types
import decisions/vocabulary.{Rules, Subject}
import decisions_otp/store
import gleam/erlang/process
import gleam/option.{None, Some}
import support/lab

pub fn a_committed_head_is_read_without_waiting_for_the_lock_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("route", None), lab.asking("mods"))
  let assert Ok(known) =
    store.transaction(s, lab.recommend(
      desk,
      _,
      "post-1",
      about: Subject("post", "1"),
      output: "remove",
      by: Rules("r", "1"),
      score: 0.5,
    ))
  assert store.head(s, "no-such-occurrence") == None
  // Another transaction holds the occurrence's lock and has not committed.
  let holding = process.new_subject()
  process.spawn(fn() {
    let gate = process.new_subject()
    let assert Ok(Nil) =
      store.transaction(s, fn(tx) {
        let assert Ok(_) = decisions.read(desk, tx, occurrence: known.id)
        process.send(holding, gate)
        let assert Ok(Nil) = process.receive(gate, 5000)
        Ok(Nil)
      })
  })
  let assert Ok(gate) = process.receive(holding, 1000)
  let assert Some(head) = store.head(s, known.id)
  assert head.status == port_types.Awaiting
  assert head.awaiting == ["mods"]
  process.send(gate, Nil)
}
