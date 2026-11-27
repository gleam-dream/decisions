//// The port's lock timeout: a long wait for a contended occurrence ends as
//// `Contended` (nothing written, safe to retry), never as `Unavailable`
//// from pog's 5 s checkout; the store option changes or removes it; and
//// it overrides a `lock_timeout` the caller set earlier in its
//// transaction, while `None` respects it.

import decisions
import decisions/store
import decisions_postgres
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import kit
import pog

/// Hold `id`'s row lock for `seconds` in one statement on the pool (a
/// `pog.transaction` would itself lose its connection after 5 s), and
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

fn read_with(
  env: kit.Env,
  desk: decisions.Desk(String, decisions_postgres.Tx),
  id: String,
  caller_timeout: option.Option(String),
) {
  decisions_postgres.refusing(env.pool, fn(tx) {
    case caller_timeout {
      Some(value) -> {
        let assert Ok(_) =
          pog.query("SET LOCAL lock_timeout = '" <> value <> "'")
          |> pog.execute(decisions_postgres.connection(tx))
        Nil
      }
      None -> Nil
    }
    decisions.read(desk, tx, occurrence: id)
  })
}

fn made(env: kit.Env, desk, spec: kit.Spec) -> String {
  let assert Ok(made) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  made.id
}

/// With the default (4 s), a lock held past it ends the wait as
/// contention, before pog's 5 s checkout would end the transaction as
/// unavailable.
pub fn a_long_lock_wait_is_contention_by_default_test() {
  let #(name, store) = kit.store()
  let spec = kit.spec("lock_default")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let id = made(env, desk, spec)
  hold(env, id, 6)
  let assert Error(decisions.StoreFailed(store.Contended(detail))) =
    read_with(env, desk, id, None)
  assert string.contains(detail, "55P03")
}

/// The option changes the limit.
pub fn the_store_option_changes_the_lock_timeout_test() {
  let #(name, store) = kit.store()
  let store =
    decisions_postgres.with_lock_timeout(store, Some(kit.lock_timeout(100)))
  let spec = kit.spec("lock_short")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let id = made(env, desk, spec)
  hold(env, id, 6)
  let assert Error(decisions.StoreFailed(store.Contended(detail))) =
    read_with(env, desk, id, None)
  assert string.contains(detail, "55P03")
}

/// With `None`, the caller's own `lock_timeout` is respected.
pub fn without_the_option_the_caller_setting_is_respected_test() {
  let #(name, store) = kit.store()
  let store = decisions_postgres.with_lock_timeout(store, None)
  let spec = kit.spec("lock_none")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let id = made(env, desk, spec)
  hold(env, id, 2)
  let assert Error(decisions.StoreFailed(store.Contended(detail))) =
    read_with(env, desk, id, Some("50ms"))
  assert string.contains(detail, "55P03")
}

/// With the option set, the store's timeout overrides the caller's: the
/// load is seen still waiting well past the caller's 50 ms, and succeeds
/// once the 2 s hold ends.
pub fn the_store_timeout_overrides_the_caller_setting_test() {
  let #(name, store) = kit.store()
  let spec = kit.spec("lock_override")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let id = made(env, desk, spec)
  hold(env, id, 2)
  let outcomes = process.new_subject()
  process.spawn(fn() {
    process.send(outcomes, read_with(env, desk, id, Some("50ms")))
  })
  let assert True =
    kit.eventually(3000, fn() {
      kit.scalar(
        env.db,
        "SELECT count(*) FROM pg_stat_activity
         WHERE wait_event_type = 'Lock' AND query LIKE '%decisions_load%'
           AND clock_timestamp() - query_start > interval '300 milliseconds'",
        [],
        decode.int,
      )
      >= 1
    })
  let assert Ok(Ok(found)) = process.receive(outcomes, 10_000)
  assert found.id == id
}

/// The shortest timeout there is, one millisecond, still ends a long wait
/// as contention. (`store.lock_timeout` refuses zero, which PostgreSQL
/// reads as "wait for ever", and a negative wait, which it refuses on
/// every load.)
pub fn the_shortest_timeout_still_bounds_the_wait_test() {
  let #(name, store) = kit.store()
  let store =
    decisions_postgres.with_lock_timeout(store, Some(kit.lock_timeout(1)))
  let spec = kit.spec("lock_shortest")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let id = made(env, desk, spec)
  hold(env, id, 2)
  let assert Error(decisions.StoreFailed(store.Contended(detail))) =
    read_with(env, desk, id, None)
  assert string.contains(detail, "55P03")
}
