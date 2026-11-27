//// A `decisions_otp/stress.Target` over PostgreSQL, so the race and crash
//// scenarios written once in `decisions_otp/stress` run against this
//// adapter.
////
//// Each target lives in a schema of its own: its pool's `search_path`
//// names it, and `migrate` creates the tables there. The store's clock is
//// the database's plus an offset that `advance` moves. Production delivery
//// of wake-ups and notices is Grind's (`decisions_postgres.wake_worker`
//// and `settlement_worker`); the `Backlog` here exists only so that the
//// shared scenarios can drive `decisions_otp/runtime` over these tables.
//// Triggers live in a test-only table, `test_triggers`.
////
//// `restart` is not a server restart: it stops the runtime and its pool and
//// opens a new pool over the same schema, so what the scenarios called
//// "restart" checks that nothing lives in the node's processes, not that
//// PostgreSQL recovers; the test script owns the cluster and cannot
//// restart it under a running suite.

import decisions/conformance
import decisions/store.{type StoreError, type Wake, Notice, Wake}
import decisions/vocabulary.{Validator}
import decisions/wire
import decisions_otp/backlog.{
  type Backlog, type Job, type Pending, type Submitted, Aside, Backlog,
  NoticeJob, Pending, Submitted, TriggerJob, WakeJob,
}
import decisions_otp/stress.{type Target, Target}
import decisions_postgres
import decisions_postgres/internal/sql
import decisions_postgres/queue
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import kit
import pog

type Offset

@external(erlang, "kit_ffi", "offset_new")
fn offset_new() -> Offset

@external(erlang, "kit_ffi", "offset_get")
fn offset_get(offset: Offset) -> Int

@external(erlang, "kit_ffi", "offset_add")
fn offset_add(offset: Offset, ms: Int) -> Nil

type Claims

@external(erlang, "kit_ffi", "claims_new")
fn claims_new() -> Claims

@external(erlang, "kit_ffi", "claim")
fn claim(claims: Claims, id: Int) -> Bool

@external(erlang, "kit_ffi", "unclaim")
fn unclaim(claims: Claims, id: Int) -> Nil

/// A fresh target in a new schema, over a new Grind runtime (no consumers:
/// the scenarios deliver through `decisions_otp/runtime` and this
/// backlog).
pub fn fresh() -> Result(Target(decisions_postgres.Tx), String) {
  let schema = "stress_" <> int.to_string(kit.unique())
  let offset = offset_new()
  let claims = claims_new()
  over(schema, offset, claims)
}

fn over(
  schema: String,
  offset: Offset,
  claims: Claims,
) -> Result(Target(decisions_postgres.Tx), String) {
  let #(name, store) = kit.store()
  let options = kit.Options(..kit.options(), pool_size: 40)
  let env = kit.start_with(name, store, schema, options, [], [])
  let db = env.db
  use _ <- result.try(
    list.try_each(
      [
        "CREATE TABLE IF NOT EXISTS test_rows (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, tbl text NOT NULL, value text NOT NULL)",
        "CREATE TABLE IF NOT EXISTS test_triggers (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, key text NOT NULL, payload text NOT NULL, set_aside_at timestamptz, set_aside_reason text)",
        "CREATE TABLE IF NOT EXISTS test_failures (kind text NOT NULL, job text NOT NULL, attempts integer NOT NULL, until_ms bigint NOT NULL, PRIMARY KEY (kind, job))",
      ],
      fn(sql) { pog.query(sql) |> pog.execute(db) |> result.replace(Nil) },
    )
    |> result.map_error(string.inspect),
  )
  let base = decisions_postgres.port(store)
  let clock = fn(tx) {
    timestamp.add(base.now(tx), duration.milliseconds(offset_get(offset)))
  }
  let port = store.Port(..base, now: clock)
  Ok(
    Target(
      adapter: conformance.Adapter(
        port:,
        inspect: decisions_postgres.inspection(),
        transaction: fn(body) { in_transaction(env, body) },
        cleanup: fn() { kit.stop(env) },
      ),
      backlog: backlog(env, fn() { kit.within(env, clock) }, claims),
      add: fn(tx, table, row) {
        pog.query("INSERT INTO test_rows (tbl, value) VALUES ($1, $2)")
        |> pog.parameter(pog.text(table))
        |> pog.parameter(pog.text(row))
        |> pog.execute(decisions_postgres.connection(tx))
        |> result.replace(Nil)
        |> result.map_error(string.inspect)
      },
      rows: fn(tx, table) {
        pog.query("SELECT value FROM test_rows WHERE tbl = $1 ORDER BY id")
        |> pog.parameter(pog.text(table))
        |> pog.returning(decode.at([0], decode.string))
        |> pog.execute(decisions_postgres.connection(tx))
        |> result.map(fn(returned) { returned.rows })
        |> result.map_error(string.inspect)
      },
      queue: fn(set, limit) {
        queue.page(
          env.pool,
          for: Validator("stress-queue-reader", [set]),
          limit:,
          after: None,
        )
        |> result.map(list.map(_, fn(card) { card.occurrence }))
        |> result.map_error(string.inspect)
      },
      advance: fn(by: Duration) {
        offset_add(offset, duration.to_milliseconds(by))
      },
      poison: fn(id) { poison(db, id) },
      restart: fn() {
        // A database restart: the runtime and its pool stop; a new pool over
        // the same schema finds what was committed.
        kit.stop(env)
        over(schema, offset, claims)
      },
    ),
  )
}

/// Damage the first entry of an occurrence, as an older codec's record
/// would look. The append-only trigger is disabled for the one statement,
/// as the table's owner can.
fn poison(db: pog.Connection, id: String) -> Result(Nil, String) {
  pog.transaction(db, fn(tx) {
    let run = fn(sql) {
      pog.query(sql)
      |> pog.parameter(pog.text(id))
      |> pog.execute(tx)
      |> result.replace(Nil)
    }
    let plain = fn(sql) {
      pog.query(sql)
      |> pog.execute(tx)
      |> result.replace(Nil)
    }
    use Nil <- result.try(plain(
      "ALTER TABLE decisions_entries DISABLE TRIGGER decisions_entries_append_only",
    ))
    use Nil <- result.try(run(
      "UPDATE decisions_entries SET event = '{not json'
       WHERE occurrence_id = $1 AND seq = 1",
    ))
    plain(
      "ALTER TABLE decisions_entries ENABLE TRIGGER decisions_entries_append_only",
    )
  })
  |> result.map_error(string.inspect)
}

/// Run `body` in a transaction on the target's pool, with its error kept
/// as text.
fn in_transaction(
  env: kit.Env,
  body: fn(decisions_postgres.Tx) -> Result(a, String),
) -> Result(a, String) {
  case kit.own(env, body) {
    Ok(value) -> Ok(value)
    Error(decisions_postgres.OwnFailed(reason)) -> Error(reason)
    Error(decisions_postgres.LibraryFailed(failure)) ->
      Error(decisions_postgres.describe(failure))
  }
}

fn backlog(
  env: kit.Env,
  now: fn() -> Timestamp,
  claims: Claims,
) -> Backlog(decisions_postgres.Tx) {
  let db = env.db
  Backlog(
    transaction: fn(body) { in_transaction(env, body) },
    now:,
    due: fn(at, limit) {
      pog.query(
        "SELECT point, occurrence_id, decisions_ms(at) FROM decisions_wakes w
         WHERE set_aside_at IS NULL AND at <= decisions_at($1)
           AND NOT EXISTS (
             SELECT 1 FROM test_failures f
             WHERE f.kind = 'wake' AND f.until_ms > $1
               AND f.job = w.point || '|' || w.occurrence_id || '|'
                 || decisions_ms(w.at))
         ORDER BY at, id LIMIT $2",
      )
      |> pog.parameter(pog.int(wire.milliseconds(at)))
      |> pog.parameter(pog.int(limit))
      |> pog.returning(wake_decoder())
      |> rows(db)
    },
    take_wake: fn(tx, wake: Wake) {
      use _ <- result.try(lock_occurrence(tx, wake.occurrence))
      pog.query(
        "DELETE FROM decisions_wakes
         WHERE point = $1 AND occurrence_id = $2 AND at = decisions_at($3)
           AND set_aside_at IS NULL
         RETURNING id",
      )
      |> wake_parameters(wake)
      |> pog.returning(decode.at([0], decode.int))
      |> rows(decisions_postgres.connection(tx))
      |> result.map(fn(found) { found != [] })
    },
    add_wake: fn(tx, wake: Wake) {
      use _ <- result.try(lock_occurrence(tx, wake.occurrence))
      pog.query(
        "INSERT INTO decisions_wakes (point, occurrence_id, at)
         VALUES ($1, $2, decisions_at($3))
         ON CONFLICT (point, occurrence_id, at) WHERE set_aside_at IS NULL
         DO NOTHING",
      )
      |> wake_parameters(wake)
      |> rows(decisions_postgres.connection(tx))
      |> result.replace(Nil)
    },
    undelivered: fn(limit) {
      pog.query(
        "SELECT id, point, occurrence_id FROM decisions_settled s
         WHERE delivered_at IS NULL AND set_aside_at IS NULL
           AND NOT EXISTS (
             SELECT 1 FROM test_failures f
             WHERE f.kind = 'notice' AND f.job = s.id::text AND f.until_ms > $2)
         ORDER BY id LIMIT $1",
      )
      |> pog.parameter(pog.int(limit))
      |> pog.parameter(pog.int(wire.milliseconds(now())))
      |> pog.returning({
        use id <- decode.field(0, decode.int)
        use point <- decode.field(1, decode.string)
        use occurrence <- decode.field(2, decode.string)
        decode.success(Pending(id:, notice: Notice(point:, occurrence:)))
      })
      |> rows(db)
    },
    deliver_notice: fn(tx, pending: Pending) {
      pog.query(
        "UPDATE decisions_settled SET delivered_at = clock_timestamp()
         WHERE id = $1 AND delivered_at IS NULL AND set_aside_at IS NULL
         RETURNING id",
      )
      |> pog.parameter(pog.int(pending.id))
      |> pog.returning(decode.at([0], decode.int))
      |> rows(decisions_postgres.connection(tx))
      |> result.map(fn(found) { found != [] })
    },
    submit: fn(tx, key, payload) {
      pog.query("INSERT INTO test_triggers (key, payload) VALUES ($1, $2)")
      |> pog.parameter(pog.text(key))
      |> pog.parameter(pog.text(payload))
      |> rows(decisions_postgres.connection(tx))
      |> result.replace(Nil)
    },
    claim_trigger: fn() {
      pog.query(
        "SELECT id, key, payload FROM test_triggers t
         WHERE set_aside_at IS NULL
           AND NOT EXISTS (
             SELECT 1 FROM test_failures f
             WHERE f.kind = 'trigger' AND f.job = t.id::text AND f.until_ms > $1)
         ORDER BY id LIMIT 256",
      )
      |> pog.parameter(pog.int(wire.milliseconds(now())))
      |> pog.returning({
        use id <- decode.field(0, decode.int)
        use key <- decode.field(1, decode.string)
        use payload <- decode.field(2, decode.string)
        decode.success(Submitted(id:, key:, payload:))
      })
      |> rows(db)
      |> result.map(fn(found) {
        // Claimed, then checked again: a trigger another worker finished
        // between the read and the claim is released and skipped.
        list.find(found, fn(submitted) {
          claim(claims, submitted.id)
          && case still_there(db, submitted.id) {
            True -> True
            False -> {
              unclaim(claims, submitted.id)
              False
            }
          }
        })
        |> option.from_result
      })
    },
    finish_trigger: fn(tx, submitted: Submitted) {
      pog.query("DELETE FROM test_triggers WHERE id = $1 RETURNING id")
      |> pog.parameter(pog.int(submitted.id))
      |> pog.returning(decode.at([0], decode.int))
      |> rows(decisions_postgres.connection(tx))
      |> result.map(fn(found) { found != [] })
    },
    release: fn(submitted: Submitted) { unclaim(claims, submitted.id) },
    failed: fn(tx, job, _reason) {
      use present <- result.try(lock_job(tx, job))
      case present {
        False -> Ok(0)
        True -> {
          let #(kind, key) = job_key(job)
          // Counted, and postponed by the backoff: `due`, `undelivered`
          // and `claim_trigger` leave the job out until it has passed.
          pog.query(
            "INSERT INTO test_failures (kind, job, attempts, until_ms)
             VALUES ($1, $2, 1, $3)
             ON CONFLICT (kind, job)
             DO UPDATE SET attempts = test_failures.attempts + 1,
                           until_ms = EXCLUDED.until_ms
             RETURNING attempts",
          )
          |> pog.parameter(pog.text(kind))
          |> pog.parameter(pog.text(key))
          |> pog.parameter(pog.int(wire.milliseconds(now()) + retry_backoff_ms))
          |> pog.returning(decode.at([0], decode.int))
          |> rows(decisions_postgres.connection(tx))
          |> result.map(fn(found) { list.first(found) |> result.unwrap(0) })
        }
      }
    },
    set_aside: fn(tx, job, reason) {
      case job {
        WakeJob(wake:) ->
          pog.query(
            "UPDATE decisions_wakes
             SET set_aside_at = clock_timestamp(), set_aside_reason = $4
             WHERE point = $1 AND occurrence_id = $2 AND at = decisions_at($3)
               AND set_aside_at IS NULL",
          )
          |> wake_parameters(wake)
          |> pog.parameter(pog.text(reason))
          |> rows(decisions_postgres.connection(tx))
          |> result.replace(Nil)
        NoticeJob(pending:) ->
          pog.query(
            "UPDATE decisions_settled
             SET set_aside_at = clock_timestamp(), set_aside_reason = $2
             WHERE id = $1 AND set_aside_at IS NULL",
          )
          |> pog.parameter(pog.int(pending.id))
          |> pog.parameter(pog.text(reason))
          |> rows(decisions_postgres.connection(tx))
          |> result.replace(Nil)
        TriggerJob(submitted:) ->
          pog.query(
            "UPDATE test_triggers
             SET set_aside_at = clock_timestamp(), set_aside_reason = $2
             WHERE id = $1 AND set_aside_at IS NULL",
          )
          |> pog.parameter(pog.int(submitted.id))
          |> pog.parameter(pog.text(reason))
          |> rows(decisions_postgres.connection(tx))
          |> result.replace(Nil)
      }
    },
    aside: fn() { aside(db) },
  )
}

fn aside(db: pog.Connection) -> Result(List(backlog.Aside), StoreError) {
  let attempts = fn(kind, key) {
    "coalesce((SELECT attempts FROM test_failures f WHERE f.kind = '"
    <> kind
    <> "' AND f.job = "
    <> key
    <> "), 0)"
  }
  use wakes <- result.try(
    pog.query(
      "SELECT point, occurrence_id, decisions_ms(at), set_aside_reason, "
      <> attempts(
        "wake",
        "w.point || '|' || w.occurrence_id || '|' || decisions_ms(w.at)",
      )
      <> ", decisions_ms(set_aside_at) FROM decisions_wakes w
         WHERE set_aside_at IS NOT NULL",
    )
    |> pog.returning({
      use point <- decode.field(0, decode.string)
      use occurrence <- decode.field(1, decode.string)
      use at <- decode.field(2, decode.int)
      use reason <- decode.field(3, decode.string)
      use attempts <- decode.field(4, decode.int)
      use aside_at <- decode.field(5, decode.int)
      decode.success(Aside(
        job: WakeJob(Wake(point:, occurrence:, at: wire.from_milliseconds(at))),
        reason:,
        attempts:,
        at: wire.from_milliseconds(aside_at),
      ))
    })
    |> rows(db),
  )
  use notices <- result.try(
    pog.query(
      "SELECT id, point, occurrence_id, set_aside_reason, "
      <> attempts("notice", "s.id::text")
      <> ", decisions_ms(set_aside_at) FROM decisions_settled s
         WHERE set_aside_at IS NOT NULL",
    )
    |> pog.returning({
      use id <- decode.field(0, decode.int)
      use point <- decode.field(1, decode.string)
      use occurrence <- decode.field(2, decode.string)
      use reason <- decode.field(3, decode.string)
      use attempts <- decode.field(4, decode.int)
      use aside_at <- decode.field(5, decode.int)
      decode.success(Aside(
        job: NoticeJob(Pending(id:, notice: Notice(point:, occurrence:))),
        reason:,
        attempts:,
        at: wire.from_milliseconds(aside_at),
      ))
    })
    |> rows(db),
  )
  use triggers <- result.try(
    pog.query(
      "SELECT id, key, payload, set_aside_reason, "
      <> attempts("trigger", "t.id::text")
      <> ", decisions_ms(set_aside_at) FROM test_triggers t
         WHERE set_aside_at IS NOT NULL",
    )
    |> pog.returning({
      use id <- decode.field(0, decode.int)
      use key <- decode.field(1, decode.string)
      use payload <- decode.field(2, decode.string)
      use reason <- decode.field(3, decode.string)
      use attempts <- decode.field(4, decode.int)
      use aside_at <- decode.field(5, decode.int)
      decode.success(Aside(
        job: TriggerJob(Submitted(id:, key:, payload:)),
        reason:,
        attempts:,
        at: wire.from_milliseconds(aside_at),
      ))
    })
    |> rows(db),
  )
  list.flatten([wakes, notices, triggers])
  |> list.sort(fn(a, b) { timestamp.compare(a.at, b.at) })
  |> Ok
}

/// How long a failed job waits before it is offered again, as the OTP
/// store's default `retry_backoff`.
const retry_backoff_ms = 1000

fn still_there(db: pog.Connection, id: Int) -> Bool {
  case
    pog.query("SELECT 1 FROM test_triggers WHERE id = $1")
    |> pog.parameter(pog.int(id))
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(db)
  {
    Ok(pog.Returned(rows: [_], ..)) -> True
    _ -> False
  }
}

fn lock_occurrence(
  tx: decisions_postgres.Tx,
  id: String,
) -> Result(Nil, StoreError) {
  pog.query("SELECT id FROM decisions_occurrences WHERE id = $1 FOR UPDATE")
  |> pog.parameter(pog.text(id))
  |> rows(decisions_postgres.connection(tx))
  |> result.replace(Nil)
}

fn lock_job(tx: decisions_postgres.Tx, job: Job) -> Result(Bool, StoreError) {
  let query = case job {
    WakeJob(wake:) ->
      pog.query(
        "SELECT 1 FROM decisions_wakes
         WHERE point = $1 AND occurrence_id = $2 AND at = decisions_at($3)
           AND set_aside_at IS NULL FOR UPDATE",
      )
      |> wake_parameters(wake)
    NoticeJob(pending:) ->
      pog.query(
        "SELECT 1 FROM decisions_settled
         WHERE id = $1 AND delivered_at IS NULL AND set_aside_at IS NULL
         FOR UPDATE",
      )
      |> pog.parameter(pog.int(pending.id))
    TriggerJob(submitted:) ->
      pog.query(
        "SELECT 1 FROM test_triggers WHERE id = $1 AND set_aside_at IS NULL
         FOR UPDATE",
      )
      |> pog.parameter(pog.int(submitted.id))
  }
  query
  |> pog.returning(decode.at([0], decode.int))
  |> rows(decisions_postgres.connection(tx))
  |> result.map(fn(found) { found != [] })
}

fn job_key(job: Job) -> #(String, String) {
  case job {
    WakeJob(wake:) -> #(
      "wake",
      wake.point
        <> "|"
        <> wake.occurrence
        <> "|"
        <> int.to_string(wire.milliseconds(wake.at)),
    )
    NoticeJob(pending:) -> #("notice", int.to_string(pending.id))
    TriggerJob(submitted:) -> #("trigger", int.to_string(submitted.id))
  }
}

fn wake_parameters(query: pog.Query(a), wake: Wake) -> pog.Query(a) {
  query
  |> pog.parameter(pog.text(wake.point))
  |> pog.parameter(pog.text(wake.occurrence))
  |> pog.parameter(pog.int(wire.milliseconds(wake.at)))
}

fn wake_decoder() -> decode.Decoder(Wake) {
  use point <- decode.field(0, decode.string)
  use occurrence <- decode.field(1, decode.string)
  use at <- decode.field(2, decode.int)
  decode.success(Wake(point:, occurrence:, at: wire.from_milliseconds(at)))
}

fn rows(
  query: pog.Query(a),
  connection: pog.Connection,
) -> Result(List(a), StoreError) {
  pog.execute(query, connection)
  |> result.map(fn(returned) { returned.rows })
  |> result.map_error(sql.store_error)
}
