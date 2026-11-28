//// An application reads where an occurrence stands, to route a card or
//// say whether it still waits, from its committed head: one statement on
//// the pool, without a lock and without waiting for a transaction that
//// holds the occurrence.

import decisions
import decisions/store
import decisions_postgres
import gleam/option.{None, Some}
import kit

pub fn a_committed_head_is_read_without_waiting_for_the_lock_test() {
  let #(name, s) = kit.store()
  let spec = kit.spec("committed_head")
  let desk = kit.desk(s, spec)
  use env <- kit.run(name, s, kit.options(), [], [])
  let assert Ok(waiting) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  assert decisions_postgres.head(env.pool, occurrence: "no-such-occurrence")
    == Ok(None)
  // This transaction holds the occurrence's lock and has not committed;
  // the head is read on another connection of the pool, at once.
  let assert Ok(head) =
    kit.tx(env, fn(tx) {
      let assert Ok(_) = decisions.read(desk, tx, occurrence: waiting.id)
      let assert Ok(Some(head)) =
        decisions_postgres.head(env.pool, occurrence: waiting.id)
      Ok(head)
    })
  assert head.status == store.Awaiting
  assert head.awaiting == ["finance"]
}
