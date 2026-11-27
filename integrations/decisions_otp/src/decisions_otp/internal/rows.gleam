//// The rows of the process-safe store, and typed access to the ETS tables
//// that hold them. Every key is a variant with two fields, which the
//// foreign code relies on to scan by tag or by tag and first field.

import decisions/store.{type Head, type Notice, type Stored}
import decisions/vocabulary.{type Ref, type Subject}
import gleam/option.{type Option}

/// The key of a row.
pub type Key {
  EntryKey(occurrence: String, seq: Int)
  HeadKey(occurrence: String, unused: Int)
  /// `job` is `#(point, occurrence)`; `at` is in milliseconds.
  WakeKey(job: #(String, String), at: Int)
  NoticeKey(id: Int, unused: Int)
  /// Present while a notice waits for delivery.
  PendingKey(id: Int, unused: Int)
  TriggerKey(id: Int, unused: Int)
  AsideKey(id: Int, unused: Int)
  AppKey(table: String, key: String)
  EvidenceKey(ref: Ref, unused: Int)
  /// One row per decision set an occurrence waits in, in queue order:
  /// `#(due ms or a time later than any, arrived ms, id)`.
  QueueKey(set: String, order: #(Int, Int, String))
  /// Present while `waiting` must return the occurrence: `about` is
  /// `#(point, subject)`.
  WaitingKey(about: #(String, Subject), id: String)
  /// Every occurrence of a point, in the order the owner committed their
  /// first entries: `#(commit, id)`. A transaction writes commit -1; the
  /// owner gives the number when it applies the commit.
  PointKey(point: String, at: #(Int, String))
  /// Every settled occurrence of a point, in commit order:
  /// `#(commit ms, commit, id)`, both given by the owner at commit, the ms
  /// never decreasing. A transaction writes -1 for both.
  SettledKey(point: String, at: #(Int, Int, String))
  /// Released, sampled and not yet reviewed.
  ReviewKey(point: String, id: String)
  /// One row per occurrence that belongs to a bundle, so `members` reads
  /// a bundle in id order.
  BundleKey(bundle: String, id: String)
}

/// Where a settlement notice stands.
pub type NoticeState {
  NoticePending
  NoticeDelivered
  NoticeSetAside(reason: String)
}

/// What a job set aside was.
pub type AsideJob {
  AsideWake(point: String, occurrence: String, at: Int)
  AsideNotice(id: Int, point: String, occurrence: String)
  AsideTrigger(id: Int, key: String, payload: String)
}

/// A row.
pub type Row {
  EntryRow(stored: Stored)
  HeadRow(head: Head, last: Int, released: Bool)
  /// `not_before`: milliseconds before which a failed one is not due.
  WakeRow(attempts: Int, not_before: Int)
  NoticeRow(notice: Notice, state: NoticeState, attempts: Int, not_before: Int)
  /// `not_before`: milliseconds before which a failed one is not due.
  PendingRow(not_before: Int)
  TriggerRow(key: String, payload: String, attempts: Int, not_before: Int)
  AsideRow(job: AsideJob, reason: String, attempts: Int, at: Int)
  AppRow(value: String)
  EvidenceRow(body: String)
  IndexRow
}

/// What a transaction locks.
pub type Lock {
  OccurrenceLock(id: String)
  NoticeLock(id: Int)
  TriggerLock(id: Int)
  NamedLock(name: String)
}

/// A table of committed rows, or of named counters.
pub type Table

/// One transaction's writes and the locks it knows it holds.
pub type Buffer

/// A copy of a buffer, for a savepoint.
pub type Snapshot

/// An exception caught with `attempt`.
pub type Crash

@external(erlang, "decisions_otp_ffi", "new_table")
pub fn new_table() -> Table

@external(erlang, "decisions_otp_ffi", "new_buffer")
pub fn new_buffer() -> Buffer

@external(erlang, "decisions_otp_ffi", "drop_buffer")
pub fn drop_buffer(buffer: Buffer) -> Nil

@external(erlang, "decisions_otp_ffi", "read")
pub fn read(table: Table, buffer: Buffer, key: Key) -> Result(Row, Nil)

@external(erlang, "decisions_otp_ffi", "read_committed")
pub fn read_committed(table: Table, key: Key) -> Result(Row, Nil)

/// Rows whose key has `probe`'s tag and first field, in key order.
@external(erlang, "decisions_otp_ffi", "scan")
pub fn scan(table: Table, buffer: Buffer, probe: Key) -> List(#(Key, Row))

@external(erlang, "decisions_otp_ffi", "scan_committed")
pub fn scan_committed(table: Table, probe: Key) -> List(#(Key, Row))

/// Rows whose key has `probe`'s tag, in key order.
@external(erlang, "decisions_otp_ffi", "scan_kind")
pub fn scan_kind(table: Table, buffer: Buffer, probe: Key) -> List(#(Key, Row))

/// Committed rows whose key has `probe`'s tag, at most `limit` of them
/// when `limit` is positive.
@external(erlang, "decisions_otp_ffi", "scan_kind_committed")
pub fn scan_kind_committed(
  table: Table,
  probe: Key,
  limit: Int,
) -> List(#(Key, Row))

/// Committed rows with `probe`'s tag whose second key field is at most
/// `max`.
@external(erlang, "decisions_otp_ffi", "scan_until")
pub fn scan_until(table: Table, probe: Key, max: Int) -> List(#(Key, Row))

/// Rows whose key has `probe`'s tag and first field, in key order, at
/// most `limit`.
@external(erlang, "decisions_otp_ffi", "scan_limit")
pub fn scan_limit(
  table: Table,
  buffer: Buffer,
  probe: Key,
  limit: Int,
) -> List(#(Key, Row))

/// Up to `limit` committed rows whose key has `probe`'s tag and first
/// field, strictly after `after` (from the first when `None`), in key
/// order. It costs what it returns.
@external(erlang, "decisions_otp_ffi", "range")
pub fn range(
  table: Table,
  probe: Key,
  after: Option(Key),
  limit: Int,
) -> List(#(Key, Row))

/// Committed triggers whose backoff has passed at `now`, oldest first.
@external(erlang, "decisions_otp_ffi", "due_triggers")
pub fn due_triggers(table: Table, now: Int, limit: Int) -> List(#(Key, Row))

/// Committed pending notices whose backoff has passed at `now`.
@external(erlang, "decisions_otp_ffi", "pending_due")
pub fn pending_due(table: Table, now: Int, limit: Int) -> List(#(Key, Row))

/// Run `read` between two even readings of the commit version, so that it
/// saw no commit in part. `Error(Nil)` when commits kept it from that.
@external(erlang, "decisions_otp_ffi", "stable")
pub fn stable(table: Table, read: fn() -> a) -> Result(a, Nil)

/// Make the commit version odd before a commit is applied and even after.
@external(erlang, "decisions_otp_ffi", "bump_version")
pub fn bump_version(table: Table) -> Int

/// The commit version: twice the number of commits applied.
@external(erlang, "decisions_otp_ffi", "version")
pub fn version(table: Table) -> Int

/// The store's clock in milliseconds, from its counters.
pub fn clock_ms(counters: Table) -> Int {
  let base = case peek(counters, "clock_stopped") {
    0 -> system_ms()
    _ -> 0
  }
  base + peek(counters, "clock_offset")
}

@external(erlang, "decisions_otp_ffi", "buffer_put")
pub fn put(buffer: Buffer, key: Key, row: Row) -> Nil

@external(erlang, "decisions_otp_ffi", "buffer_delete")
pub fn delete(buffer: Buffer, key: Key) -> Nil

/// Every write of a buffer: `Some(row)` to put, `None` to delete.
@external(erlang, "decisions_otp_ffi", "buffer_writes")
pub fn writes(buffer: Buffer) -> List(#(Key, Option(Row)))

/// The rows a buffer puts under keys with `probe`'s tag.
@external(erlang, "decisions_otp_ffi", "buffer_heads")
pub fn written_of_kind(buffer: Buffer, probe: Key) -> List(#(Key, Row))

@external(erlang, "decisions_otp_ffi", "snapshot")
pub fn snapshot(buffer: Buffer) -> Snapshot

@external(erlang, "decisions_otp_ffi", "restore")
pub fn restore(buffer: Buffer, snapshot: Snapshot) -> Nil

@external(erlang, "decisions_otp_ffi", "holds_lock")
pub fn holds_lock(buffer: Buffer, lock: Lock) -> Bool

@external(erlang, "decisions_otp_ffi", "note_lock")
pub fn note_lock(buffer: Buffer, lock: Lock) -> Nil

@external(erlang, "decisions_otp_ffi", "apply_writes")
pub fn apply_writes(table: Table, writes: List(#(Key, Option(Row)))) -> Nil

@external(erlang, "decisions_otp_ffi", "all_rows")
pub fn all_rows(table: Table) -> List(#(Key, Row))

@external(erlang, "decisions_otp_ffi", "load_rows")
pub fn load_rows(table: Table, rows: List(#(Key, Row))) -> Nil

@external(erlang, "decisions_otp_ffi", "all_rows")
pub fn all_counters(table: Table) -> List(#(String, Int))

@external(erlang, "decisions_otp_ffi", "load_rows")
pub fn load_counters(table: Table, rows: List(#(String, Int))) -> Nil

/// The next value of a named counter: 1, 2, 3 and so on.
@external(erlang, "decisions_otp_ffi", "counter")
pub fn next(counters: Table, name: String) -> Int

@external(erlang, "decisions_otp_ffi", "peek_counter")
pub fn peek(counters: Table, name: String) -> Int

@external(erlang, "decisions_otp_ffi", "put_counter")
pub fn set(counters: Table, name: String, value: Int) -> Nil

/// Claim `id` for the calling process. False when a live process holds it.
@external(erlang, "decisions_otp_ffi", "claim")
pub fn claim(claims: Table, id: Int) -> Bool

@external(erlang, "decisions_otp_ffi", "unclaim")
pub fn unclaim(claims: Table, id: Int) -> Nil

@external(erlang, "decisions_otp_ffi", "attempt")
pub fn attempt(body: fn() -> a) -> Result(a, Crash)

@external(erlang, "decisions_otp_ffi", "reraise")
pub fn reraise(crash: Crash) -> a

@external(erlang, "decisions_otp_ffi", "system_ms")
pub fn system_ms() -> Int
