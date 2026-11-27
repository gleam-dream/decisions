//// A process-safe, in-memory store: the storage port of `decisions` with
//// real transactions that many processes use at once. Applications use it
//// in tests that start processes, and small deployments without a
//// database can use it in production if they accept what it loses (below).
////
//// **Transactions.** `transaction(store, body)` runs `body` in the
//// calling process. Its writes go to a buffer of its own that no other
//// transaction sees; they become visible all at once when `body` returns
//// `Ok`. When `body` returns `Error`, raises, or its process dies, nothing
//// it wrote is kept. Reads see committed rows and the transaction's own
//// writes.
////
//// **Commits are seen whole.** Every read of committed rows (queues,
//// `waiting`, pages, the inspection) sees each commit entirely or not at
//// all: the owner marks the table while it applies a commit, and a reader
//// that met a commit in progress reads again, or has the owner read for it
//// between two commits. The backlog's reads (`due`, `undelivered`,
//// `claim_trigger`) are the exception: they read without that mark, and
//// the runtime checks each job again under its lock before acting on it.
////
//// **Locks.** `load`, `append`, `schedule` and taking a wake-up lock the
//// occurrence's id until the transaction ends, **whether or not the
//// occurrence exists yet**: a second transaction that asks for the same
//// lock waits. The core's subject lock (`decisions.subject_lock`) is such
//// an id: it never holds entries and leaves no row. A wait that would close a cycle of transactions waiting for
//// each other is refused at once with `Contended("deadlock ...")`; a wait
//// longer than the configured `lock_timeout` is refused with
//// `Contended("lock wait ...")`. Either way nothing was written; the
//// caller rolls back and may retry. `Unavailable` means the store has
//// stopped. A
//// savepoint (`atomically`) that rolls back undoes its writes and keeps
//// its locks until the transaction ends.
////
//// **The owner.** One process owns the tables, grants the locks and
//// applies each commit. It monitors every process that holds a
//// transaction and drops the locks of one that dies. Wake-ups, settlement
//// notices, triggers and an application's own rows are rows like the
//// record, so they are durable for as long as the owner lives: a runtime
//// killed and started again finds every one of them.
////
//// **Ids.** An occurrence id is a UUID version 7 made on the node, as the
//// PostgreSQL adapter makes it, so it is unique across owners: a store
//// restarted empty never reuses an id, and an external effect keyed by an
//// occurrence's id stays unique.
////
//// **What is lost when the owner stops.** Everything. The tables live in
//// the owner's memory, so stopping it (with `stop`, or because the
//// process that started it exited) loses every record, wake-up, notice
//// and row, and every call on the old handle then fails or raises. A
//// transaction in flight raises. `restart` hands the committed rows to a
//// new owner, as a database's disk would; nothing outside the VM keeps
//// them. Use a database when the record must outlive the VM.
////
//// **Application rows are strings.** `put`, `get`, `add` and `rows` keep
//// text, as a database column of type text would. Keep a typed row with
//// a codec of `decisions/wire`: write
//// `wire.encode(codec, value) |> result.map(value.to_string)` (with
//// `json/blueprint/value`) and read it
//// back with `wire.parse(codec, text)`.
////
//// **Reading a point's occurrences.** `occurrences_of` and
//// `settled_since` page through a point's occurrences from indexes, for
//// learning and export; read each with `decisions.read`. The queue reads
//// (`queue`, `queue_page`, `queue_for`, `queue_page_for`, `review_queue`)
//// and the port's `waiting` read indexes too.
////
//// **In an application's tree.** `supervised(config, named:)` is a child
//// specification for the owner; `named(name)` gives the handle. See
//// `supervised` for what the owner's exit means for the tree.
////
//// **Only a transaction runs a verb.** The transaction value `Tx` is
//// valid only inside the body `transaction` handed it to, and nothing
//// else makes one, so the lock a verb takes, the gated tool's writes and
//// the entry that records the release always commit together.
//// `transaction` takes the `Store`, not a `Tx`: called inside another
//// transaction's body with the same `Store`, it opens a second, separate
//// transaction, which commits by itself. The reads an application makes outside a transaction
//// (the queues, the pages, `entries`, `heads`, `wakes`, `notices`) take
//// the `Store` and see committed rows; read a record through its desk
//// with `store.transaction(s, decisions.read(desk, _, occurrence: id))`.
////
//// ```gleam
//// import decisions_otp/store
////
//// let assert Ok(s) = store.start(store.defaults())
//// let desk = decisions.desk(point, drives:, under:, over: store.port())
//// let assert Ok(waiting) =
////   store.transaction(s, decisions.recommend_once(desk, _, key:, proposal:))
//// ```

import decisions/model.{type Evidence, Evidence}
import decisions/store.{
  type Head, type Inspection, type LockTimeout, type Notice, type Port,
  type StoreError, type Stored, type Wake, Conflict, Contended, Inspection,
  Notice, Port, Stored, Unavailable, Wake,
} as port_types
import decisions/vocabulary.{
  type Ref, type Stop, type Subject as About, type Validator,
}
import decisions/wire
import decisions_otp/backlog.{
  type Backlog, type Job, type Pending, type Submitted, Aside, Backlog,
  NoticeJob, Pending, Submitted, TriggerJob, WakeJob,
}
import decisions_otp/internal/owner.{type Change, type Message, Change}
import decisions_otp/internal/rows.{
  type Buffer, type Key, type Lock, type Row, AppKey, AppRow, AsideKey, AsideRow,
  BundleKey, EntryKey, EntryRow, EvidenceKey, EvidenceRow, HeadKey, HeadRow,
  IndexRow, NoticeKey, NoticeRow, OccurrenceLock, PendingKey, PendingRow,
  PointKey, QueueKey, ReviewKey, SettledKey, TriggerKey, TriggerRow, WaitingKey,
  WakeAtKey, WakeKey, WakeRow,
}
import decisions_otp/live.{type Hint, type Topic}
import gleam/bool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/set
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}

/// A running store: the handle every process uses. Copying it is free;
/// every copy addresses the same owner.
pub opaque type Store {
  Store(
    owner: Subject(Message),
    pid: Pid,
    tables: owner.Tables,
    lock_timeout: Int,
    capacity: Int,
    backoff: Int,
  )
}

/// The transaction value of the port: a transaction in progress. Only
/// `transaction` makes one, so every port call, and every verb of a desk
/// over this store, runs inside a transaction that commits or rolls back
/// whole.
pub opaque type Tx {
  Tx(store: Store, open: Open)
}

type Open {
  Open(id: Int, buffer: Buffer)
}

/// How a store behaves.
pub type Config {
  Config(
    /// How long a transaction waits for a lock before it is refused with
    /// `Contended`: at least a millisecond, as in every store
    /// (`decisions/store.lock_timeout`).
    lock_timeout: LockTimeout,
    /// How many messages a subscriber's mailbox may hold before hints to
    /// it are dropped and counted (see `decisions_otp/live`).
    hint_capacity: Int,
    /// What the store's clock reads.
    clock: Clock,
    /// How long a job whose handler failed waits before it is due again:
    /// this after the first failure, twice it after the second, and so
    /// on, at most 64 times it (see `decisions_otp/backlog.Backlog.failed`).
    retry_backoff: Duration,
  )
}

/// What a store's clock reads. `advance` moves either forward.
pub type Clock {
  /// The system clock at the moment of each reading.
  Wall
  /// A clock stopped at `at`: it moves only when `advance` moves it, so a
  /// test reads the same time twice. It breaks the port's clause that
  /// `now` is the wall clock, so `decisions_otp/stress` needs `Wall`.
  Stopped(at: Timestamp)
}

/// The shared four-second lock wait (`decisions/store.default_lock_timeout`),
/// room for 1 000 messages per subscriber, the wall clock, and a retry
/// backoff of one second.
pub fn defaults() -> Config {
  Config(
    lock_timeout: port_types.default_lock_timeout,
    hint_capacity: 1000,
    clock: Wall,
    retry_backoff: duration.seconds(1),
  )
}

/// Start a store, linked to the calling process, which owns it: when the
/// caller exits, the store stops and everything in it is lost. Its clock
/// reads the system clock until `advance` moves it.
pub fn start(config: Config) -> Result(Store, actor.StartError) {
  start_loaded(config, None, fn(_) { Nil })
}

/// The name a supervised store's owner is registered under. Make one at
/// start-up with `new_name` and keep it: each name is an atom, and atoms
/// are never collected.
pub opaque type Name {
  Name(name: process.Name(Message))
}

/// A new name for a store. Call it once per store, at start-up.
pub fn new_name(prefix: String) -> Name {
  Name(process.new_name(prefix))
}

/// The store's owner as a child of the application's supervisor,
/// registered under `name`; reach it with `named(name)`.
///
/// **What its exit means for the tree.** The owner holds every row. If it
/// exits, everything the store held is lost, and the supervisor's restart
/// starts an **empty** store under the same name. Every handle taken
/// before the exit fails or raises from then on, and every process that
/// uses the store must take a new handle with `named`. Put the store
/// first under a `RestForOne` supervisor with everything that uses it
/// after it (the runtime, the application's own processes), so that they
/// restart with the store and take a fresh handle.
pub fn supervised(
  config: Config,
  named name: Name,
) -> supervision.ChildSpecification(Store) {
  supervision.worker(fn() {
    start_loaded(config, Some(name.name), fn(_) { Nil })
    |> result.map(fn(store) { actor.Started(pid: store.pid, data: store) })
  })
}

/// Why the owner did not answer a request.
pub type OwnerError {
  /// The owner is not running: the store has stopped, or nothing is
  /// registered under the name.
  StoreStopped
  /// The owner is running and did not answer within this many
  /// milliseconds. It is slow, not gone; the request may still be
  /// handled.
  NoAnswerWithin(milliseconds: Int)
  /// `subscribe` was given a named subject that no process owns.
  NoSubscriber
}

/// The handle of the store registered under `name`: `StoreStopped` when
/// none runs, `NoAnswerWithin` when its owner is too slow to answer. A handle stays valid until that owner exits; take a new one
/// after a restart.
pub fn named(name: Name) -> Result(Store, OwnerError) {
  use pid <- result.try(
    process.named(name.name) |> result.replace_error(StoreStopped),
  )
  let subject = process.named_subject(name.name)
  use #(tables, settings) <- result.try(ask_owner(
    subject,
    pid,
    owner.Describe,
    5000,
  ))
  let #(lock_timeout, capacity, backoff) = settings
  Ok(Store(owner: subject, pid:, tables:, lock_timeout:, capacity:, backoff:))
}

fn start_loaded(
  config: Config,
  name: Option(process.Name(Message)),
  load: fn(owner.Tables) -> Nil,
) -> Result(Store, actor.StartError) {
  let capacity = int.max(1, config.hint_capacity)
  let load = fn(tables: owner.Tables) {
    load(tables)
    // A clock carried over by `restart` keeps reading as it did.
    case config.clock, rows.peek(tables.counters, "clock_stopped") {
      Stopped(at:), 0 -> {
        rows.set(tables.counters, "clock_stopped", 1)
        rows.set(tables.counters, "clock_offset", wire.milliseconds(at))
      }
      _, _ -> Nil
    }
  }
  let lock_timeout = port_types.lock_timeout_milliseconds(config.lock_timeout)
  let backoff = int.max(1, duration.to_milliseconds(config.retry_backoff))
  use started <- result.map(owner.start(
    capacity,
    name,
    #(lock_timeout, capacity, backoff),
    load,
  ))
  let #(subject, tables) = started.data
  Store(
    owner: subject,
    pid: started.pid,
    tables:,
    lock_timeout:,
    capacity:,
    backoff:,
  )
}

/// When a job that has failed `attempts` times is due again.
fn later(store: Store, attempts: Int) -> Int {
  let factor = case attempts {
    a if a <= 1 -> 1
    a if a >= 7 -> 64
    a -> pow2(a - 1)
  }
  wire.milliseconds(now(store)) + store.backoff * factor
}

fn pow2(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False -> 2 * pow2(n - 1)
  }
}

/// Stop the store. Everything in it is lost, and a transaction in
/// progress raises.
pub fn stop(store: Store) -> Nil {
  process.send(store.owner, owner.Stop)
}

/// The owner process. Killing it is stopping the store.
pub fn owner(store: Store) -> Pid {
  store.pid
}

/// Stop the store and start a new one, linked to the caller, holding only
/// what was committed: as a database restarts from its disk. Every
/// commit acknowledged before the restart is kept. Transactions in
/// progress on the old store raise, and one whose commit reached the old
/// owner after the copy raises "outcome unknown" and is not kept; claims on triggers and
/// subscriptions are not carried over. Build every handle again from the
/// new store.
pub fn restart(
  store: Store,
  config: Config,
) -> Result(Store, actor.StartError) {
  // The copy and the stop are one step in the owner: every commit it
  // acknowledged is in the copy, and a commit that arrives after it is
  // never applied and its caller raises "outcome unknown".
  use #(committed, counters) <- result.try(
    ask_forever(store, owner.Snapshot)
    |> result.replace_error(actor.InitFailed("the store had already stopped")),
  )
  start_loaded(config, None, fn(tables) {
    rows.load_rows(tables.rows, committed)
    rows.load_counters(tables.counters, counters)
  })
}

// -- Transactions ------------------------------------------------------------------

/// Run `body` as one transaction in the calling process. `Ok` commits
/// every write at once; `Error` keeps none. When `body` raises, nothing is
/// kept and the exception is raised again.
///
/// It raises when the store has stopped, including when it stops while
/// `body` runs. A store that stops after receiving the commit leaves the
/// outcome unknown; the raise says so.
pub fn transaction(store: Store, body: fn(Tx) -> Result(a, e)) -> Result(a, e) {
  let open = begin(store)
  case rows.attempt(fn() { body(Tx(store:, open:)) }) {
    Ok(Ok(value)) -> {
      commit(store, open)
      Ok(value)
    }
    Ok(Error(error)) -> {
      finish(store, open, None, [])
      Error(error)
    }
    Error(crash) -> {
      let _ = rows.attempt(fn() { finish(store, open, None, []) })
      rows.reraise(crash)
    }
  }
}

fn begin(store: Store) -> Open {
  case ask(store, owner.Begin(process.self(), _), 5000) {
    Ok(id) -> Open(id:, buffer: rows.new_buffer())
    Error(StoreStopped) | Error(NoSubscriber) ->
      panic as "decisions_otp/store: the store has stopped"
    Error(NoAnswerWithin(_)) ->
      panic as "decisions_otp/store: the owner did not answer within 5000 ms; no transaction was begun"
  }
}

fn commit(store: Store, open: Open) -> Nil {
  let writes = rows.writes(open.buffer)
  let changes = changes(store, open)
  finish(store, open, Some(writes), changes)
}

fn finish(
  store: Store,
  open: Open,
  writes: Option(List(#(Key, Option(Row)))),
  changes: List(Change),
) -> Nil {
  let outcome = ask_forever(store, owner.Finish(open.id, writes, changes, _))
  rows.drop_buffer(open.buffer)
  case outcome, writes {
    Ok(Nil), _ -> Nil
    Error(Nil), Some(_) ->
      panic as "decisions_otp/store: the store stopped during the commit; its outcome is unknown"
    Error(Nil), None -> Nil
  }
}

/// What a commit changes about each occurrence whose head it writes.
fn changes(store: Store, open: Open) -> List(Change) {
  rows.written_of_kind(open.buffer, HeadKey("", 0))
  |> list.filter_map(fn(pair) {
    case pair {
      #(HeadKey(occurrence:, ..) as key, HeadRow(head:, ..)) -> {
        let #(before, reviewed) = case
          rows.read_committed(store.tables.rows, key)
        {
          Ok(HeadRow(head: old, ..)) -> #(old.awaiting, old.review_pending)
          _ -> #([], False)
        }
        Ok(Change(
          point: head.point,
          occurrence:,
          status: port_types.status_name(head.status),
          queues: list.unique(list.append(before, head.awaiting)),
          reviews: reviewed || head.review_pending,
        ))
      }
      _ -> Error(Nil)
    }
  })
}

/// Send a request and wait for its reply, or for the owner to stop.
fn ask(
  store: Store,
  make: fn(Subject(reply)) -> Message,
  timeout: Int,
) -> Result(reply, OwnerError) {
  ask_owner(store.owner, store.pid, make, timeout)
}

fn ask_owner(
  owner: Subject(Message),
  pid: Pid,
  make: fn(Subject(reply)) -> Message,
  timeout: Int,
) -> Result(reply, OwnerError) {
  let reply = process.new_subject()
  let monitor = process.monitor(pid)
  process.send(owner, make(reply))
  let answer =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, fn(_) { Error(StoreStopped) })
    |> process.selector_receive(timeout)
  process.demonitor_process(monitor)
  case answer {
    Ok(outcome) -> outcome
    Error(Nil) -> Error(NoAnswerWithin(timeout))
  }
}

fn ask_forever(
  store: Store,
  make: fn(Subject(reply)) -> Message,
) -> Result(reply, Nil) {
  let reply = process.new_subject()
  let monitor = process.monitor(store.pid)
  process.send(store.owner, make(reply))
  let answer =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  answer
}

/// Run `body` with the transaction's store and buffer.
fn within(tx: Tx, body: fn(Store, Open) -> a) -> a {
  body(tx.store, tx.open)
}

/// Run a read in a transaction of its own, which writes nothing. It sees
/// committed rows only.
fn reading(store: Store, body: fn(Store, Open) -> a) -> a {
  case transaction(store, fn(tx) { Ok(body(tx.store, tx.open)) }) {
    Ok(value) -> value
    // The body cannot fail, and `transaction` raises rather than return
    // an error of its own.
    Error(Nil) -> panic as "decisions_otp/store: a read failed"
  }
}

// -- Reads that see each commit whole -----------------------------------------

/// Run `read` so that it sees no commit in part: between two commits, by
/// itself when it can, and in the owner, between two commits, when commits
/// keep it from that. Every scan of committed rows goes through it.
fn stable(store: Store, read: fn() -> a) -> a {
  case rows.stable(store.tables.rows, read) {
    Ok(value) -> value
    Error(Nil) -> {
      let reply = process.new_subject()
      case
        ask_forever(store, fn(done) {
          owner.Run(fn() {
            process.send(reply, read())
            process.send(done, Nil)
          })
        })
      {
        Ok(Nil) ->
          case process.receive(reply, 0) {
            Ok(value) -> value
            Error(Nil) ->
              panic as "decisions_otp/store: a read in the owner failed"
          }
        Error(Nil) -> panic as "decisions_otp/store: the store has stopped"
      }
    }
  }
}

fn scan(store: Store, buffer: Buffer, probe: Key) -> List(#(Key, Row)) {
  stable(store, fn() { rows.scan(store.tables.rows, buffer, probe) })
}

fn scan_kind(store: Store, buffer: Buffer, probe: Key) -> List(#(Key, Row)) {
  stable(store, fn() { rows.scan_kind(store.tables.rows, buffer, probe) })
}

fn scan_limit(
  store: Store,
  buffer: Buffer,
  probe: Key,
  limit: Int,
) -> List(#(Key, Row)) {
  stable(store, fn() {
    rows.scan_limit(store.tables.rows, buffer, probe, limit)
  })
}

fn scan_kind_committed(
  store: Store,
  probe: Key,
  limit: Int,
) -> List(#(Key, Row)) {
  stable(store, fn() {
    rows.scan_kind_committed(store.tables.rows, probe, limit)
  })
}

fn range(
  store: Store,
  probe: Key,
  after: Option(Key),
  limit: Int,
) -> List(#(Key, Row)) {
  stable(store, fn() { rows.range(store.tables.rows, probe, after, limit) })
}

// -- Locks -------------------------------------------------------------------------

/// Lock a name of the application's own until the transaction ends, as an
/// advisory lock in a database. Another transaction that locks the same
/// name waits.
pub fn lock(tx: Tx, name: String) -> Result(Nil, StoreError) {
  within(tx, fn(store, open) { take(store, open, rows.NamedLock(name)) })
}

type Answer {
  Answered(owner.Grant)
  OwnerStopped
}

fn take(store: Store, open: Open, lock: Lock) -> Result(Nil, StoreError) {
  case rows.holds_lock(open.buffer, lock) {
    True -> Ok(Nil)
    False -> {
      let reply = process.new_subject()
      let monitor = process.monitor(store.pid)
      process.send(store.owner, owner.Acquire(open.id, lock, reply))
      let selector =
        process.new_selector()
        |> process.select_map(reply, Answered)
        |> process.select_specific_monitor(monitor, fn(_) { OwnerStopped })
      let answer = case process.selector_receive(selector, store.lock_timeout) {
        Ok(answer) -> answer
        // Too long: withdraw the request. The owner answers the
        // withdrawal exactly once, on a subject of its own, and after any
        // grant it already sent: that answer is the truth, and a grant on
        // `reply` is in the mailbox by then, so it is read and dropped.
        Error(Nil) -> {
          let withdrawn = process.new_subject()
          process.send(store.owner, owner.Withdraw(open.id, withdrawn))
          let answer =
            process.new_selector()
            |> process.select_map(withdrawn, Answered)
            |> process.select_specific_monitor(monitor, fn(_) { OwnerStopped })
            |> process.selector_receive_forever
          let _ = process.receive(reply, 0)
          answer
        }
      }
      process.demonitor_process(monitor)
      case answer {
        Answered(owner.Granted) -> {
          rows.note_lock(open.buffer, lock)
          Ok(Nil)
        }
        Answered(owner.Deadlock) ->
          Error(Contended(
            "deadlock detected: two transactions wait for each other",
          ))
        Answered(owner.Withdrawn) ->
          Error(Contended(
            "lock wait longer than "
            <> int.to_string(store.lock_timeout)
            <> " ms",
          ))
        OwnerStopped -> Error(Unavailable("the store has stopped"))
      }
    }
  }
}

// -- The port ----------------------------------------------------------------------

/// The storage port. Every function runs in the caller's transaction.
pub fn port() -> Port(Tx) {
  Port(
    load: load,
    append: append,
    waiting: waiting,
    schedule: schedule,
    settled: settled,
    atomically: atomically,
    now: fn(tx: Tx) { Ok(now(tx.store)) },
    new_id: fn(_) { new_id() },
    members: members,
  )
}

/// A new occurrence id: a UUID version 7 made on the node, as the
/// PostgreSQL adapter makes it. It is unique by construction, not by a
/// counter of the owner's, so an owner restarted empty (`supervised`)
/// never issues an id an earlier owner issued, and an external effect
/// keyed by an occurrence's id never meets an earlier occurrence's key.
/// Ids made later sort later.
@external(erlang, "decisions_otp_ffi", "new_id")
fn new_id() -> String

fn members(
  tx: Tx,
  bundle: String,
) -> Result(List(#(String, Head)), StoreError) {
  use store, open <- within(tx)
  stable(store, fn() {
    rows.scan(store.tables.rows, open.buffer, BundleKey(bundle, ""))
    |> list.filter_map(fn(pair) {
      case pair.0 {
        BundleKey(id:, ..) ->
          case rows.read(store.tables.rows, open.buffer, HeadKey(id, 0)) {
            Ok(HeadRow(head:, ..)) -> Ok(#(id, head))
            _ -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  })
  |> Ok
}

fn load(tx: Tx, id: String) -> Result(List(Stored), StoreError) {
  use store, open <- within(tx)
  use Nil <- result.try(take(store, open, OccurrenceLock(id)))
  Ok(entries_in(store, open, id))
}

/// The entries of an occurrence. Callers hold its lock (`load`, `append`),
/// or read entries already committed, which no commit changes: no
/// `stable` needed.
fn entries_in(store: Store, open: Open, id: String) -> List(Stored) {
  rows.scan(store.tables.rows, open.buffer, EntryKey(id, 0))
  |> list.filter_map(fn(pair) {
    case pair.1 {
      EntryRow(stored:) -> Ok(stored)
      _ -> Error(Nil)
    }
  })
}

fn append(
  tx: Tx,
  id: String,
  head: Head,
  fresh: List(Stored),
) -> Result(Nil, StoreError) {
  use store, open <- within(tx)
  use Nil <- result.try(take(store, open, OccurrenceLock(id)))
  let #(last, released, old) = case
    rows.read(store.tables.rows, open.buffer, HeadKey(id, 0))
  {
    Ok(HeadRow(head: old, last:, released:)) -> #(last, released, Some(old))
    _ -> #(0, False, None)
  }
  let in_order =
    list.index_map(fresh, fn(stored, index) { stored.seq == last + index + 1 })
    |> list.all(fn(ok) { ok })
  let releases =
    list.count(fresh, fn(stored) { stored.kind == "released" })
    + case released {
      True -> 1
      False -> 0
    }
  case in_order, releases > 1 {
    False, _ ->
      Error(Conflict(
        "occurrence "
        <> id
        <> " holds "
        <> int.to_string(last)
        <> " entries; these do not follow",
      ))
    True, True -> Error(Conflict("occurrence " <> id <> " is already released"))
    True, False -> {
      list.each(fresh, fn(stored) {
        rows.put(open.buffer, EntryKey(id, stored.seq), EntryRow(stored))
      })
      rows.put(
        open.buffer,
        HeadKey(id, 0),
        HeadRow(head:, last: last + list.length(fresh), released: releases == 1),
      )
      index(open, id, old, head)
      Ok(Nil)
    }
  }
}

fn waiting(
  tx: Tx,
  point: String,
  subject: About,
) -> Result(List(String), StoreError) {
  use store, open <- within(tx)
  scan(store, open.buffer, WaitingKey(#(point, subject), ""))
  |> list.filter_map(fn(pair) {
    case pair.0 {
      WaitingKey(id:, ..) -> Ok(id)
      _ -> Error(Nil)
    }
  })
  |> Ok
}

/// Keep the two indexes beside a head: one row per decision set it waits
/// in, keyed by queue order, and one row while `waiting` must return it.
/// Both are rows of the transaction, so they commit and roll back with
/// the head.
fn index(open: Open, id: String, old: Option(Head), new: Head) -> Nil {
  case old {
    Some(old) -> {
      list.each(old.awaiting, fn(set) {
        rows.delete(open.buffer, QueueKey(set, queue_order(id, old)))
      })
      rows.delete(open.buffer, WaitingKey(#(old.point, old.subject), id))
      rows.delete(open.buffer, ReviewKey(old.point, id))
    }
    None -> rows.put(open.buffer, PointKey(new.point, #(-1, id)), IndexRow)
  }
  let was_settled = case old {
    Some(old) -> is_settled(old.status)
    None -> False
  }
  case is_settled(new.status), was_settled {
    True, False ->
      rows.put(open.buffer, SettledKey(new.point, #(-1, -1, id)), IndexRow)
    _, _ -> Nil
  }
  case new.review_pending {
    True -> rows.put(open.buffer, ReviewKey(new.point, id), IndexRow)
    False -> Nil
  }
  case new.bundle {
    Some(bundle) ->
      rows.put(
        open.buffer,
        BundleKey(vocabulary.bundle_key(bundle), id),
        IndexRow,
      )
    None -> Nil
  }
  list.each(new.awaiting, fn(set) {
    rows.put(open.buffer, QueueKey(set, queue_order(id, new)), IndexRow)
  })
  case port_types.is_waiting(new.status) {
    True ->
      rows.put(open.buffer, WaitingKey(#(new.point, new.subject), id), IndexRow)
    False -> Nil
  }
}

fn is_settled(status: port_types.Status) -> Bool {
  case status {
    port_types.Released
    | port_types.Rejected
    | port_types.Expired
    | port_types.Withdrawn
    | port_types.Refused -> True
    port_types.Pending
    | port_types.Recommended
    | port_types.Awaiting
    | port_types.Accepted
    | port_types.Held -> False
  }
}

/// The soonest due first, those with no due time last, then by arrival,
/// then by id.
fn queue_order(id: String, head: Head) -> #(Int, Int, String) {
  #(
    case head.due {
      Some(due) -> wire.milliseconds(due)
      None -> no_due
    },
    wire.milliseconds(head.arrived),
    id,
  )
}

/// Later than any due time a store will hold (the year 2286).
const no_due = 9_999_999_999_999

fn heads_in(store: Store, open: Open) -> List(#(String, Head)) {
  scan_kind(store, open.buffer, HeadKey("", 0))
  |> list.filter_map(head_pair)
}

fn head_pair(pair: #(Key, Row)) -> Result(#(String, Head), Nil) {
  case pair {
    #(HeadKey(occurrence:, ..), HeadRow(head:, ..)) -> Ok(#(occurrence, head))
    _ -> Error(Nil)
  }
}

fn schedule(
  tx: Tx,
  point: String,
  occurrence: String,
  at: List(Timestamp),
) -> Result(Nil, StoreError) {
  use store, open <- within(tx)
  use Nil <- result.try(take(store, open, OccurrenceLock(occurrence)))
  // Under the occurrence's lock: no other commit touches these rows.
  rows.scan(store.tables.rows, open.buffer, WakeKey(#(point, occurrence), 0))
  |> list.each(fn(pair) { drop_wake(store, open, pair.0) })
  at
  |> list.map(wire.milliseconds)
  |> list.unique
  |> list.each(fn(ms) {
    put_wake(store, open, WakeKey(#(point, occurrence), ms), WakeRow(0, 0))
  })
  Ok(Nil)
}

fn settled(
  tx: Tx,
  point: String,
  occurrence: String,
) -> Result(Nil, StoreError) {
  use store, open <- within(tx)
  let id = rows.next(store.tables.counters, "notice")
  rows.put(
    open.buffer,
    NoticeKey(id, 0),
    NoticeRow(Notice(point:, occurrence:), rows.NoticePending, 0, 0),
  )
  rows.put(open.buffer, PendingKey(id, 0), PendingRow(0))
  Ok(Nil)
}

fn atomically(
  tx: Tx,
  body: fn(Tx) -> Result(List(Ref), Stop),
) -> Result(Result(List(Ref), Stop), StoreError) {
  use store, open <- within(tx)
  let before = rows.snapshot(open.buffer)
  case rows.attempt(fn() { body(Tx(store:, open:)) }) {
    Ok(Ok(refs)) -> Ok(Ok(refs))
    Ok(Error(reason)) -> {
      rows.restore(open.buffer, before)
      Ok(Error(reason))
    }
    // A body that raises leaves nothing of its own behind either; the
    // exception goes on to the caller.
    Error(crash) -> {
      rows.restore(open.buffer, before)
      rows.reraise(crash)
    }
  }
}

/// What `decisions/conformance` and `decisions/testing` read: committed
/// rows and the transaction's own writes.
pub fn inspection() -> Inspection(Tx) {
  Inspection(
    occurrences: fn(tx, point) {
      use store, open <- within(tx)
      heads_in(store, open)
      |> list.filter(fn(pair) { { pair.1 }.point == point })
      |> list.map(fn(pair) { pair.0 })
      |> Ok
    },
    head: fn(tx, id) {
      use store, open <- within(tx)
      case rows.read(store.tables.rows, open.buffer, HeadKey(id, 0)) {
        Ok(HeadRow(head:, ..)) -> Ok(Some(head))
        _ -> Ok(None)
      }
    },
    wakes: fn(tx) { Ok(within(tx, wakes_in)) },
    notices: fn(tx) { Ok(within(tx, notices_in)) },
  )
}

/// Evidence kept in the store's rows, for `decisions/model.capture`.
pub fn evidence() -> Evidence(Tx) {
  Evidence(
    put: fn(tx, ref, body) {
      within(tx, fn(_, open) {
        rows.put(open.buffer, EvidenceKey(ref, 0), EvidenceRow(body))
      })
      Ok(Nil)
    },
    get: fn(tx, ref: Ref) {
      within(tx, fn(store, open) {
        case rows.read(store.tables.rows, open.buffer, EvidenceKey(ref, 0)) {
          Ok(EvidenceRow(body:)) -> Ok(body)
          _ -> Error("no evidence stored for " <> ref.kind <> ":" <> ref.id)
        }
      })
    },
  )
}

// -- What an application and a test read --------------------------------------------

/// The committed entries of a record, in sequence order, without a lock.
pub fn entries(store: Store, id: String) -> List(Stored) {
  reading(store, fn(store, open) { entries_in(store, open, id) })
}

/// Every committed record's head, by id.
pub fn heads(store: Store) -> List(#(String, Head)) {
  reading(store, heads_in)
}

/// The occurrences waiting for a holder of `set`: the soonest due first,
/// those with no due time last, then in arrival order. Read from an
/// index kept in queue order, so its cost grows with what it returns.
pub fn queue(store: Store, set: String) -> List(String) {
  queue_page(store, set, 0)
}

/// The first `limit` of `queue(store, set)`; every one when `limit` is 0.
pub fn queue_page(store: Store, set: String, limit: Int) -> List(String) {
  reading(store, fn(store, open) { indexed(store, open, set, limit) })
  |> list.map(fn(entry) { entry.1 })
}

fn indexed(
  store: Store,
  open: Open,
  set: String,
  limit: Int,
) -> List(#(#(Int, Int, String), String)) {
  let probe = QueueKey(set, #(0, 0, ""))
  case limit > 0 {
    True -> scan_limit(store, open.buffer, probe, limit)
    False -> scan(store, open.buffer, probe)
  }
  |> list.filter_map(fn(pair) {
    case pair.0 {
      QueueKey(order:, ..) -> Ok(#(order, order.2))
      _ -> Error(Nil)
    }
  })
}

/// The occurrences a validator may decide, in queue order: waiting for a
/// set they hold, not already approved by them, and not barred from them
/// (`Head.may_not_decide`, such as the person who asked).
pub fn queue_for(store: Store, validator: Validator) -> List(String) {
  queue_page_for(store, validator, 0)
}

/// The first `limit` of `queue_for(store, validator)`; every one when
/// `limit` is 0. With a limit, it walks each held set's queue index in
/// step, in queue order, and stops once it has `limit` that the validator
/// may decide, so a page costs about what it returns.
pub fn queue_page_for(
  store: Store,
  validator: Validator,
  limit: Int,
) -> List(String) {
  reading(store, fn(store, open) {
    case limit > 0 {
      True -> {
        let chunk = int.max(16, limit)
        let streams =
          list.unique(validator.holds)
          |> list.map(fn(set) {
            Stream(set:, ahead: [], last: None, done: False)
          })
        merge(store, open, validator, streams, chunk, limit, set.new(), [])
      }
      False ->
        list.flat_map(list.unique(validator.holds), fn(set) {
          indexed(store, open, set, 0)
        })
        |> list.sort(fn(a, b) { compare_order(a.0, b.0) })
        |> list.map(fn(entry) { entry.1 })
        |> list.unique
        |> take_allowed(store, open, validator, limit, [])
    }
  })
}

/// One held set's queue, read a chunk at a time.
type Stream {
  Stream(
    set: String,
    ahead: List(#(#(Int, Int, String), String)),
    last: Option(Key),
    done: Bool,
  )
}

fn fill(store: Store, stream: Stream, chunk: Int) -> Stream {
  case stream.ahead, stream.done {
    [], False -> {
      let found =
        range(store, QueueKey(stream.set, #(0, 0, "")), stream.last, chunk)
      let ahead =
        list.filter_map(found, fn(pair) {
          case pair.0 {
            QueueKey(order:, ..) -> Ok(#(order, order.2))
            _ -> Error(Nil)
          }
        })
      Stream(
        ..stream,
        ahead:,
        last: case list.last(found) {
          Ok(#(key, _)) -> Some(key)
          Error(Nil) -> stream.last
        },
        done: list.length(found) < chunk,
      )
    }
    _, _ -> stream
  }
}

fn merge(
  store: Store,
  open: Open,
  validator: Validator,
  streams: List(Stream),
  chunk: Int,
  limit: Int,
  seen: set.Set(String),
  so_far: List(String),
) -> List(String) {
  let streams = list.map(streams, fill(store, _, chunk))
  let first: Option(#(#(Int, Int, String), String)) =
    list.fold(streams, None, fn(best, stream: Stream) {
      case stream.ahead, best {
        [head, ..], None -> Some(head)
        [head, ..], Some(#(other, _)) ->
          case compare_order(head.0, other) {
            order.Lt -> Some(head)
            _ -> best
          }
        [], _ -> best
      }
    })
  case first, list.length(so_far) >= limit {
    None, _ | _, True -> list.reverse(so_far)
    Some(#(order, id)), False -> {
      let streams =
        list.map(streams, fn(stream) {
          case stream.ahead {
            [#(o, _), ..rest] if o == order -> Stream(..stream, ahead: rest)
            _ -> stream
          }
        })
      let so_far = case
        set.contains(seen, id) || !allowed(store, open, validator, id)
      {
        True -> so_far
        False -> [id, ..so_far]
      }
      merge(
        store,
        open,
        validator,
        streams,
        chunk,
        limit,
        set.insert(seen, id),
        so_far,
      )
    }
  }
}

fn allowed(store: Store, open: Open, validator: Validator, id: String) -> Bool {
  case rows.read(store.tables.rows, open.buffer, HeadKey(id, 0)) {
    Ok(HeadRow(head:, ..)) ->
      !list.contains(head.approved, validator.subject)
      && !list.contains(head.may_not_decide, validator.subject)
    _ -> False
  }
}

fn take_allowed(
  ids: List(String),
  store: Store,
  open: Open,
  validator: Validator,
  limit: Int,
  so_far: List(String),
) -> List(String) {
  case ids, limit > 0 && list.length(so_far) >= limit {
    [], _ | _, True -> list.reverse(so_far)
    [id, ..rest], False -> {
      take_allowed(
        rest,
        store,
        open,
        validator,
        limit,
        case allowed(store, open, validator, id) {
          True -> [id, ..so_far]
          False -> so_far
        },
      )
    }
  }
}

fn compare_order(
  a: #(Int, Int, String),
  b: #(Int, Int, String),
) -> order.Order {
  case int.compare(a.0, b.0) {
    order.Eq ->
      case int.compare(a.1, b.1) {
        order.Eq -> string.compare(a.2, b.2)
        other -> other
      }
    other -> other
  }
}

/// Sampled, released occurrences waiting for a review after the fact,
/// of every point, by point and then by id. Read from an index.
pub fn review_queue(store: Store) -> List(String) {
  reading(store, fn(store, open) {
    scan_kind(store, open.buffer, ReviewKey("", ""))
    |> list.filter_map(fn(pair) {
      case pair.0 {
        ReviewKey(id:, ..) -> Ok(id)
        _ -> Error(Nil)
      }
    })
  })
}

/// `review_queue` of one point, by id, at most `limit` (every one when
/// `limit` is 0).
pub fn review_queue_of(
  store: Store,
  point: String,
  limit: Int,
) -> List(String) {
  reading(store, fn(store, open) {
    let probe = ReviewKey(point, "")
    case limit > 0 {
      True -> scan_limit(store, open.buffer, probe, limit)
      False -> scan(store, open.buffer, probe)
    }
    |> list.filter_map(fn(pair) {
      case pair.0 {
        ReviewKey(id:, ..) -> Ok(id)
        _ -> Error(Nil)
      }
    })
  })
}

/// One page of occurrence ids, and where the next page starts.
pub type Page {
  Page(ids: List(String), next: Option(Cursor))
}

/// Where the next page of `occurrences_of` or `settled_since` starts.
/// Pass it back unchanged.
pub opaque type Cursor {
  Cursor(after: Key)
}

/// Every occurrence of `point`, in the order their first entries
/// committed, `limit` at a time (at least 1): the first page with
/// `after: None`, the next with the page's `next`. The order is a number
/// the owner gives each commit, so a reader that keeps its cursor reads
/// each occurrence once, including one that commits while it reads. A
/// page reads committed rows only, from an index, and costs what it
/// returns. Read each occurrence with `decisions.read`. For learning and
/// export, such as `decisions/learning.example`.
pub fn occurrences_of(
  store: Store,
  point: String,
  after after: Option(Cursor),
  limit limit: Int,
) -> Page {
  paged(store, PointKey(point, #(-1, "")), after, None, limit, fn(key) {
    case key {
      PointKey(at: #(_, id), ..) -> Ok(id)
      _ -> Error(Nil)
    }
  })
}

/// The occurrences of `point` whose settlement committed at or after
/// `since` on the store's clock, in commit order, `limit` at a time (at
/// least 1). The time is the commit's, which the owner never lets go back;
/// the order is the commit's number. A reader that keeps the last page's
/// `next` reads each settlement once, including one that commits while it
/// reads. Committed rows only; a page costs what it returns.
pub fn settled_since(
  store: Store,
  point: String,
  since since: Timestamp,
  after after: Option(Cursor),
  limit limit: Int,
) -> Page {
  let from = SettledKey(point, #(wire.milliseconds(since), -1, ""))
  paged(
    store,
    SettledKey(point, #(-1, -1, "")),
    after,
    Some(from),
    limit,
    fn(key) {
      case key {
        SettledKey(at: #(_, _, id), ..) -> Ok(id)
        _ -> Error(Nil)
      }
    },
  )
}

fn paged(
  store: Store,
  probe: Key,
  after: Option(Cursor),
  start: Option(Key),
  limit: Int,
  id_of: fn(Key) -> Result(String, Nil),
) -> Page {
  let limit = int.max(1, limit)
  let after = case after {
    Some(Cursor(after:)) -> Some(after)
    None -> start
  }
  let found = range(store, probe, after, limit + 1)
  let shown = list.take(found, limit)
  let ids = list.filter_map(shown, fn(pair) { id_of(pair.0) })
  case list.length(found) > limit, list.last(shown) {
    True, Ok(#(last, _)) -> Page(ids:, next: Some(Cursor(last)))
    _, _ -> Page(ids:, next: None)
  }
}

/// Every committed pending wake-up.
pub fn wakes(store: Store) -> List(Wake) {
  reading(store, wakes_in)
}

fn wakes_in(store: Store, open: Open) -> List(Wake) {
  scan_kind(store, open.buffer, WakeKey(#("", ""), 0))
  |> list.filter_map(wake_of)
}

fn wake_of(pair: #(Key, Row)) -> Result(Wake, Nil) {
  case pair {
    #(WakeKey(job: #(point, occurrence), at:), _) ->
      Ok(Wake(point:, occurrence:, at: wire.from_milliseconds(at)))
    _ -> Error(Nil)
  }
}

/// Every committed settlement notice, delivered or not, in the order
/// admitted.
pub fn notices(store: Store) -> List(Notice) {
  reading(store, notices_in)
}

fn notices_in(store: Store, open: Open) -> List(Notice) {
  scan_kind(store, open.buffer, NoticeKey(0, 0))
  |> list.filter_map(fn(pair) {
    case pair.1 {
      NoticeRow(notice:, ..) -> Ok(notice)
      _ -> Error(Nil)
    }
  })
}

/// Replace the stored text of one entry, bypassing every rule of the
/// port, as damage to a database would. It exists to test what happens
/// around a record that no longer decodes.
pub fn tamper(store: Store, id: String, seq: Int, text: String) -> Nil {
  // In a transaction of its own; it must commit.
  let assert Ok(Nil) =
    transaction(store, fn(tx) {
      use store, open <- within(tx)
      case rows.read(store.tables.rows, open.buffer, EntryKey(id, seq)) {
        Ok(EntryRow(stored:)) ->
          rows.put(
            open.buffer,
            EntryKey(id, seq),
            EntryRow(Stored(..stored, event: text)),
          )
        _ -> Nil
      }
      Ok(Nil)
    })
  Nil
}

// -- Rows of the application's own ------------------------------------------------------

/// Write an application's own row in `table` under `key`. It commits and
/// rolls back with the transaction, as a gated tool's write must. Two
/// transactions that write one key both succeed and the later commit
/// stands; take `lock` first where that matters.
pub fn put(tx: Tx, table: String, key: String, value: String) -> Nil {
  within(tx, fn(_, open) {
    rows.put(open.buffer, AppKey(table, key), AppRow(value))
  })
}

/// An application's own row.
pub fn get(tx: Tx, table: String, key: String) -> Result(String, Nil) {
  within(tx, fn(store, open) {
    case rows.read(store.tables.rows, open.buffer, AppKey(table, key)) {
      Ok(AppRow(value:)) -> Ok(value)
      _ -> Error(Nil)
    }
  })
}

/// Remove an application's own row.
pub fn remove(tx: Tx, table: String, key: String) -> Nil {
  within(tx, fn(_, open) { rows.delete(open.buffer, AppKey(table, key)) })
}

/// Add a row to `table` under a new key that sorts after every key `add`
/// gave before, such as an outbox's next message.
pub fn add(tx: Tx, table: String, value: String) -> Nil {
  let number = rows.next(tx.store.tables.counters, "row")
  put(tx, table, string.pad_start(int.to_string(number), 12, "0"), value)
}

/// Every row of `table`, as `#(key, value)` in key order.
pub fn rows(tx: Tx, table: String) -> List(#(String, String)) {
  within(tx, fn(store, open) {
    scan(store, open.buffer, AppKey(table, ""))
    |> list.filter_map(fn(pair) {
      case pair {
        #(AppKey(key:, ..), AppRow(value:)) -> Ok(#(key, value))
        _ -> Error(Nil)
      }
    })
  })
}

/// How many rows `table` holds.
pub fn count(tx: Tx, table: String) -> Int {
  list.length(rows(tx, table))
}

// -- The clock -----------------------------------------------------------------------

/// The store's clock: the system clock plus whatever `advance` added. It
/// is shared by every process using the store.
pub fn now(store: Store) -> Timestamp {
  let counters = store.tables.counters
  let base = case rows.peek(counters, "clock_stopped") {
    0 -> rows.system_ms()
    _ -> 0
  }
  wire.from_milliseconds(base + rows.peek(counters, "clock_offset"))
}

/// Move the store's clock forward, as time passing would.
pub fn advance(store: Store, by: Duration) -> Nil {
  let offset = rows.peek(store.tables.counters, "clock_offset")
  rows.set(
    store.tables.counters,
    "clock_offset",
    offset + duration.to_milliseconds(by),
  )
}

// -- Subscriptions ---------------------------------------------------------------------

/// A live subscription. Pass it to `unsubscribe`, or let the subscribing
/// process exit: the store monitors it and forgets it.
pub opaque type Subscription {
  Subscription(id: Int)
}

/// Tell `subscriber` after each commit that changes what `topic` watches.
/// The subscriber is the process that owns `subscriber`. See
/// `decisions_otp/live` for what it is told and what that promises. It is
/// acknowledged: `Ok` means the owner holds the subscription.
/// `NoAnswerWithin` means the owner was too slow to say, so the caller
/// cannot tell whether it holds it; `StoreStopped` that it never will.
pub fn subscribe(
  store: Store,
  to topic: Topic,
  hints subscriber: Subject(Hint),
) -> Result(Subscription, OwnerError) {
  case ask(store, owner.Subscribe(topic, subscriber, _), 5000) {
    Ok(Ok(id)) -> Ok(Subscription(id))
    Ok(Error(Nil)) -> Error(NoSubscriber)
    Error(error) -> Error(error)
  }
}

/// Stop telling a subscriber. Hints already sent stay in its mailbox.
pub fn unsubscribe(store: Store, subscription: Subscription) -> Nil {
  process.send(store.owner, owner.Unsubscribe(subscription.id))
}

// -- The backlog ------------------------------------------------------------------------

/// The store's backlog, for `decisions_otp/runtime` and
/// `decisions_otp/stress`.
pub fn backlog(store: Store) -> Backlog(Tx) {
  Backlog(
    transaction: fn(body) { transaction(store, body) },
    now: fn() { now(store) },
    due: fn(at, limit) {
      // A raw read of the time-ordered index, which holds a wake-up whose
      // handler failed at the end of its backoff: only the due prefix is
      // read. A commit seen in part here can only offer a wake-up that
      // `take_wake` then finds gone, or miss one until the next look.
      rows.due_wakes(store.tables.rows, wire.milliseconds(at), limit)
      |> list.filter_map(fn(key) {
        case key {
          WakeAtKey(wake: #(point, occurrence, at), ..) ->
            Ok(Wake(point:, occurrence:, at: wire.from_milliseconds(at)))
          _ -> Error(Nil)
        }
      })
      |> Ok
    },
    take_wake: fn(tx, wake: Wake) {
      use store, open <- within(tx)
      use Nil <- result.try(take(store, open, OccurrenceLock(wake.occurrence)))
      let key = wake_key(wake)
      let at = int.max(wire.milliseconds(now(store)), 0)
      use <- bool.guard(wire.milliseconds(wake.at) > at, Ok(False))
      case rows.read(store.tables.rows, open.buffer, key) {
        // Due, and past any backoff: a second runtime on the same store
        // cannot deliver a wake-up that is still backing off.
        Ok(WakeRow(not_before:, ..)) if not_before <= at -> {
          drop_wake(store, open, key)
          Ok(True)
        }
        _ -> Ok(False)
      }
    },
    add_wake: fn(tx, wake: Wake) {
      use store, open <- within(tx)
      use Nil <- result.try(take(store, open, OccurrenceLock(wake.occurrence)))
      put_wake(store, open, wake_key(wake), WakeRow(0, 0))
      Ok(Nil)
    },
    undelivered: fn(limit) {
      let at = wire.milliseconds(now(store))
      // Only notices past their backoff are read, so notices backing off
      // never fill the batch.
      // A raw read, as for `due`: `deliver_notice` checks again under the
      // notice's lock.
      {
        rows.pending_due(store.tables.rows, at, limit)
        |> list.filter_map(fn(pair) {
          case pair.0 {
            PendingKey(id:, ..) ->
              case rows.read_committed(store.tables.rows, NoticeKey(id, 0)) {
                Ok(NoticeRow(notice:, ..)) -> Ok(Pending(id:, notice:))
                _ -> Error(Nil)
              }
            _ -> Error(Nil)
          }
        })
      }
      |> Ok
    },
    deliver_notice: fn(tx, pending: Pending) {
      use store, open <- within(tx)
      use Nil <- result.try(take(store, open, rows.NoticeLock(pending.id)))
      case
        rows.read(store.tables.rows, open.buffer, PendingKey(pending.id, 0))
      {
        Ok(_) -> {
          rows.delete(open.buffer, PendingKey(pending.id, 0))
          update_notice(store, open, pending.id, rows.NoticeDelivered)
          Ok(True)
        }
        Error(Nil) -> Ok(False)
      }
    },
    submit: fn(tx, key, payload) {
      use store, open <- within(tx)
      let id = rows.next(store.tables.counters, "trigger")
      rows.put(
        open.buffer,
        TriggerKey(id, 0),
        TriggerRow(key:, payload:, attempts: 0, not_before: 0),
      )
      Ok(Nil)
    },
    claim_trigger: fn() {
      let at = wire.milliseconds(now(store))
      // Only triggers past their backoff are read, so triggers backing
      // off never hide the ones behind them.
      // A raw read: the claim reads the row again before it hands it out.
      rows.due_triggers(store.tables.rows, at, 256)
      |> list.find_map(fn(pair) {
        case pair {
          #(TriggerKey(id:, ..), TriggerRow(key:, payload:, ..)) ->
            case rows.claim(store.tables.claims, id) {
              // Read the row again under the claim: a worker that just
              // finished it committed before it released its claim, so a
              // trigger gone now is not handed out.
              True ->
                case rows.read_committed(store.tables.rows, TriggerKey(id, 0)) {
                  Ok(TriggerRow(..)) -> Ok(Submitted(id:, key:, payload:))
                  _ -> {
                    rows.unclaim(store.tables.claims, id)
                    Error(Nil)
                  }
                }
              False -> Error(Nil)
            }
          _ -> Error(Nil)
        }
      })
      |> option.from_result
      |> Ok
    },
    finish_trigger: fn(tx, submitted: Submitted) {
      use store, open <- within(tx)
      use Nil <- result.try(take(store, open, rows.TriggerLock(submitted.id)))
      let key = TriggerKey(submitted.id, 0)
      let found = rows.read(store.tables.rows, open.buffer, key)
      rows.delete(open.buffer, key)
      Ok(result.is_ok(found))
    },
    release: fn(submitted: Submitted) {
      rows.unclaim(store.tables.claims, submitted.id)
    },
    failed: fn(tx, job, _reason) {
      use store, open <- within(tx)
      failed(store, open, job)
    },
    set_aside: fn(tx, job, reason) {
      use store, open <- within(tx)
      set_aside(store, open, job, reason)
    },
    set_aside_occurrence: fn(tx, occurrence, reason) {
      use store, open <- within(tx)
      set_aside_occurrence(store, open, occurrence, reason)
    },
    aside: fn() {
      scan_kind_committed(store, AsideKey(0, 0), 0)
      |> list.filter_map(fn(pair) {
        case pair.1 {
          AsideRow(job:, reason:, attempts:, at:) ->
            Ok(Aside(
              job: aside_job(job),
              reason:,
              attempts:,
              at: wire.from_milliseconds(at),
            ))
          _ -> Error(Nil)
        }
      })
      |> Ok
    },
  )
}

fn wake_key(wake: Wake) -> Key {
  WakeKey(#(wake.point, wake.occurrence), wire.milliseconds(wake.at))
}

/// Write a wake-up's row and its row in the time-ordered index, in place
/// of any it had.
fn put_wake(store: Store, open: Open, key: Key, row: Row) -> Nil {
  drop_wake(store, open, key)
  rows.put(open.buffer, key, row)
  case wake_at_key(key, row) {
    Ok(index) -> rows.put(open.buffer, index, IndexRow)
    Error(Nil) -> Nil
  }
}

/// Remove a wake-up's row and its row in the time-ordered index.
fn drop_wake(store: Store, open: Open, key: Key) -> Nil {
  case rows.read(store.tables.rows, open.buffer, key) {
    Ok(row) -> {
      rows.delete(open.buffer, key)
      case wake_at_key(key, row) {
        Ok(index) -> rows.delete(open.buffer, index)
        Error(Nil) -> Nil
      }
    }
    Error(Nil) -> Nil
  }
}

/// A wake-up's row in the time-ordered index: due at its time, or at the
/// end of its backoff when that is later.
fn wake_at_key(key: Key, row: Row) -> Result(Key, Nil) {
  case key, row {
    WakeKey(job: #(point, occurrence), at:), WakeRow(not_before:, ..) ->
      Ok(WakeAtKey(int.max(at, not_before), #(point, occurrence, at)))
    _, _ -> Error(Nil)
  }
}

fn update_notice(
  store: Store,
  open: Open,
  id: Int,
  state: rows.NoticeState,
) -> Nil {
  case rows.read(store.tables.rows, open.buffer, NoticeKey(id, 0)) {
    Ok(NoticeRow(..) as row) ->
      rows.put(open.buffer, NoticeKey(id, 0), NoticeRow(..row, state:))
    _ -> Nil
  }
}

fn failed(store: Store, open: Open, job: Job) -> Result(Int, StoreError) {
  case job {
    WakeJob(wake:) -> {
      use Nil <- result.try(take(store, open, OccurrenceLock(wake.occurrence)))
      let key = wake_key(wake)
      case rows.read(store.tables.rows, open.buffer, key) {
        Ok(WakeRow(attempts:, ..)) -> {
          put_wake(
            store,
            open,
            key,
            WakeRow(attempts + 1, later(store, attempts + 1)),
          )
          Ok(attempts + 1)
        }
        _ -> Ok(0)
      }
    }
    NoticeJob(pending:) -> {
      use Nil <- result.try(take(store, open, rows.NoticeLock(pending.id)))
      case rows.read(store.tables.rows, open.buffer, NoticeKey(pending.id, 0)) {
        Ok(NoticeRow(attempts:, ..) as row) -> {
          rows.put(
            open.buffer,
            NoticeKey(pending.id, 0),
            NoticeRow(
              ..row,
              attempts: attempts + 1,
              not_before: later(store, attempts + 1),
            ),
          )
          case
            rows.read(store.tables.rows, open.buffer, PendingKey(pending.id, 0))
          {
            Ok(_) ->
              rows.put(
                open.buffer,
                PendingKey(pending.id, 0),
                PendingRow(later(store, attempts + 1)),
              )
            Error(Nil) -> Nil
          }
          Ok(attempts + 1)
        }
        _ -> Ok(0)
      }
    }
    TriggerJob(submitted:) -> {
      use Nil <- result.try(take(store, open, rows.TriggerLock(submitted.id)))
      let key = TriggerKey(submitted.id, 0)
      case rows.read(store.tables.rows, open.buffer, key) {
        Ok(TriggerRow(attempts:, ..) as row) -> {
          rows.put(
            open.buffer,
            key,
            TriggerRow(
              ..row,
              attempts: attempts + 1,
              not_before: later(store, attempts + 1),
            ),
          )
          Ok(attempts + 1)
        }
        _ -> Ok(0)
      }
    }
  }
}

/// Take an occurrence out of its queues and `waiting`, and set aside its
/// pending wake-ups. Its head and entries stay, so it can still be read.
fn set_aside_occurrence(
  store: Store,
  open: Open,
  occurrence: String,
  reason: String,
) -> Result(Nil, StoreError) {
  use Nil <- result.try(take(store, open, OccurrenceLock(occurrence)))
  case rows.read(store.tables.rows, open.buffer, HeadKey(occurrence, 0)) {
    Ok(HeadRow(head:, ..)) -> {
      list.each(head.awaiting, fn(set) {
        rows.delete(open.buffer, QueueKey(set, queue_order(occurrence, head)))
      })
      rows.delete(
        open.buffer,
        WaitingKey(#(head.point, head.subject), occurrence),
      )
      rows.scan(
        store.tables.rows,
        open.buffer,
        WakeKey(#(head.point, occurrence), 0),
      )
      |> list.filter_map(wake_of)
      |> list.try_each(fn(wake) {
        set_aside(store, open, WakeJob(wake), reason)
      })
    }
    _ -> Ok(Nil)
  }
}

fn set_aside(
  store: Store,
  open: Open,
  job: Job,
  reason: String,
) -> Result(Nil, StoreError) {
  let at = wire.milliseconds(now(store))
  let keep = fn(aside, attempts) {
    let id = rows.next(store.tables.counters, "aside")
    rows.put(
      open.buffer,
      AsideKey(id, 0),
      AsideRow(aside, reason, attempts, at),
    )
  }
  case job {
    WakeJob(wake:) -> {
      use Nil <- result.try(take(store, open, OccurrenceLock(wake.occurrence)))
      let key = wake_key(wake)
      let attempts = case rows.read(store.tables.rows, open.buffer, key) {
        Ok(WakeRow(attempts:, ..)) -> attempts
        _ -> 0
      }
      drop_wake(store, open, key)
      keep(
        rows.AsideWake(wake.point, wake.occurrence, wire.milliseconds(wake.at)),
        attempts,
      )
      Ok(Nil)
    }
    NoticeJob(pending:) -> {
      use Nil <- result.try(take(store, open, rows.NoticeLock(pending.id)))
      let attempts = case
        rows.read(store.tables.rows, open.buffer, NoticeKey(pending.id, 0))
      {
        Ok(NoticeRow(attempts:, ..)) -> attempts
        _ -> 0
      }
      rows.delete(open.buffer, PendingKey(pending.id, 0))
      update_notice(store, open, pending.id, rows.NoticeSetAside(reason))
      keep(
        rows.AsideNotice(
          pending.id,
          pending.notice.point,
          pending.notice.occurrence,
        ),
        attempts,
      )
      Ok(Nil)
    }
    TriggerJob(submitted:) -> {
      use Nil <- result.try(take(store, open, rows.TriggerLock(submitted.id)))
      let key = TriggerKey(submitted.id, 0)
      let attempts = case rows.read(store.tables.rows, open.buffer, key) {
        Ok(TriggerRow(attempts:, ..)) -> attempts
        _ -> 0
      }
      rows.delete(open.buffer, key)
      keep(
        rows.AsideTrigger(submitted.id, submitted.key, submitted.payload),
        attempts,
      )
      Ok(Nil)
    }
  }
}

fn aside_job(job: rows.AsideJob) -> Job {
  case job {
    rows.AsideWake(point:, occurrence:, at:) ->
      WakeJob(Wake(point:, occurrence:, at: wire.from_milliseconds(at)))
    rows.AsideNotice(id:, point:, occurrence:) ->
      NoticeJob(Pending(id:, notice: Notice(point:, occurrence:)))
    rows.AsideTrigger(id:, key:, payload:) ->
      TriggerJob(Submitted(id:, key:, payload:))
  }
}
