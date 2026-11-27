//// How the port reports a failure in which nothing was written: a
//// statement in a transaction that an earlier statement aborted, a
//// statement the server cancelled, and a pool with no connection to give
//// are all contention (roll back and run again), not an unknown outcome.

import decisions
import decisions/store
import decisions_postgres
import decisions_postgres/internal/sql
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/option.{None}
import gleam/string
import kit
import pog

fn made(env: kit.Env, desk, spec: kit.Spec) -> String {
  let assert Ok(made) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  made.id
}

/// The application's own statement fails and the verb runs after it in
/// the same transaction: nothing can be written any more.
pub fn a_verb_in_an_aborted_transaction_is_contention_test() {
  let #(name, store) = kit.store()
  let spec = kit.spec("aborted")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let id = made(env, desk, spec)
  let assert Error(decisions.StoreFailed(store.Contended(detail))) =
    decisions_postgres.refusing(env.pool, fn(tx) {
      let assert Error(_) =
        pog.query("SELECT 1 / 0")
        |> pog.execute(decisions_postgres.connection(tx))
      decisions.read(desk, tx, occurrence: id)
    })
  assert string.contains(detail, "25P02")
}

/// The server cancels the verb's statement (`statement_timeout`): the
/// transaction is aborted and nothing was written.
pub fn a_cancelled_statement_is_contention_test() {
  let #(name, store) = kit.store()
  let store = decisions_postgres.with_lock_timeout(store, None)
  let spec = kit.spec("cancelled")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let id = made(env, desk, spec)
  hold(env, id, 2)
  let assert Error(decisions.StoreFailed(store.Contended(detail))) =
    decisions_postgres.refusing(env.pool, fn(tx) {
      let assert Ok(_) =
        pog.query("SET LOCAL statement_timeout = '100ms'")
        |> pog.execute(decisions_postgres.connection(tx))
      decisions.read(desk, tx, occurrence: id)
    })
  assert string.contains(detail, "57014")
}

/// No connection was checked out, so nothing was sent.
pub fn no_connection_is_contention_test() {
  let assert store.Contended(_) = sql.store_error(pog.ConnectionUnavailable)
}

/// Hold `id`'s row lock for `seconds` in one statement on the pool, and
/// return once the holder is seen sleeping with the lock.
fn hold(env: kit.Env, id: String, seconds: Int) -> Nil {
  let tag = kit.tag("hold")
  process.spawn_unlinked(fn() {
    let _ =
      pog.query("SELECT pg_sleep($2)::text /* " <> tag <> " */ FROM (
           SELECT 1 FROM decisions_occurrences WHERE id = $1 FOR UPDATE) AS l")
      |> pog.parameter(pog.text(id))
      |> pog.parameter(pog.int(seconds))
      |> pog.timeout({ seconds + 5 } * 1000)
      |> pog.execute(env.db)
    Nil
  })
  let assert True =
    kit.eventually(5000, fn() {
      kit.scalar(
        env.db,
        "SELECT count(*) FROM pg_stat_activity
         WHERE wait_event = 'PgSleep' AND query LIKE $1",
        [pog.text("%" <> tag <> "%")],
        decode.int,
      )
      == 1
    })
  Nil
}
