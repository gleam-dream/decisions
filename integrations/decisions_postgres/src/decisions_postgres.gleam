//// The PostgreSQL store for `decisions`: the storage port over the
//// application's own transactions, the migrations that create its tables,
//// the Grind workers that deliver wake-ups and settlement notices after a
//// restart, and a thin transaction helper.
////
//// ```gleam
//// import decisions
//// import decisions_postgres
//// import grind
////
//// // Before the runtime starts: a store, desks over its port, workers.
//// let jobs = grind.named(grind_name)
//// let store = decisions_postgres.new(jobs)
//// let refunds = decisions.desk(refund_point(), drives:, under:, over: decisions_postgres.port(store))
//// let config =
////   grind.new(pool_config)
////   |> grind.with_worker(decisions_postgres.wake_worker(store, [decisions.waker(refunds)]))
////
//// // At deploy time, or at start-up where the role may run DDL.
//// let assert Ok(Nil) = decisions_postgres.migrate(grind.connection(jobs))
////
//// // A request: the verb runs in a transaction of its own.
//// let db = grind.connection(jobs)
//// case decisions_postgres.transaction(db, decisions.recommend(refunds, _, proposal)) {
////   Ok(waiting) -> show(waiting)
////   Error(decisions_postgres.Refused(refusal)) -> explain(refusal)
////   Error(decisions_postgres.Conflict(_)) -> retry()
////   Error(_) -> try_later()
//// }
//// ```
////
//// ## Who owns what
////
//// | Piece | Owner |
//// | --- | --- |
//// | The connection pool and the Grind runtime | The application (`grind.supervised`, or a pool it starts) |
//// | The workers' registration | The application: `grind.with_worker(wake_worker(..))`, and `settlement_worker(..)` when a point has followers |
//// | The schema | One migration owner: `migrate` at deploy time, or the SQL in `priv/migrations` through the application's tool |
//// | Grind's own schema, at version 14 or later | The application, through Grind: `grind.migrate`, `grind.with_startup_migration`, or Grind's migration files in its tool |
//// | The tables' rows | This package, through the port and the workers |
////
//// ## Guarantees and what provides them
////
//// | Guarantee | Mechanism |
//// | --- | --- |
//// | Entries are never changed or removed | A statement trigger on `decisions_entries` refuses `UPDATE`, `DELETE` and `TRUNCATE` |
//// | A sequence number is held once | Primary key `decisions_entries_pkey (occurrence_id, seq)` |
//// | Entries follow each other without a gap | Foreign key `decisions_entries_no_gap`: entry `n` references entry `n - 1` of its occurrence |
//// | At most one release per occurrence | Unique index `decisions_entries_one_release` on released entries |
//// | Only known entry kinds | Check `decisions_entries_kind`, equal to `decisions/entry.kinds` |
//// | Only known head statuses | Check `decisions_occurrences_status`, equal to `decisions/store.statuses` |
//// | One admission per id, under concurrent deliveries | `load` locks the head row, or an advisory lock on the id when there is no row yet |
//// | A tool that writes and refuses leaves nothing | `atomically` is a savepoint |
//// | The store's clock | `clock_timestamp()` at the moment of the call (never `now()`, the transaction's start), truncated to the millisecond that entries keep |
//// | A savepoint whose tool raises leaves nothing | `atomically` rolls back to the savepoint, then raises again |
//// | Wake-ups survive a restart, and a cancelled one does nothing | A row in `decisions_wakes` per wake-up and a Grind job admitted in the same transaction; the job delivers only while its row is pending |
//// | One settlement notice per occurrence | Unique constraint `decisions_settled_once` |
//// | A notice reaches what follows, once per database effect | A Grind job admitted in the settling transaction; the follower runs in the transaction that marks the notice delivered |
//// | A delivery abandoned again and again ends set aside, not pending for ever | Each worker replays an expired lease 10 times, then its declared Grind settlement replays at most `authorized_replay_limit` more times and sets the row aside |
////
//// The port reports an integrity violation (SQLSTATE class 23) as
//// `store.Conflict`; a deadlock, a serialization failure or a lock wait
//// that timed out as `store.Contended`; every other failure as
//// `store.Unavailable`.
////
//// Every transaction that uses the port must run at `READ COMMITTED`, the
//// PostgreSQL default and what Grind's `submit_in` requires. The port
//// relies on it: each statement takes a new snapshot, so a read made after
//// a lock is granted sees what the lock's previous holder committed. That
//// is how `decisions.happened`, after taking the subject's lock, sees a key
//// an earlier admission `expect`ed. Under REPEATABLE READ or SERIALIZABLE
//// the snapshot is the transaction's first, and the second of two
//// admissions about one subject would miss the first. So `load`
//// (`decisions_load`, which every verb reaches first) refuses a transaction
//// at another level with `store.Conflict` naming the level, in the same
//// statement, without a round trip of its own.
////
//// Admitting a trigger: call `decisions.happened` first and
//// `decisions.expect` after, in one transaction. `happened` takes the
//// subject's lock (`decisions.subject_lock`, an id that never holds
//// entries; `load` locks it with an advisory lock and stores nothing), so
//// two admissions about one subject run one after the other. In the other
//// order, two admissions can each hold what the other waits for;
//// PostgreSQL detects the deadlock and one transaction ends `Contended`.
////
//// The tables are created in the schema of the migrating transaction's
//// `search_path` and are named without a schema, so every connection that
//// uses the port must resolve them through its `search_path`.

import decisions.{type Card, type Desk, type Refusal}
import decisions/occurrence.{type Occurrence}
import decisions/store.{
  type Head, type Inspection, type Port, type StoreError, type Stored, Head,
  Inspection, Notice, Port, Stored, Wake,
}
import decisions/vocabulary.{type Ref, type Subject, type Verdict, Subject}
import decisions/wire
import decisions_postgres/internal/migrations
import decisions_postgres/internal/sql
import decisions_postgres/telemetry
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import grind
import grind/abandoned.{type Abandoned}
import grind/admin
import grind/job
import grind/worker
import pog
import sinal

// -- The store ------------------------------------------------------------------

/// What the port needs beyond the caller's transaction: the Grind runtime
/// that admits wake-up and settlement jobs, the queue they run in, and the
/// points whose settlements have a follower. Build it with `new` before the
/// runtime starts; `grind.named` gives a handle that is valid before then.
pub opaque type Store {
  Store(
    jobs: grind.Grind,
    queue: String,
    followed: List(String),
    name: String,
    offset: Duration,
    settlement_attempts: Int,
    wake_attempts: Int,
    snooze_limit: Int,
    lock_timeout: Option(Duration),
  )
}

/// The Grind queue the jobs run in unless `with_queue` names another.
pub const default_queue = "decisions"

/// A store that admits its jobs through `jobs`, in the queue `"decisions"`,
/// and whose settlements have no follower yet.
pub fn new(jobs: grind.Grind) -> Store {
  Store(
    jobs:,
    queue: default_queue,
    followed: [],
    name: default_name,
    offset: duration.milliseconds(0),
    settlement_attempts: 20,
    wake_attempts: 20,
    snooze_limit: 1000,
    lock_timeout: Some(duration.seconds(4)),
  )
}

/// How long `load` waits for an occurrence's lock before the database
/// gives up, which the port reports as `store.Contended` (nothing written,
/// safe to run again); 4 seconds unless set, `None` to leave the
/// connection's own setting alone.
///
/// Why a default: `pog.transaction` checks a connection out for at most 5
/// seconds, and a transaction still waiting then loses its connection,
/// which reaches the caller as `Unavailable` (outcome unknown) for what
/// was only contention. Below that limit, a long lock wait ends as
/// contention by construction.
///
/// `load` sets it with `SET LOCAL` semantics (`set_config(.., true)`), so
/// it applies to the rest of the caller's transaction too, and it
/// **overrides** a `lock_timeout` the caller set earlier in that
/// transaction. With `None`, the caller's setting, or the role's, is
/// respected.
pub fn with_lock_timeout(store: Store, timeout: Option(Duration)) -> Store {
  Store(..store, lock_timeout: timeout)
}

/// How many times a wake-up or a notice may be delivered again without an
/// outcome (a store that stays contended or unavailable, a wake-up that
/// keeps arriving early) before it is set aside and reported with
/// `telemetry.set_aside`; 1 000 unless set, at least 1. Each is a Grind
/// snooze, which uses no attempt. Set on the store whose port admits the
/// jobs.
pub fn with_snooze_limit(store: Store, limit: Int) -> Store {
  Store(..store, snooze_limit: int.max(1, limit))
}

/// How many counted attempts a wake-up gets before it is set aside; 20
/// unless set, at least 1. An attempt is counted when `decisions.handling`
/// says `Backoff`: a conflict, a policy that cannot be read, a consulted
/// point that cannot be asked, a tool that answered `Unsure`. Grind records
/// a job's attempt limit when the job is admitted, so this is set on the
/// store whose port admits the jobs.
pub fn with_wake_attempts(store: Store, attempts: Int) -> Store {
  Store(..store, wake_attempts: int.max(1, attempts))
}

/// How many attempts a settlement delivery whose follower keeps failing
/// with `decisions.ApplicationFailed` gets before its notice is set aside;
/// 20 unless set, at least 1. Grind records a job's attempt limit when the
/// job is admitted, so this is set on the store whose port admits the jobs,
/// not on the registered worker.
pub fn with_settlement_attempts(store: Store, attempts: Int) -> Store {
  Store(..store, settlement_attempts: int.max(1, attempts))
}

/// The name a store's telemetry carries unless `with_name` gives another.
pub const default_name = "decisions"

/// Name the store, so its telemetry events can be told from another
/// store's on the same node: every event's metadata carries it as `source`.
pub fn with_name(store: Store, name: String) -> Store {
  Store(..store, name:)
}

/// The store's name, as its telemetry carries it.
pub fn name(store: Store) -> String {
  store.name
}

/// **For tests.** The store's clock reads the database's clock plus
/// `offset`, so a test can stand an hour later without waiting: build a
/// second store with a larger offset and a desk over its port. The wake-up
/// jobs it admits are scheduled on the database's clock, at the time the
/// store's clock reaches theirs, and the worker built from this store
/// measures an early wake-up on this clock. An application in production
/// leaves it at zero.
pub fn with_clock_offset(store: Store, offset: Duration) -> Store {
  Store(..store, offset:)
}

/// Run the wake-up and settlement jobs in `queue`. The workers built from
/// this store run in the same queue.
pub fn with_queue(store: Store, queue: String) -> Store {
  Store(..store, queue:)
}

/// Settlements of `point` have a follower: the settling transaction admits
/// a job that delivers the notice to it (`settlement_worker`). Without
/// this, a settlement is recorded in `decisions_settled` and nothing is
/// delivered.
pub fn following(store: Store, point: String) -> Store {
  Store(..store, followed: [point, ..store.followed])
}

// -- The port --------------------------------------------------------------------

/// The storage port. Every function runs in the connection it is given:
/// in the caller's open transaction, so a verb, the application's own
/// writes and the gated tool's commit or roll back together; or on the
/// pool, where each call commits by itself.
///
/// - `load` is one statement (`decisions_load`): it locks the head row,
///   or, when there is none, an advisory lock on the id and then the row
///   again, and reads the entries after the lock is held. An id with no
///   row, such as `decisions.subject_lock`, is locked and nothing is
///   stored for it. It refuses a transaction that is not READ COMMITTED
///   with `store.Conflict`. It first sets the
///   transaction's `lock_timeout` (`with_lock_timeout`, 4 s by default), so
///   a long lock wait ends as `store.Contended`.
/// - `append` is one statement (`decisions_append`): the head, the entries,
///   the queue rows and a `NOTIFY` on channel `decisions_changed`. The
///   database refuses a repeated sequence number, a gap and a second
///   release, which the port reports as `store.Conflict`. An occurrence id
///   or point name longer than `max_name_bytes` (255) is refused at once
///   with a `store.Conflict` that says so. With no entries, the head is
///   replaced.
/// - `schedule` keeps the pending wake-ups whose time is still wanted,
///   removes the others, and admits a Grind job for each new one.
/// - `settled` admits the notice, and a Grind job for it when the point
///   has a follower (`following`).
/// - `atomically` is a savepoint.
/// - `now` is the database's clock to the millisecond.
/// - `new_id` is a UUID version 7 made on this node.
pub fn port(store: Store) -> Port(pog.Connection) {
  Port(
    load: fn(tx, id) { load(store, tx, id) },
    append:,
    waiting:,
    schedule: fn(tx, point, occurrence, times) {
      schedule(store, tx, point, occurrence, times)
    },
    settled: fn(tx, point, occurrence) { settled(store, tx, point, occurrence) },
    atomically:,
    now: fn(tx) { clock(store, tx) },
    new_id: fn(_) { sql.new_id() },
  )
}

/// The store's clock: the database's, plus the store's test offset.
fn clock(store: Store, tx: pog.Connection) -> Timestamp {
  timestamp.add(sql.now(tx), store.offset)
}

fn load(
  store: Store,
  tx: pog.Connection,
  id: String,
) -> Result(List(Stored), StoreError) {
  pog.query("SELECT seq, at_ms, kind, event FROM decisions_load($1, $2)")
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.nullable(
    fn(timeout) {
      pog.text(int.to_string(duration.to_milliseconds(timeout)) <> "ms")
    },
    store.lock_timeout,
  ))
  |> pog.returning({
    use seq <- decode.field(0, decode.int)
    use at <- decode.field(1, sql.time())
    use kind <- decode.field(2, decode.string)
    use event <- decode.field(3, decode.string)
    decode.success(Stored(seq:, at:, kind:, event:))
  })
  |> sql.run(tx)
}

/// The longest occurrence id and point name the store keeps, in bytes.
/// Checked before every append (and by the constraints
/// `decisions_occurrences_id_length` and `decisions_occurrences_point_length`)
/// so that the `NOTIFY` payload, which PostgreSQL limits to 8 000 bytes,
/// stays bounded.
pub const max_name_bytes = 255

fn append(
  tx: pog.Connection,
  id: String,
  head: Head,
  entries: List(Stored),
) -> Result(Nil, StoreError) {
  let too_long = fn(what, value) {
    store.Conflict(
      what
      <> " is "
      <> int.to_string(string.byte_size(value))
      <> " bytes; the store keeps at most "
      <> int.to_string(max_name_bytes),
    )
  }
  case
    string.byte_size(id) > max_name_bytes,
    string.byte_size(head.point) > max_name_bytes
  {
    True, _ -> Error(too_long("the occurrence id", id))
    _, True -> Error(too_long("the point name", head.point))
    False, False ->
      // With no entries the head is still replaced, as the port says.
      pog.query(
        "SELECT decisions_append($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)",
      )
      |> pog.parameter(pog.text(id))
      |> pog.parameter(pog.text(head.point))
      |> pog.parameter(pog.text(head.subject.kind))
      |> pog.parameter(pog.text(head.subject.id))
      |> pog.parameter(pog.text(store.status_name(head.status)))
      |> pog.parameter(pog.array(pog.text, head.awaiting))
      |> pog.parameter(pog.array(pog.text, head.approved))
      |> pog.parameter(pog.array(pog.text, head.may_not_decide))
      |> pog.parameter(pog.nullable(sql.at, head.due))
      |> pog.parameter(sql.at(head.arrived))
      |> pog.parameter(pog.bool(head.review_pending))
      |> pog.parameter(pog.array(pog.int, list.map(entries, fn(e) { e.seq })))
      |> pog.parameter(pog.array(sql.at, list.map(entries, fn(e) { e.at })))
      |> pog.parameter(pog.array(pog.text, list.map(entries, fn(e) { e.kind })))
      |> pog.parameter(pog.array(pog.text, list.map(entries, fn(e) { e.event })))
      |> sql.run(tx)
      |> result.replace(Nil)
  }
}

fn waiting(
  tx: pog.Connection,
  point: String,
  subject: Subject,
) -> Result(List(String), StoreError) {
  // The statuses `store.is_waiting` accepts, named here so the partial
  // index `decisions_occurrences_waiting` serves the query
  // (`migrations_test` checks the two agree). In id order (the column's
  // collation is "C", byte order), so every transaction that locks several
  // occurrences locks them in one order. Set-aside records are left out.
  pog.query(
    "SELECT id FROM decisions_occurrences
     WHERE point = $1 AND subject_kind = $2 AND subject_id = $3
       AND status IN ('pending', 'recommended', 'awaiting', 'held')
       AND set_aside_at IS NULL
     ORDER BY id",
  )
  |> pog.parameter(pog.text(point))
  |> pog.parameter(pog.text(subject.kind))
  |> pog.parameter(pog.text(subject.id))
  |> pog.returning(decode.at([0], decode.string))
  |> sql.run(tx)
}

fn schedule(
  store: Store,
  tx: pog.Connection,
  point: String,
  occurrence: String,
  times: List(Timestamp),
) -> Result(Nil, StoreError) {
  use tx <- sql.within(tx)
  // Pending wake-ups whose time is still wanted stay with their job; the
  // others are removed, so their jobs find nothing and do nothing.
  use added <- result.try(
    pog.query(
      "WITH gone AS (
         DELETE FROM decisions_wakes
         WHERE point = $1 AND occurrence_id = $2 AND set_aside_at IS NULL
           AND NOT (decisions_ms(at) = ANY ($3::bigint[]))
       )
       INSERT INTO decisions_wakes (point, occurrence_id, at)
       SELECT DISTINCT $1, $2, decisions_at(t) FROM unnest($3::bigint[]) AS t
       ON CONFLICT (point, occurrence_id, at) WHERE set_aside_at IS NULL
       DO NOTHING
       RETURNING id, decisions_ms(at)",
    )
    |> pog.parameter(pog.text(point))
    |> pog.parameter(pog.text(occurrence))
    |> pog.parameter(pog.array(sql.at, times))
    |> pog.returning({
      use id <- decode.field(0, decode.int)
      use at <- decode.field(1, sql.time())
      decode.success(#(id, at))
    })
    |> sql.run(tx),
  )
  list.try_each(added, fn(row) {
    let #(id, at) = row
    admit_wake(
      store,
      tx,
      WakeJob(wake: id, point:, occurrence:, at_ms: wire.milliseconds(at)),
      "decisions.wake:" <> int.to_string(id),
    )
  })
}

fn settled(
  store: Store,
  tx: pog.Connection,
  point: String,
  occurrence: String,
) -> Result(Nil, StoreError) {
  use tx <- sql.within(tx)
  use ids <- result.try(
    pog.query(
      "INSERT INTO decisions_settled (point, occurrence_id) VALUES ($1, $2)
       RETURNING id",
    )
    |> pog.parameter(pog.text(point))
    |> pog.parameter(pog.text(occurrence))
    |> pog.returning(decode.at([0], decode.int))
    |> sql.run(tx),
  )
  case list.contains(store.followed, point), ids {
    True, [id] ->
      admit_notice(
        store,
        tx,
        NoticeJob(notice: id, point:, occurrence:),
        "decisions.settlement:" <> int.to_string(id),
      )
    _, _ -> Ok(Nil)
  }
}

/// Admit a wake-up's job in `tx` and keep its Grind id on the row, so
/// `sweep` can tell a row whose job ended from one whose job waits.
fn admit_wake(
  store: Store,
  tx: pog.Connection,
  input: WakeJob,
  submission: String,
) -> Result(Nil, StoreError) {
  job.new(wake_definition(store, never_runs), input)
  |> job.with_id(submission)
  |> job.with_queue(store.queue)
  // Grind waits on the database's clock; the store's may be offset.
  |> job.at(timestamp.add(
    wire.from_milliseconds(input.at_ms),
    duration.milliseconds(0 - duration.to_milliseconds(store.offset)),
  ))
  |> admit(store, tx, _)
  |> result.try(record_job(tx, "decisions_wakes", input.wake, _))
}

fn admit_notice(
  store: Store,
  tx: pog.Connection,
  input: NoticeJob,
  submission: String,
) -> Result(Nil, StoreError) {
  job.new(settlement_definition(store, never_runs), input)
  |> job.with_id(submission)
  |> job.with_queue(store.queue)
  |> admit(store, tx, _)
  |> result.try(record_job(tx, "decisions_settled", input.notice, _))
}

fn record_job(
  tx: pog.Connection,
  table: String,
  id: Int,
  job_id: Int,
) -> Result(Nil, StoreError) {
  pog.query("UPDATE " <> table <> " SET job_id = $2 WHERE id = $1")
  |> pog.parameter(pog.int(id))
  |> pog.parameter(pog.int(job_id))
  |> sql.run(tx)
  |> result.replace(Nil)
}

fn admit(
  store: Store,
  tx: pog.Connection,
  submitted: job.Job(input, output, error),
) -> Result(Int, StoreError) {
  grind.submit_in(store.jobs, tx, submitted)
  |> result.map(fn(admission) { job.id(grind.handle(admission)) })
  |> result.map_error(fn(error) {
    store.Unavailable(
      "the job was not admitted: " <> grind.describe_submit_error(error),
    )
  })
}

fn atomically(
  tx: pog.Connection,
  body: fn(pog.Connection) -> Result(List(Ref), String),
) -> Result(Result(List(Ref), String), StoreError) {
  case sql.is_pool(tx) {
    // Outside a transaction the body gets one of its own.
    True ->
      case pog.transaction(tx, body) {
        Ok(relied) -> Ok(Ok(relied))
        Error(pog.TransactionRolledBack(reason)) -> Ok(Error(reason))
        Error(pog.TransactionQueryError(error)) -> Error(sql.store_error(error))
      }
    False -> {
      // A name of its own, so a savepoint nested inside another (a tool
      // that drives another point's verb) never rolls back to the wrong
      // one.
      let name = "decisions_tool_" <> int.to_string(sql.unique())
      let statement = fn(text) {
        pog.query(text) |> sql.run(tx) |> result.replace(Nil)
      }
      use Nil <- result.try(statement("SAVEPOINT " <> name))
      // A body that raises is rolled back to the savepoint before the
      // raise goes on, so a caller that catches it keeps a usable
      // transaction without the body's writes.
      let ran =
        sql.on_raise(fn() { body(tx) }, fn() {
          statement("ROLLBACK TO SAVEPOINT " <> name)
        })
      case ran {
        Ok(relied) ->
          statement("RELEASE SAVEPOINT " <> name) |> result.replace(Ok(relied))
        Error(reason) ->
          statement("ROLLBACK TO SAVEPOINT " <> name)
          |> result.replace(Error(reason))
      }
    }
  }
}

// -- Inspection ------------------------------------------------------------------------

/// What `decisions/conformance` and `decisions/testing` read: every record
/// of a point, a head, the pending wake-ups and the settlement notices.
/// The desk never reads through it.
pub fn inspection() -> Inspection(pog.Connection) {
  Inspection(
    occurrences: fn(tx, point) {
      pog.query("SELECT id FROM decisions_occurrences WHERE point = $1")
      |> pog.parameter(pog.text(point))
      |> pog.returning(decode.at([0], decode.string))
      |> sql.run(tx)
    },
    head: fn(tx, id) {
      pog.query(
        "SELECT point, subject_kind, subject_id, status, awaiting,
                decisions_ms(due), decisions_ms(arrived), approved,
                may_not_decide, review_pending
         FROM decisions_occurrences WHERE id = $1",
      )
      |> pog.parameter(pog.text(id))
      |> pog.returning(head_decoder())
      |> sql.run(tx)
      |> result.map(fn(rows) { list.first(rows) |> option.from_result })
    },
    wakes: fn(tx) {
      pog.query(
        "SELECT point, occurrence_id, decisions_ms(at) FROM decisions_wakes
         WHERE set_aside_at IS NULL ORDER BY id",
      )
      |> pog.returning({
        use point <- decode.field(0, decode.string)
        use occurrence <- decode.field(1, decode.string)
        use at <- decode.field(2, sql.time())
        decode.success(Wake(point:, occurrence:, at:))
      })
      |> sql.run(tx)
    },
    notices: fn(tx) {
      pog.query(
        "SELECT point, occurrence_id FROM decisions_settled ORDER BY id",
      )
      |> pog.returning({
        use point <- decode.field(0, decode.string)
        use occurrence <- decode.field(1, decode.string)
        decode.success(Notice(point:, occurrence:))
      })
      |> sql.run(tx)
    },
  )
}

fn head_decoder() -> decode.Decoder(Head) {
  use point <- decode.field(0, decode.string)
  use kind <- decode.field(1, decode.string)
  use id <- decode.field(2, decode.string)
  use status <- decode.field(3, status_decoder())
  use awaiting <- decode.field(4, decode.list(decode.string))
  use due <- decode.field(5, decode.optional(sql.time()))
  use arrived <- decode.field(6, sql.time())
  use approved <- decode.field(7, decode.list(decode.string))
  use may_not_decide <- decode.field(8, decode.list(decode.string))
  use review_pending <- decode.field(9, decode.bool)
  decode.success(Head(
    point:,
    subject: Subject(kind:, id:),
    status:,
    awaiting:,
    due:,
    arrived:,
    approved:,
    may_not_decide:,
    review_pending:,
  ))
}

/// A status column, decoded.
pub fn status_decoder() -> decode.Decoder(store.Status) {
  use name <- decode.then(decode.string)
  case store.parse_status(name) {
    Ok(status) -> decode.success(status)
    Error(Nil) -> decode.failure(store.Pending, "a head status")
  }
}

// -- Migrations ------------------------------------------------------------------------

/// Why `migrate` failed.
pub type MigrateError {
  /// The database was unreachable or refused a statement (`reason`). The
  /// migration runs in one transaction, so it applied nothing, unless the
  /// failure was the reply to its commit; running `migrate` again is safe.
  MigrationFailed(reason: String)
}

/// The error as one line, for a log.
pub fn describe_migrate_error(error: MigrateError) -> String {
  case error {
    MigrationFailed(reason:) ->
      "decisions_postgres migration failed: " <> reason
  }
}

/// Bring the tables up to date: apply, in one transaction, each numbered
/// migration not applied yet, and record each in
/// `decisions_schema_migrations`. Safe to run again and from several nodes
/// at once: an advisory lock serialises them, and a later one finds
/// nothing to do. A database migrated further by a newer version of this
/// package is left as it is.
///
/// It creates tables, indexes, functions and a trigger, so the role that
/// runs it must own DDL. Run it at deploy time, or at start-up only where
/// the application's role may own DDL. The same migrations are in
/// `priv/migrations/` for an application that applies migrations with its
/// own tool; choose one migration owner per database.
pub fn migrate(db: pog.Connection) -> Result(Nil, MigrateError) {
  pog.transaction(db, fn(tx) {
    let run = fn(text) {
      pog.query(text)
      |> pog.timeout(60_000)
      |> pog.execute(tx)
      |> result.replace(Nil)
    }
    use Nil <- result.try(run("SET TRANSACTION ISOLATION LEVEL READ COMMITTED"))
    use Nil <- result.try(run(migrations.lock))
    use marked <- result.try(
      pog.query("SELECT to_regclass('decisions_schema_migrations') IS NOT NULL")
      |> pog.returning(decode.at([0], decode.bool))
      |> pog.execute(tx)
      |> result.map(fn(returned) { returned.rows == [True] }),
    )
    use applied <- result.try(case marked {
      False -> Ok(0)
      True ->
        pog.query(
          "SELECT coalesce(max(version), 0) FROM decisions_schema_migrations",
        )
        |> pog.returning(decode.at([0], decode.int))
        |> pog.execute(tx)
        |> result.map(fn(returned) {
          list.first(returned.rows) |> result.unwrap(0)
        })
    })
    migrations.all()
    |> list.filter(fn(migration) { migration.version > applied })
    |> list.try_each(fn(migration) { list.try_each(migration.up, run) })
  })
  |> result.map_error(fn(error) {
    MigrationFailed(case error {
      pog.TransactionQueryError(error) | pog.TransactionRolledBack(error) ->
        sql.describe(error)
    })
  })
}

// -- The transaction helper ----------------------------------------------------------

/// Why a verb run through `transaction` or `decide` did not do what was
/// asked. In every case its transaction rolled back.
pub type Failure {
  /// The verb refused: the occurrence is not waiting, the validator may
  /// not decide it, the gated tool refused, and so on. Retrying the same
  /// call gives the same answer until something else changes.
  Refused(refusal: Refusal)
  /// The verb refused, and the second transaction that keeps the refusal
  /// on the record (`decisions.record_refusal`) failed with `detail`. The
  /// record may not show the attempt; when the failure was the reply to
  /// that transaction's commit, it may. `record_refusal` is safe to repeat
  /// with the same `Rollback`: it appends once.
  RefusedUnrecorded(refusal: Refusal, detail: String)
  /// The database refused a write that breaks the record's rules. Running
  /// the whole call again is safe: it reads the record again. A conflict
  /// that repeats points at a writer that does not take the lock.
  Conflict(detail: String)
  /// Contention: a deadlock, a serialization failure or a lock wait that
  /// timed out. Nothing was written; running the call again is safe.
  Contended(detail: String)
  /// The database could not do it and the outcome may be unknown: a lost
  /// connection, a query timeout, or a failure in the reply to the commit,
  /// after which the commit may have happened. The verbs are safe to send
  /// again on what they find (`recommend_once` finds what it made, the
  /// same verdict on the same card stands); read the record first for
  /// anything else.
  Unavailable(detail: String)
}

/// The failure as one line, for a person or a log.
pub fn describe(failure: Failure) -> String {
  case failure {
    Refused(refusal:) -> decisions.describe(refusal)
    RefusedUnrecorded(refusal:, detail:) ->
      decisions.describe(refusal) <> " (not recorded: " <> detail <> ")"
    Conflict(detail:) -> "conflict: " <> detail
    Contended(detail:) -> "contention, nothing written: " <> detail
    Unavailable(detail:) -> "store unavailable: " <> detail
  }
}

/// Run `body` in a transaction of its own on `db` (a pool): commit on `Ok`,
/// roll back on `Error` or a crash. `body` is usually one verb, such as
/// `decisions.recommend(desk, _, proposal)`, with any writes of the
/// application's own that must commit with it.
///
/// It is optional: an application that manages its own transaction calls
/// the verbs with that transaction's connection directly.
pub fn transaction(
  db: pog.Connection,
  body: fn(pog.Connection) -> Result(a, Refusal),
) -> Result(a, Failure) {
  pog.transaction(db, body) |> result.map_error(failure_of)
}

fn failure_of(error: pog.TransactionError(Refusal)) -> Failure {
  case error {
    pog.TransactionRolledBack(decisions.StoreFailed(store.Conflict(detail:))) ->
      Conflict(detail:)
    pog.TransactionRolledBack(decisions.StoreFailed(store.Contended(detail:))) ->
      Contended(detail:)
    pog.TransactionRolledBack(decisions.StoreFailed(store.Unavailable(detail:))) ->
      Unavailable(detail:)
    pog.TransactionRolledBack(refusal) -> Refused(refusal:)
    pog.TransactionQueryError(error) ->
      case sql.store_error(error) {
        store.Conflict(detail:) -> Conflict(detail:)
        store.Contended(detail:) -> Contended(detail:)
        store.Unavailable(detail:) -> Unavailable(detail:)
      }
  }
}

/// Why a body run by `transaction_with` ended without committing: a verb
/// of the desk refused, or the application's own work failed with its own
/// error. (Not to be confused with `decisions.Stop`, what a guard or a
/// gated tool answers.)
pub type BodyFailure(error) {
  /// A verb refused, or the store failed under it.
  Desk(refusal: Refusal)
  /// The application's own error, kept as its type.
  Own(error: error)
}

/// A verb's result as a step of a `transaction_with` body:
///
/// ```gleam
/// decisions_postgres.transaction_with(db, fn(tx) {
///   use waiting <- result.try(
///     decisions.recommend(desk, tx, proposal) |> decisions_postgres.desk,
///   )
///   use Nil <- result.try(save_request(tx, waiting.id) |> result.map_error(Own))
///   Ok(waiting)
/// })
/// ```
pub fn desk(result: Result(a, Refusal)) -> Result(a, BodyFailure(error)) {
  result.map_error(result, Desk)
}

/// Why `transaction_with` did not commit.
pub type Failed(error) {
  /// The library's failure, as `transaction` reports it: a refusal, a
  /// conflict, contention, or an unavailable store.
  LibraryFailed(failure: Failure)
  /// The application's own error. The transaction rolled back.
  OwnFailed(error: error)
}

/// `transaction` for a body that also does the application's own work,
/// such as writing its own rows, and can fail with the application's own
/// error. Both kinds of failure stay typed: a verb's refusal (lift it with
/// `desk`) becomes `LibraryFailed`, classified exactly as `transaction`
/// classifies it; the application's error (`Own`) becomes
/// `OwnFailed`. The transaction commits on `Ok` and rolls back
/// otherwise.
pub fn transaction_with(
  db: pog.Connection,
  body: fn(pog.Connection) -> Result(a, BodyFailure(error)),
) -> Result(a, Failed(error)) {
  case pog.transaction(db, body) {
    Ok(value) -> Ok(value)
    Error(pog.TransactionRolledBack(Own(error:))) -> Error(OwnFailed(error:))
    Error(pog.TransactionRolledBack(Desk(refusal:))) ->
      Error(LibraryFailed(failure_of(pog.TransactionRolledBack(refusal))))
    Error(pog.TransactionQueryError(error)) ->
      Error(LibraryFailed(failure_of(pog.TransactionQueryError(error))))
  }
}

/// `transaction` in the shape of a verb: its failure is a `Refusal`, as
/// `decisions_otp/isolated.recommend` and `recommend_when` want for their
/// `in:`. A refusal the body returns is returned as it is (its
/// transaction rolled back); a failure of the transaction itself becomes
/// `StoreFailed` with its classification kept: contention stays
/// `Contended`, a lost connection or an unknown commit stays `Unavailable`.
///
/// ```gleam
/// isolated.recommend_when(desk, in: decisions_postgres.refusing(db, _), ..)
/// ```
pub fn refusing(
  db: pog.Connection,
  body: fn(pog.Connection) -> Result(a, Refusal),
) -> Result(a, Refusal) {
  case pog.transaction(db, body) {
    Ok(value) -> Ok(value)
    Error(pog.TransactionRolledBack(refusal)) -> Error(refusal)
    Error(pog.TransactionQueryError(error)) ->
      Error(decisions.StoreFailed(sql.store_error(error)))
  }
}

/// Give a verdict in a transaction of its own: `card` opens or resumes the
/// card in that transaction, then `decisions.decide` runs. When the gated
/// tool or its guard refuses, the transaction rolls back, and a second
/// transaction keeps the refused verdict on the record with
/// `decisions.record_refusal` and the refusal's `Rollback`; the result is
/// then `Error(Refused(ToolRefused(..)))`.
///
/// Resume the card from a `Ticket` (`decisions.resume`) where the card was
/// opened in an earlier request: a card opened inside the transaction that
/// rolled back names a showing the record no longer holds.
pub fn decide(
  db: pog.Connection,
  desk: Desk(o, pog.Connection),
  card: fn(pog.Connection) -> Result(Card(o), Refusal),
  verdict: Verdict(o),
) -> Result(Occurrence(o), Failure) {
  let ran =
    pog.transaction(db, fn(tx) {
      use card <- result.try(card(tx))
      decisions.decide(desk, tx, card, verdict)
    })
  case ran {
    Ok(decided) -> Ok(decided)
    Error(pog.TransactionRolledBack(
      decisions.ToolRefused(rollback:, ..) as refusal,
    )) ->
      case transaction(db, decisions.record_refusal(desk, _, rollback)) {
        Ok(_) -> Error(Refused(refusal:))
        Error(failure) ->
          Error(RefusedUnrecorded(refusal:, detail: describe(failure)))
      }
    Error(error) -> Error(failure_of(error))
  }
}

// -- Setting aside --------------------------------------------------------------------

/// Set aside an occurrence whose entries no longer decode with its point's
/// codec, so it blocks nothing: it leaves every validator's queue
/// (`decisions_awaiting`), `waiting` no longer returns it, and its pending
/// wake-ups are set aside with it. Its entries stay as they are, and
/// `decisions_postgres/queue.set_aside` lists it. The wake-up worker does
/// this by itself when a delivery finds the record unreadable.
///
/// Returns the occurrence's point, or `None` when no such occurrence
/// exists or it was set aside already.
pub fn set_aside(
  tx: pog.Connection,
  occurrence id: String,
  because reason: String,
) -> Result(Option(String), StoreError) {
  pog.query(
    "WITH head AS (
       UPDATE decisions_occurrences
       SET set_aside_at = clock_timestamp(), set_aside_reason = $2
       WHERE id = $1 AND set_aside_at IS NULL
       RETURNING point
     ), queues AS (
       DELETE FROM decisions_awaiting WHERE occurrence_id = $1
     ), wakes AS (
       UPDATE decisions_wakes
       SET set_aside_at = clock_timestamp(), set_aside_reason = $2
       WHERE occurrence_id = $1 AND set_aside_at IS NULL
     )
     SELECT point FROM head",
  )
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.text(reason))
  |> pog.returning(decode.at([0], decode.string))
  |> sql.run(tx)
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

// -- Wake-ups ---------------------------------------------------------------------------

/// A wake-up job's input: the wake-up's row in `decisions_wakes`, and,
/// for logs and telemetry, its point, occurrence and time.
pub type WakeJob {
  WakeJob(wake: Int, point: String, occurrence: String, at_ms: Int)
}

/// One point's wake handler, as `decisions.waker(desk)` returns it.
pub type Waker =
  #(String, fn(pog.Connection, String) -> Result(Option(Timestamp), Refusal))

/// The Grind worker that delivers wake-ups. Register it with
/// `grind.with_worker` on every node that should deliver them, with the
/// waker of every point that has holds, validity or escalation steps:
/// `wake_worker(store, [decisions.waker(refunds), decisions.waker(replies)])`.
///
/// One delivery is one transaction on the runtime's pool:
///
/// 1. When the wake-up's row is no longer pending (it was cancelled,
///    replaced, delivered or set aside), nothing happens.
/// 2. Otherwise the point's waker runs. When it is done (`None`), the row
///    is removed in the same transaction. When it answers `Some(until)`,
///    the wake-up came early; the row stays and the job is delivered again
///    at `until` (a Grind snooze).
///
/// Delivery is at least once. A job delivered twice, or replayed after its
/// worker was killed between the commit and Grind's acknowledgement, finds
/// its row gone and does nothing, and `decisions.wake` itself does nothing
/// when nothing is due.
///
/// An attempt whose lease expires (its node died, or the delivery hung) is
/// replayed up to 10 times (`ReplayAfterLeaseExpiry`). When those replays
/// are used up, Grind holds the job uncertain and runs the worker's
/// declared settlement (`worker.with_settlement`; in Grind's sense: what
/// becomes of an abandoned job, not a decision's settlement or its
/// notice). It reads the wake-up's row in Grind's transaction and does
/// nothing else:
///
/// - The row is no longer pending: the job ends succeeded ("nothing
///   pending"), as a delivery that finds it gone does.
/// - A cancellation of the job was requested (Grind declines a replay
///   then): the job ends failed and the row stays pending; `sweep` gives it
///   a new job, since the row, not the Grind job, is the authority.
/// - Otherwise the delivery is replayed, at most `authorized_replay_limit`
///   (3) times per job; delivery is idempotent, so a replay is safe.
/// - After that the row is set aside with the reason, in the same
///   transaction, and the job ends failed with it. This setting aside
///   emits no `telemetry.set_aside`, because the settlement may run more
///   than once and keeps to database work; Grind reports the committed
///   settlement as `[grind, job, resolved]` and keeps the reason on the job.
///
/// Grind's schema must be at version 14 or later for this (see the
/// package README).
///
/// A refusal is acted on by `decisions.handling(DeskRefused(refusal))`
/// alone, the same rule as the settlement worker's:
///
/// - `Redeliver` (the store was contended or unavailable): the job is
///   snoozed for 2 seconds and delivered again. A snooze uses no attempt.
/// - `Backoff` (a conflict, a policy that cannot be read, a consulted
///   point that cannot be asked, a tool that answered `Unsure`): the
///   attempt is counted and retried with Grind's backoff (the registered
///   worker's retry policy); after the last attempt (`with_wake_attempts`,
///   20 unless set) the wake-up's row is set aside.
/// - `SetAside` (the record does not decode, the policy cannot be
///   published, facts that are not declared, an output that does not
///   encode, a key another point holds): the wake-up's row and the
///   occurrence are set aside (`set_aside`), so they block nothing.
/// - `Drop` (the record says nothing is left to do): the row is removed
///   and the job succeeds.
///
/// A waker that raises is treated as `Backoff`: counted, and set aside
/// after the last attempt. A wake-up delivered again without an outcome
/// (`Redeliver`, or arriving early) `with_snooze_limit` times (1 000 unless
/// set) is set aside rather than ended by Grind. With no waker for its
/// point, the wake-up's row is set aside. Setting aside emits
/// `telemetry.set_aside`; nothing drops a job silently. `sweep` gives a job
/// to any pending row left without one.
pub fn wake_worker(
  store: Store,
  wakers: List(Waker),
) -> worker.Worker(WakeJob, String, String) {
  wake_definition(store, fn(context, input) {
    deliver_wake(store, wakers, context, input)
  })
}

/// The worker's definition: its id, version, codecs, queue and policies,
/// which a submitted job records, around `handle`. The port submits jobs
/// with a definition whose handler never runs.
fn wake_definition(
  store: Store,
  handle: fn(worker.Context, WakeJob) -> worker.Response(String, String),
) -> worker.Worker(WakeJob, String, String) {
  worker.responding(
    "decisions.wake",
    input: worker.codec(
      worker.infallible(fn(wake: WakeJob) {
        json.object([
          #("wake", json.int(wake.wake)),
          #("point", json.string(wake.point)),
          #("occurrence", json.string(wake.occurrence)),
          #("at_ms", json.int(wake.at_ms)),
        ])
      }),
      {
        use wake <- decode.field("wake", decode.int)
        use point <- decode.field("point", decode.string)
        use occurrence <- decode.field("occurrence", decode.string)
        use at_ms <- decode.field("at_ms", decode.int)
        decode.success(WakeJob(wake:, point:, occurrence:, at_ms:))
      },
    ),
    output: text_codec(),
    handle:,
  )
  |> worker.with_queue(store.queue)
  |> worker.with_error_codec(text_codec())
  |> worker.with_abandonment(worker.ReplayAfterLeaseExpiry(replays))
  |> worker.with_settlement(settle_wake)
  // One snooze more than the limit, so the handler sets the wake-up aside
  // before Grind would end the job.
  |> worker.with_max_snoozes(store.snooze_limit + 1)
  |> worker.with_max_attempts(store.wake_attempts)
}

/// A handler for a definition that only submits jobs.
fn never_runs(
  _context: worker.Context,
  _input: input,
) -> worker.Response(String, String) {
  worker.Failed("this definition only submits jobs")
}

fn text_codec() -> worker.Codec(String) {
  worker.codec(worker.infallible(json.string), decode.string)
}

type WakeOutcome {
  NothingPending
  Done(lag_ms: Int)
  Early(until: Timestamp, now: Timestamp)
}

type WakeFailure {
  WakeStore(StoreError)
  WakeRefused(Refusal)
  /// The waker raised; treated as an application failure: counted.
  WakeRaised(String)
}

/// How long a delivery whose store was contended or unavailable waits
/// before it is tried again. It is a Grind snooze, which uses no attempt.
const retry_after_ms = 2000

fn deliver_wake(
  store: Store,
  wakers: List(Waker),
  context: worker.Context,
  input: WakeJob,
) -> worker.Response(String, String) {
  let db = worker.connection(context)
  let last_attempt = worker.attempt(context) >= worker.max_attempts(context)
  let snoozes_used = worker.snooze_count(context) >= store.snooze_limit
  case deliver_one(store, wakers, db, input, last_attempt) {
    WakeDelivered -> worker.Succeeded("delivered")
    WakeNothing -> worker.Succeeded("nothing pending")
    WakeEarly(..) | WakeRetry(..) if snoozes_used -> {
      let reason = snoozed_out(store)
      set_aside_wake(store, db, input, reason)
      worker.Discarded(reason)
    }
    WakeEarly(after_ms:) ->
      worker.Snoozed(
        after: duration.milliseconds(after_ms),
        reason: "nothing is due before the store's clock reaches it",
      )
    WakeRetry(reason:) -> retry_later(reason)
    WakeAside(reason:) -> worker.Discarded(reason)
    WakeDone(reason:) -> worker.Succeeded("done: " <> reason)
    WakeFailed(reason:) -> worker.Failed(reason)
  }
}

fn snoozed_out(store: Store) -> String {
  "delivered again "
  <> int.to_string(store.snooze_limit)
  <> " times without an outcome"
}

/// What one delivery of a wake-up did. The worker and `deliver_due` share
/// it, so both follow one code path.
type WakeResult {
  WakeDelivered
  WakeNothing
  WakeEarly(after_ms: Int)
  WakeRetry(reason: String)
  WakeAside(reason: String)
  WakeDone(reason: String)
  WakeFailed(reason: String)
}

fn deliver_one(
  store: Store,
  wakers: List(Waker),
  db: pog.Connection,
  input: WakeJob,
  last_attempt: Bool,
) -> WakeResult {
  case list.key_find(wakers, input.point) {
    Error(Nil) -> {
      let reason = "no desk serves the point " <> input.point
      set_aside_wake(store, db, input, reason)
      WakeAside(reason)
    }
    Ok(waker) -> {
      let outcome =
        pog.transaction(db, fn(tx) {
          use pending <- result.try(
            pog.query(
              "SELECT decisions_ms(at) FROM decisions_wakes
               WHERE id = $1 AND set_aside_at IS NULL",
            )
            |> pog.parameter(pog.int(input.wake))
            |> pog.returning(decode.at([0], sql.time()))
            |> sql.run(tx)
            |> result.map_error(WakeStore),
          )
          case pending {
            [] -> Ok(NothingPending)
            [at, ..] ->
              case sql.rescue(fn() { waker(tx, input.occurrence) }) {
                Error(raised) -> Error(WakeRaised(raised))
                Ok(Ok(None)) -> {
                  use _ <- result.try(
                    pog.query("DELETE FROM decisions_wakes WHERE id = $1")
                    |> pog.parameter(pog.int(input.wake))
                    |> sql.run(tx)
                    |> result.map_error(WakeStore),
                  )
                  let now = clock(store, tx)
                  Ok(Done(
                    lag_ms: wire.milliseconds(now) - wire.milliseconds(at),
                  ))
                }
                // Measured on the store's clock, in the same transaction:
                // the snooze is the time left on that clock, so a store
                // clock ahead of or behind the node's cannot make it a time
                // already past.
                Ok(Ok(Some(until))) -> Ok(Early(until:, now: clock(store, tx)))
                Ok(Error(refusal)) -> Error(WakeRefused(refusal))
              }
          }
        })
      case outcome {
        Ok(NothingPending) -> WakeNothing
        Ok(Done(lag_ms:)) -> {
          sinal.emit(
            telemetry.wake_delivered(),
            telemetry.Count(1),
            telemetry.Delivered(
              source: store.name,
              wake: input.wake,
              point: input.point,
              occurrence: input.occurrence,
              lag_ms:,
            ),
          )
          WakeDelivered
        }
        Ok(Early(until:, now:)) -> {
          sinal.emit(
            telemetry.wake_rescheduled(),
            telemetry.Count(1),
            telemetry.Rescheduled(
              source: store.name,
              wake: input.wake,
              point: input.point,
              occurrence: input.occurrence,
              until_ms: wire.milliseconds(until),
            ),
          )
          WakeEarly(after_ms: remaining_ms(until, now))
        }
        Error(pog.TransactionRolledBack(WakeStore(error))) ->
          WakeRetry(store.describe(error))
        Error(pog.TransactionQueryError(error)) ->
          WakeRetry(sql.describe(error))
        Error(pog.TransactionRolledBack(WakeRaised(raised))) ->
          counted(
            store,
            db,
            input,
            "the waker raised: " <> raised,
            last_attempt,
          )
        Error(pog.TransactionRolledBack(WakeRefused(refusal))) -> {
          let reason = decisions.describe(refusal)
          case decisions.handling(decisions.DeskRefused(refusal)) {
            decisions.Redeliver -> WakeRetry(reason)
            decisions.SetAside -> {
              set_aside_wake(store, db, input, reason)
              set_aside_occurrence(store, db, input.occurrence, reason)
              WakeAside(reason)
            }
            decisions.Backoff -> counted(store, db, input, reason, last_attempt)
            // The record says the wake-up has nothing left to do.
            decisions.Drop ->
              case
                pog.query("DELETE FROM decisions_wakes WHERE id = $1")
                |> pog.parameter(pog.int(input.wake))
                |> pog.execute(db)
              {
                Ok(_) -> WakeDone(reason)
                Error(error) -> WakeRetry(sql.describe(error))
              }
          }
        }
      }
    }
  }
}

/// A counted failure: retried after a backoff, set aside on the last
/// attempt.
fn counted(
  store: Store,
  db: pog.Connection,
  input: WakeJob,
  reason: String,
  last_attempt: Bool,
) -> WakeResult {
  case last_attempt {
    False -> WakeFailed(reason)
    True -> {
      set_aside_wake(store, db, input, reason)
      WakeAside(reason)
    }
  }
}

/// Deliver now every pending wake-up that is due on the store's clock, at
/// most `limit` of them, the earliest first, through exactly the code path
/// of `wake_worker`: the pending row is the authority, the point's waker
/// runs and the row is removed in one transaction, a waker that answers
/// `Some(until)` leaves its row pending, and poison is set aside. A counted
/// failure is not counted here (the row stays pending for the worker).
/// Returns how many were delivered.
///
/// It is for tests that use `with_clock_offset` (a wake-up's Grind job is
/// scheduled on the database's clock and cannot come due sooner), and for
/// an operator who wants the due wake-ups delivered without waiting for the
/// queue. It is safe beside the worker: each wake-up is delivered in a
/// transaction that locks its occurrence, and the Grind job that arrives
/// later finds the row gone and does nothing. `deliver_notices` does the
/// same for settlement notices.
pub fn deliver_due(
  store: Store,
  db: pog.Connection,
  wakers: List(Waker),
  limit limit: Int,
) -> Result(Int, StoreError) {
  use due <- result.try(
    pog.query(
      "SELECT id, point, occurrence_id, decisions_ms(at) FROM decisions_wakes
       WHERE set_aside_at IS NULL AND at <= decisions_at($1)
       ORDER BY at, id LIMIT $2",
    )
    |> pog.parameter(sql.at(clock(store, db)))
    |> pog.parameter(pog.int(limit))
    |> pog.returning(wake_row())
    |> sql.run(db),
  )
  Ok(
    list.count(due, fn(input) {
      deliver_one(store, wakers, db, input, False) == WakeDelivered
    }),
  )
}

fn wake_row() -> decode.Decoder(WakeJob) {
  use wake <- decode.field(0, decode.int)
  use point <- decode.field(1, decode.string)
  use occurrence <- decode.field(2, decode.string)
  use at_ms <- decode.field(3, decode.int)
  decode.success(WakeJob(wake:, point:, occurrence:, at_ms:))
}

/// What `sweep` admitted.
pub type Swept {
  Swept(
    /// Pending wake-ups that had no live job and got one.
    wakes: Int,
    /// Undelivered notices of followed points that had no live job and
    /// got one.
    notices: Int,
    /// The Grind jobs, held uncertain with no settlement to come (left for
    /// a person), whose pending rows got a new job here. Each still waits
    /// in Grind's list of uncertain jobs: resolve it there with any
    /// decision. Its row stays the authority, so a replay of it delivers
    /// nothing twice.
    left_uncertain: List(Int),
  )
}

/// Admit a Grind job for every pending wake-up, and every undelivered
/// settlement notice of a point the store follows, whose job will not
/// deliver it: a job missing (never admitted, as for a point added to
/// `following` after its occurrences settled, or pruned), ended while its
/// row stayed pending, or held uncertain and left for a person. A job held
/// uncertain whose declared settlement is still due is left to that
/// settlement (see `wake_worker`). Run it once the runtime has started,
/// and whenever an operator wants to; it is safe beside the workers,
/// because the row stays the authority: a job admitted twice delivers
/// once, and the second finds nothing pending. It reads each row's job
/// (two queries a row) and lists the queue's uncertain jobs once, so its
/// cost grows with the pending rows. A storage failure, Grind's included,
/// is an `Error`, never a row taken for one without a job.
pub fn sweep(store: Store, db: pog.Connection) -> Result(Swept, StoreError) {
  use wakes <- result.try(
    pog.query(
      "SELECT id, point, occurrence_id, decisions_ms(at), job_id
       FROM decisions_wakes WHERE set_aside_at IS NULL ORDER BY id",
    )
    |> pog.returning({
      use input <- decode.then(wake_row())
      use job_id <- decode.field(4, decode.optional(decode.int))
      decode.success(#(input, job_id))
    })
    |> sql.run(db),
  )
  use notices <- result.try(
    pog.query(
      "SELECT id, point, occurrence_id, job_id FROM decisions_settled
       WHERE delivered_at IS NULL AND set_aside_at IS NULL
         AND point = ANY ($1::text[])
       ORDER BY id",
    )
    |> pog.parameter(pog.array(pog.text, store.followed))
    |> pog.returning({
      use notice <- decode.field(0, decode.int)
      use point <- decode.field(1, decode.string)
      use occurrence <- decode.field(2, decode.string)
      use job_id <- decode.field(3, decode.optional(decode.int))
      decode.success(#(NoticeJob(notice:, point:, occurrence:), job_id))
    })
    |> sql.run(db),
  )
  // Listed before any job's state is read: a job held uncertain after
  // this listing was held just now, and its settlement is due.
  use marks <- result.try(uncertain_marks(store, 0, dict.new()))
  let wake_worker = wake_definition(store, never_runs)
  let notice_worker = settlement_definition(store, never_runs)
  use #(woken, left) <- result.try(
    list.try_fold(wakes, #(0, []), fn(swept, row) {
      let #(input, job_id) = row
      use recorded <- result.try(recorded_job(store, wake_worker, job_id, marks))
      readmit_unless_live(swept, recorded, fn() {
        readmit(db, "decisions_wakes", input.wake, fn(tx) {
          admit_wake(
            store,
            tx,
            input,
            "decisions.wake:"
              <> int.to_string(input.wake)
              <> ":"
              <> sql.new_id(),
          )
        })
      })
    }),
  )
  use #(noticed, left) <- result.map(
    list.try_fold(notices, #(0, left), fn(swept, row) {
      let #(input, job_id) = row
      use recorded <- result.try(recorded_job(
        store,
        notice_worker,
        job_id,
        marks,
      ))
      readmit_unless_live(swept, recorded, fn() {
        readmit(db, "decisions_settled", input.notice, fn(tx) {
          admit_notice(
            store,
            tx,
            input,
            "decisions.settlement:"
              <> int.to_string(input.notice)
              <> ":"
              <> sql.new_id(),
          )
        })
      })
    }),
  )
  Swept(wakes: woken, notices: noticed, left_uncertain: list.reverse(left))
}

/// What a pending row's recorded Grind job will do for it.
type Recorded {
  /// No job recorded, or none Grind holds as this row's: never admitted,
  /// pruned, or another runtime's.
  NoJob
  /// Waiting or running: it will deliver the row.
  Live
  /// Held uncertain, and its worker's declared settlement is still due: the
  /// settlement decides it.
  AwaitingSettlement
  /// Held uncertain with no settlement to come: left for a person, so it
  /// will not deliver the row by itself.
  LeftUncertain(job: Int)
  /// Finished while its row stayed pending: it will not deliver again.
  Ended
}

fn readmit_unless_live(
  swept: #(Int, List(Int)),
  recorded: Recorded,
  readmit: fn() -> Result(Int, StoreError),
) -> Result(#(Int, List(Int)), StoreError) {
  let #(count, left) = swept
  case recorded {
    Live | AwaitingSettlement -> Ok(swept)
    NoJob | Ended ->
      result.map(readmit(), fn(admitted) { #(count + admitted, left) })
    LeftUncertain(job:) ->
      result.map(readmit(), fn(admitted) {
        case admitted {
          0 -> #(count, left)
          _ -> #(count + admitted, [job, ..left])
        }
      })
  }
}

/// Every uncertain job in the store's queue, by id: `True` while its
/// settlement mark is due (a settler will decide it), `False` when it has
/// none or it ended.
fn uncertain_marks(
  store: Store,
  after: Int,
  marks: Dict(Int, Bool),
) -> Result(Dict(Int, Bool), StoreError) {
  let page = 1000
  use jobs <- result.try(
    admin.list(
      store.jobs,
      admin.query(limit: page)
        |> admin.in_queue(store.queue)
        |> admin.in_state(job.Uncertain)
        |> admin.after(after),
    )
    |> result.map_error(fn(error) {
      store.Unavailable(
        "Grind's uncertain jobs could not be listed: "
        <> admin.describe_error(error),
      )
    }),
  )
  let marks =
    list.fold(jobs, marks, fn(marks, summary) {
      let due = case summary.settlement {
        Some(mark) -> option.is_some(admin.mark_due_at(mark))
        None -> False
      }
      dict.insert(marks, summary.id, due)
    })
  let full = list.length(jobs) == page
  case list.last(jobs) {
    Ok(last) if full -> uncertain_marks(store, last.id, marks)
    _ -> Ok(marks)
  }
}

/// What a row's recorded job will do for it. `marks` is
/// `uncertain_marks`, listed before this read.
fn recorded_job(
  store: Store,
  definition: worker.Worker(input, String, String),
  job_id: Option(Int),
  marks: Dict(Int, Bool),
) -> Result(Recorded, StoreError) {
  case job_id {
    None -> Ok(NoJob)
    Some(id) -> {
      let state =
        grind.bind(store.jobs, definition, id)
        |> result.try(grind.state(store.jobs, _))
      case state {
        Ok(job.Uncertain) ->
          case dict.get(marks, id) {
            Ok(False) -> Ok(LeftUncertain(job: id))
            Ok(True) | Error(Nil) -> Ok(AwaitingSettlement)
          }
        Ok(state) ->
          case job.is_finished(state) {
            True -> Ok(Ended)
            False -> Ok(Live)
          }
        Error(grind.ReadUnavailable(error)) ->
          Error(store.Unavailable(
            "the job "
            <> int.to_string(id)
            <> " could not be read: "
            <> sql.describe(error),
          ))
        Error(grind.ReadNotRunning) ->
          Error(store.Unavailable(
            "the job "
            <> int.to_string(id)
            <> " could not be read: the Grind runtime is not running",
          ))
        // The id names no job of this row's worker in this runtime: never
        // its job, or pruned.
        Error(grind.JobNotFound)
        | Error(grind.QueueMismatch(..))
        | Error(grind.WorkerMismatch(..))
        | Error(grind.CodecMismatch(..))
        | Error(grind.HandleFromAnotherDatabase)
        | Error(grind.UndecodableValue(_))
        | Error(grind.CorruptRecord(_)) -> Ok(NoJob)
      }
    }
  }
}

/// Lock the row (still pending, or skip it), admit its job, commit.
fn readmit(
  db: pog.Connection,
  table: String,
  id: Int,
  admit: fn(pog.Connection) -> Result(Nil, StoreError),
) -> Result(Int, StoreError) {
  let pending = case table {
    "decisions_wakes" -> "set_aside_at IS NULL"
    _ -> "delivered_at IS NULL AND set_aside_at IS NULL"
  }
  pog.transaction(db, fn(tx) {
    use rows <- result.try(
      pog.query(
        "SELECT id FROM "
        <> table
        <> " WHERE id = $1 AND "
        <> pending
        <> " FOR UPDATE",
      )
      |> pog.parameter(pog.int(id))
      |> pog.returning(decode.at([0], decode.int))
      |> sql.run(tx),
    )
    case rows {
      [] -> Ok(0)
      _ -> admit(tx) |> result.replace(1)
    }
  })
  |> result.map_error(fn(error) {
    case error {
      pog.TransactionRolledBack(error) -> error
      pog.TransactionQueryError(error) -> sql.store_error(error)
    }
  })
}

/// Milliseconds from `now` to `until` on one clock, at least 1.
fn remaining_ms(until: Timestamp, now: Timestamp) -> Int {
  int.max(1, wire.milliseconds(until) - wire.milliseconds(now))
}

fn retry_later(reason: String) -> worker.Response(String, String) {
  worker.Snoozed(after: duration.milliseconds(retry_after_ms), reason:)
}

fn set_aside_wake(
  store: Store,
  db: pog.Connection,
  input: WakeJob,
  reason: String,
) -> Nil {
  case wake_aside(db, input.wake, reason) {
    Ok(True) ->
      emit_set_aside(
        store,
        telemetry.WakeUp,
        input.point,
        input.occurrence,
        reason,
      )
    _ -> Nil
  }
}

/// Set a pending wake-up's row aside; `False` when it was no longer
/// pending.
fn wake_aside(
  db: pog.Connection,
  wake: Int,
  reason: String,
) -> Result(Bool, StoreError) {
  pog.query(
    "UPDATE decisions_wakes
     SET set_aside_at = clock_timestamp(), set_aside_reason = $2
     WHERE id = $1 AND set_aside_at IS NULL",
  )
  |> pog.parameter(pog.int(wake))
  |> pog.parameter(pog.text(reason))
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.count == 1 })
  |> result.map_error(sql.store_error)
}

fn set_aside_occurrence(
  store: Store,
  db: pog.Connection,
  id: String,
  reason: String,
) -> Nil {
  case set_aside(db, occurrence: id, because: reason) {
    Ok(Some(point)) ->
      emit_set_aside(store, telemetry.Occurrence, point, id, reason)
    _ -> Nil
  }
}

fn emit_set_aside(
  store: Store,
  kind: telemetry.Kind,
  point: String,
  occurrence: String,
  reason: String,
) -> Nil {
  sinal.emit(
    telemetry.set_aside(),
    telemetry.Count(1),
    telemetry.SetAside(source: store.name, kind:, point:, occurrence:, reason:),
  )
}

// -- Abandoned deliveries ------------------------------------------------------------

/// The lease-expiry replays Grind gives a wake-up or notice job before it
/// holds the job uncertain (`worker.ReplayAfterLeaseExpiry`).
const replays = 10

/// How many replays the workers' declared settlement authorises for one
/// abandoned wake-up or notice job once Grind's own replays are used up,
/// before it sets the row aside. `AuthorizeReplay` does not give the job
/// its replays back, so each one is a single further delivery.
pub const authorized_replay_limit = 3

/// What becomes of a delivery Grind abandoned (its lease expired with no
/// replay left), decided from its row and the abandoned job alone.
type AbandonedDelivery {
  /// The row is no longer pending: nothing is left to deliver.
  NoLongerPending
  /// The row is pending: deliver it again.
  DeliverAgain
  /// The row is pending, but a cancellation of the job was requested, and
  /// Grind declines a replay then. The job ends failed; the row stays the
  /// authority, so `sweep` gives it a new job.
  CancelRequested
  /// The row is pending and the authorised replays are used up: set the
  /// row aside.
  GiveUp
}

fn abandoned_delivery(
  pending: Bool,
  job: Abandoned(input),
) -> AbandonedDelivery {
  case
    pending,
    abandoned.cancellation_requested(job),
    abandoned.authorized_replays(job) < authorized_replay_limit
  {
    False, _, _ -> NoLongerPending
    True, True, _ -> CancelRequested
    True, False, True -> DeliverAgain
    True, False, False -> GiveUp
  }
}

/// The wake-up worker's settlement (`worker.with_settlement`), run by Grind
/// in a transaction of its own when a delivery is abandoned for good. It
/// does database work only.
fn settle_wake(
  tx: pog.Connection,
  job: Abandoned(WakeJob),
) -> Result(worker.Settlement(String, String), String) {
  let wake = abandoned.input(job).wake
  settle_abandoned(
    job,
    pending: pending(
      tx,
      "SELECT count(*) FROM decisions_wakes
       WHERE id = $1 AND set_aside_at IS NULL",
      wake,
    ),
    set_aside: fn(reason) { wake_aside(tx, wake, reason) },
  )
}

/// The settlement worker's settlement, as `settle_wake`.
fn settle_notice(
  tx: pog.Connection,
  job: Abandoned(NoticeJob),
) -> Result(worker.Settlement(String, String), String) {
  let notice = abandoned.input(job).notice
  settle_abandoned(
    job,
    pending: pending(
      tx,
      "SELECT count(*) FROM decisions_settled
       WHERE id = $1 AND delivered_at IS NULL AND set_aside_at IS NULL",
      notice,
    ),
    set_aside: fn(reason) { notice_aside(tx, notice, reason) },
  )
}

fn pending(
  tx: pog.Connection,
  query: String,
  id: Int,
) -> Result(Bool, StoreError) {
  pog.query(query)
  |> pog.parameter(pog.int(id))
  |> pog.returning(decode.at([0], decode.int))
  |> sql.run(tx)
  |> result.map(fn(counts) { counts != [0] })
}

/// An `Error` asks Grind to try again later; a storage failure is one.
fn settle_abandoned(
  job: Abandoned(input),
  pending pending: Result(Bool, StoreError),
  set_aside set_aside: fn(String) -> Result(Bool, StoreError),
) -> Result(worker.Settlement(String, String), String) {
  use pending <- result.try(pending |> result.map_error(store.describe))
  case abandoned_delivery(pending, job) {
    NoLongerPending -> Ok(worker.ConfirmSuccess("nothing pending"))
    DeliverAgain -> Ok(worker.AuthorizeReplay)
    CancelRequested ->
      Ok(worker.ConfirmFailure(
        "abandoned with a cancellation requested; its row is still pending, "
        <> "so this job delivered nothing, and sweep gives the row a new job",
      ))
    GiveUp -> {
      let reason = given_up(job)
      case set_aside(reason) {
        Error(error) -> Error(store.describe(error))
        // Another delivery took the row since it was read.
        Ok(False) -> Ok(worker.ConfirmSuccess("nothing pending"))
        Ok(True) -> Ok(worker.ConfirmFailure(reason))
      }
    }
  }
}

fn given_up(job: Abandoned(input)) -> String {
  "abandoned after "
  <> int.to_string(abandoned.replays(job))
  <> " replays and "
  <> int.to_string(abandoned.authorized_replays(job))
  <> " authorised replays: each delivery died with its node or outlived "
  <> "its lease; set aside so it blocks nothing"
}

// -- Settlements ---------------------------------------------------------------------------

/// A settlement job's input: the notice's row in `decisions_settled`, its
/// point and its occurrence.
pub type NoticeJob {
  NoticeJob(notice: Int, point: String, occurrence: String)
}

/// What follows a point's settlements: given the transaction and the
/// settled record's id, it starts what comes next, typically by reading the
/// record and calling a verb of another desk or resuming a run. Every
/// notice reaches it, including one for a record that ended before it
/// began. Read it with `decisions.read_record` to get the same
/// `Begun(occurrence)` or `NotBegun(pending)` the OTP runtime hands its
/// followers (ADR 0055); `decisions.read` refuses a record not begun. The
/// outcome of a record not begun is final (a lapsed one may still record
/// a late recommendation, expired, with no second notice): do not wait
/// for it to begin. An
/// `Error` rolls the delivery back; what happens next depends on the
/// failure (see `settlement_worker`). Wrap a verb's refusal
/// in `decisions.DeskRefused`, and the application's own failure, such as
/// a call to another system, in `decisions.ApplicationFailed`.
pub type Follower =
  #(String, fn(pog.Connection, String) -> Result(Nil, decisions.HandlerFailure))

/// The Grind worker that delivers settlement notices to what follows them.
/// Register it with the follower of every point named with `following`.
///
/// One delivery is one transaction on the runtime's pool: it locks the
/// notice's row, runs the follower, and marks the notice delivered. The
/// follower's own database writes therefore happen once per notice: a job
/// delivered again, or replayed after its worker was killed after the
/// commit, finds the notice delivered and does nothing. An effect outside
/// the database may happen more than once and must be idempotent (key it
/// by the occurrence's id).
///
/// A follower's failure is acted on by `decisions.handling(failure)`
/// alone, the same rule `decisions_otp`'s runtime follows:
///
/// - `Redeliver` (a contended or unavailable store): the job is snoozed
///   for 2 seconds and delivered again. A snooze uses no attempt.
/// - `Backoff` (the application's own failure, a conflict, a policy that
///   cannot be read, a consulted point that cannot be asked, a tool that
///   answered `Unsure`): the attempt is counted and retried with Grind's
///   backoff (the registered worker's retry policy); after the last attempt
///   (`with_settlement_attempts`, 20 unless set) the notice is set aside. A
///   follower that raises is counted the same way.
/// - `SetAside` (a record that does not decode, an unpublishable policy,
///   undeclared facts, an output that does not encode, a key another point
///   holds): the notice is set aside at once.
/// - `Drop` (what follows was refused for good, for example the next
///   occurrence moved on): the notice is marked delivered and the job
///   succeeds, with the refusal in its output.
///
/// A follower that raises is an application failure (`Backoff`). A notice
/// delivered again without an outcome `with_snooze_limit` times is set
/// aside. With no follower for its point, the notice is set aside at once.
/// Setting aside emits `telemetry.set_aside`; nothing drops a job
/// silently. `sweep` gives a job to any undelivered notice of a followed
/// point left without one, such as one that settled before its point was
/// followed.
///
/// An attempt whose lease expires is replayed up to 10 times, and then the
/// job is settled in Grind's sense (`worker.with_settlement`: what becomes
/// of an abandoned job, which is not this worker's settlement notice) by
/// the rule `wake_worker` states, with the notice's row in place of the
/// wake-up's: replayed at most `authorized_replay_limit` times, then set
/// aside.
///
/// A record superseded before it began (expected, then a newer event), or
/// lapsed at its own deadline before it began (`decisions.expect_until`),
/// still admits a notice, and its follower is handed it like any other.
/// Reading it (`decisions.read`) is refused with `SupersededBefore` or
/// `DeadlinePassedBefore`, whose handling is `Drop`: return that refusal
/// and the notice ends delivered; `decisions.read_record` tells such a
/// record apart as `NotBegun`. When a late recommendation was recorded
/// before the notice is delivered, `read` returns the expired occurrence
/// instead.
pub fn settlement_worker(
  store: Store,
  followers: List(Follower),
) -> worker.Worker(NoticeJob, String, String) {
  settlement_definition(store, fn(context, input) {
    deliver_notice(store, followers, context, input)
  })
}

fn settlement_definition(
  store: Store,
  handle: fn(worker.Context, NoticeJob) -> worker.Response(String, String),
) -> worker.Worker(NoticeJob, String, String) {
  worker.responding(
    "decisions.settlement",
    input: worker.codec(
      worker.infallible(fn(notice: NoticeJob) {
        json.object([
          #("notice", json.int(notice.notice)),
          #("point", json.string(notice.point)),
          #("occurrence", json.string(notice.occurrence)),
        ])
      }),
      {
        use notice <- decode.field("notice", decode.int)
        use point <- decode.field("point", decode.string)
        use occurrence <- decode.field("occurrence", decode.string)
        decode.success(NoticeJob(notice:, point:, occurrence:))
      },
    ),
    output: text_codec(),
    handle:,
  )
  |> worker.with_queue(store.queue)
  |> worker.with_error_codec(text_codec())
  |> worker.with_abandonment(worker.ReplayAfterLeaseExpiry(replays))
  |> worker.with_settlement(settle_notice)
  |> worker.with_max_snoozes(store.snooze_limit + 1)
  |> worker.with_max_attempts(store.settlement_attempts)
}

type NoticeFailure {
  NoticeStore(StoreError)
  FollowerFailed(decisions.HandlerFailure)
}

type NoticeOutcome {
  DeliveredBefore
  Delivered
}

/// What one delivery of a notice did. The worker and `deliver_notices`
/// share it.
type NoticeResult {
  NoticeDelivered
  NoticeBefore
  NoticeRetry(reason: String)
  NoticeAside(reason: String)
  NoticeDone(reason: String)
  NoticeFailed(reason: String)
}

fn deliver_notice(
  store: Store,
  followers: List(Follower),
  context: worker.Context,
  input: NoticeJob,
) -> worker.Response(String, String) {
  let db = worker.connection(context)
  let last_attempt = worker.attempt(context) >= worker.max_attempts(context)
  let snoozes_used = worker.snooze_count(context) >= store.snooze_limit
  case notice_one(store, followers, db, input, last_attempt) {
    NoticeDelivered -> worker.Succeeded("delivered")
    NoticeBefore -> worker.Succeeded("delivered before")
    NoticeRetry(..) if snoozes_used -> {
      let reason = snoozed_out(store)
      set_aside_notice(store, db, input, reason)
      worker.Discarded(reason)
    }
    NoticeRetry(reason:) -> retry_later(reason)
    NoticeAside(reason:) -> worker.Discarded(reason)
    NoticeDone(reason:) -> worker.Succeeded("done: " <> reason)
    NoticeFailed(reason:) -> worker.Failed(reason)
  }
}

fn notice_one(
  store: Store,
  followers: List(Follower),
  db: pog.Connection,
  input: NoticeJob,
  last_attempt: Bool,
) -> NoticeResult {
  case list.key_find(followers, input.point) {
    Error(Nil) -> {
      let reason = "nothing follows the point " <> input.point
      set_aside_notice(store, db, input, reason)
      NoticeAside(reason)
    }
    Ok(follow) -> {
      let outcome =
        pog.transaction(db, fn(tx) {
          use pending <- result.try(
            pog.query(
              "SELECT id FROM decisions_settled
               WHERE id = $1 AND delivered_at IS NULL AND set_aside_at IS NULL
               FOR UPDATE",
            )
            |> pog.parameter(pog.int(input.notice))
            |> pog.returning(decode.at([0], decode.int))
            |> sql.run(tx)
            |> result.map_error(NoticeStore),
          )
          case pending {
            [] -> Ok(DeliveredBefore)
            _ -> {
              // A follower that raises is an application failure.
              let followed = case
                sql.rescue(fn() { follow(tx, input.occurrence) })
              {
                Ok(followed) -> followed
                Error(raised) ->
                  Error(decisions.ApplicationFailed(
                    "the follower raised: " <> raised,
                  ))
              }
              use Nil <- result.try(
                followed |> result.map_error(FollowerFailed),
              )
              mark_delivered(tx, input.notice)
              |> result.map_error(NoticeStore)
              |> result.replace(Delivered)
            }
          }
        })
      case outcome {
        Ok(DeliveredBefore) -> NoticeBefore
        Ok(Delivered) -> {
          sinal.emit(
            telemetry.settlement_delivered(),
            telemetry.Count(1),
            telemetry.Settled(
              source: store.name,
              notice: input.notice,
              point: input.point,
              occurrence: input.occurrence,
            ),
          )
          NoticeDelivered
        }
        Error(pog.TransactionRolledBack(NoticeStore(error))) ->
          NoticeRetry(store.describe(error))
        Error(pog.TransactionQueryError(error)) ->
          NoticeRetry(sql.describe(error))
        Error(pog.TransactionRolledBack(FollowerFailed(failure))) -> {
          let reason = case failure {
            decisions.DeskRefused(refusal:) -> decisions.describe(refusal)
            decisions.ApplicationFailed(reason:) -> reason
          }
          case decisions.handling(failure) {
            decisions.Redeliver -> NoticeRetry(reason)
            decisions.Backoff ->
              case last_attempt {
                False -> NoticeFailed(reason)
                True -> {
                  set_aside_notice(store, db, input, reason)
                  NoticeAside(reason)
                }
              }
            decisions.SetAside -> {
              set_aside_notice(store, db, input, reason)
              NoticeAside(reason)
            }
            // What follows has nothing left to do: the notice is marked
            // delivered in a transaction of its own.
            decisions.Drop ->
              case mark_delivered(db, input.notice) {
                Ok(Nil) -> NoticeDone(reason)
                Error(error) -> NoticeRetry(store.describe(error))
              }
          }
        }
      }
    }
  }
}

/// Deliver now every undelivered settlement notice of a point the store
/// follows, at most `limit`, the oldest first, through exactly the code
/// path of `settlement_worker`. A counted failure is not counted here (the
/// notice stays for the worker). Returns how many were delivered. Like
/// `deliver_due`, it is for tests and operators, and safe beside the
/// worker: the notice's row is locked and marked delivered in the
/// follower's transaction.
pub fn deliver_notices(
  store: Store,
  db: pog.Connection,
  followers: List(Follower),
  limit limit: Int,
) -> Result(Int, StoreError) {
  use pending <- result.try(
    pog.query(
      "SELECT id, point, occurrence_id FROM decisions_settled
       WHERE delivered_at IS NULL AND set_aside_at IS NULL
         AND point = ANY ($1::text[])
       ORDER BY id LIMIT $2",
    )
    |> pog.parameter(pog.array(pog.text, store.followed))
    |> pog.parameter(pog.int(limit))
    |> pog.returning({
      use notice <- decode.field(0, decode.int)
      use point <- decode.field(1, decode.string)
      use occurrence <- decode.field(2, decode.string)
      decode.success(NoticeJob(notice:, point:, occurrence:))
    })
    |> sql.run(db),
  )
  Ok(
    list.count(pending, fn(input) {
      notice_one(store, followers, db, input, False) == NoticeDelivered
    }),
  )
}

fn mark_delivered(
  connection: pog.Connection,
  notice: Int,
) -> Result(Nil, StoreError) {
  pog.query(
    "UPDATE decisions_settled SET delivered_at = clock_timestamp()
     WHERE id = $1 AND delivered_at IS NULL",
  )
  |> pog.parameter(pog.int(notice))
  |> sql.run(connection)
  |> result.replace(Nil)
}

fn set_aside_notice(
  store: Store,
  db: pog.Connection,
  input: NoticeJob,
  reason: String,
) -> Nil {
  case notice_aside(db, input.notice, reason) {
    Ok(True) ->
      emit_set_aside(
        store,
        telemetry.Notice,
        input.point,
        input.occurrence,
        reason,
      )
    _ -> Nil
  }
}

/// Set an undelivered notice aside; `False` when it was no longer pending.
fn notice_aside(
  db: pog.Connection,
  notice: Int,
  reason: String,
) -> Result(Bool, StoreError) {
  pog.query(
    "UPDATE decisions_settled
     SET set_aside_at = clock_timestamp(), set_aside_reason = $2
     WHERE id = $1 AND set_aside_at IS NULL AND delivered_at IS NULL",
  )
  |> pog.parameter(pog.int(notice))
  |> pog.parameter(pog.text(reason))
  |> pog.execute(db)
  |> result.map(fn(returned) { returned.count == 1 })
  |> result.map_error(sql.store_error)
}
