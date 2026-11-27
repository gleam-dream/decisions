//// The port requires READ COMMITTED: `happened` reads `waiting` after it
//// takes the subject's lock, and only a new snapshot per statement shows it
//// what the lock's previous holder committed. A transaction at another
//// level is refused by `load` with a conflict that names the level. And a
//// subject lock stores nothing.

import decisions
import decisions/vocabulary.{Subject}
import decisions_postgres.{Conflict}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None}
import gleam/string
import kit
import pog

fn at_level(level: String, body) {
  fn(tx) {
    let assert Ok(_) =
      pog.query("SET TRANSACTION ISOLATION LEVEL " <> level)
      |> pog.execute(decisions_postgres.connection(tx))
    body(tx)
  }
}

pub fn a_transaction_not_read_committed_is_refused_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("isolation"), superseded_by: ["closed"])
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let about = Subject("person", kit.tag("ana"))
  // `happened` reaches `load` first, on the subject's lock.
  let assert Error(Conflict(detail)) =
    kit.tx(
      env,
      at_level("REPEATABLE READ", fn(tx) {
        decisions.happened(desk, tx, "closed", about:)
      }),
    )
  assert string.contains(detail, "requires READ COMMITTED")
  assert string.contains(detail, "repeatable read")
  // Any verb is refused the same way.
  let assert Error(Conflict(detail)) =
    kit.tx(
      env,
      at_level("SERIALIZABLE", fn(tx) {
        decisions.recommend_once(
          desk,
          tx,
          key: kit.tag("key"),
          proposal: kit.proposal(spec.name, about),
        )
      }),
    )
  assert string.contains(detail, "serializable")
  // At READ COMMITTED it runs.
  let assert Ok(_) =
    kit.tx(
      env,
      at_level("READ COMMITTED", fn(tx) {
        decisions.happened(desk, tx, "closed", about:)
      }),
    )
}

/// `load` of a subject lock takes the lock and stores nothing: no head, no
/// entry, no queue row, no wake-up, no notice.
pub fn a_subject_lock_stores_nothing_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("lock_id"), superseded_by: ["closed"])
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let about = Subject("person", kit.tag("ana"))
  let lock = decisions.subject_lock(point: spec.name, subject: about)
  let assert Ok(_) =
    kit.tx(env, fn(tx) { decisions.happened(desk, tx, "closed", about:) })
  let inspect = decisions_postgres.inspection()
  let assert Ok(None) = kit.within(env, inspect.head(_, lock))
  let assert Ok([]) =
    kit.within(env, decisions_postgres.port(store).load(_, lock))
  let assert Ok(wakes) = kit.within(env, inspect.wakes)
  assert !list.any(wakes, fn(w) { w.occurrence == lock })
  let assert Ok(notices) = kit.within(env, inspect.notices)
  assert !list.any(notices, fn(n) { n.occurrence == lock })
  assert kit.scalar(
      env.db,
      "SELECT (SELECT count(*) FROM decisions_entries WHERE occurrence_id = $1)
            + (SELECT count(*) FROM decisions_awaiting WHERE occurrence_id = $1)",
      [pog.text(lock)],
      decode.int,
    )
    == 0
}
