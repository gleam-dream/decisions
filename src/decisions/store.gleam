//// The storage port: everything the desk needs from a store, always inside
//// the caller's transaction. An adapter implements `Port` once for its
//// store; `decisions/memory` is the one in this package, and
//// `decisions/conformance` checks any adapter against the contract below.
////
//// The port has nine functions. Each exists because a guarantee rests on
//// the store and the core cannot provide it alone:
////
//// | Function | Why it exists |
//// | --- | --- |
//// | `load` | Reads an occurrence and **locks it, even when it does not exist yet**, so two deliveries of one trigger cannot both admit it |
//// | `append` | Adds entries and replaces the head in one write; refuses a sequence number it holds and a second release |
//// | `waiting` | Finds the undecided occurrences of a point about a subject, for superseding, in a stable order |
//// | `schedule` | Replaces an occurrence's pending wake-ups; an empty list cancels them |
//// | `settled` | Admits one durable notice that an occurrence settled, so what follows can start |
//// | `atomically` | A savepoint around the guard and the gated tool, so a tool that writes and then refuses leaves nothing behind |
//// | `now` | The store's clock, read after the lock |
//// | `new_id` | An id for an occurrence admitted without a key |
//// | `members` | Finds the occurrences of a bundle across every point, so whoever follows them can tell when all have settled |
////
//// The port offers no way to take, acknowledge or postpone a wake-up or a
//// notice. Delivery belongs to the runtime that drives the desk: the
//// supervised runtime of `decisions_otp` (its sweeper and dispatcher), and
//// the Grind workers of `decisions_postgres`. The port only records what
//// is pending.
////
//// `Inspection` is not part of the port. It is what an adapter supplies so
//// that `decisions/conformance` and `decisions/testing` can look at what it
//// stored.
////
//// Target-independent: builds for Erlang and JavaScript.

import decisions/vocabulary.{type Bundle, type Ref, type Subject}
import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}

/// An entry as the store keeps it. `kind` is the entry's kind (see
/// `decisions/entry.kind`), kept as a column so the store can hold "at
/// most one `released` per occurrence" behind a unique key. `event` is the
/// entry's JSON text, which only the point's codec decodes.
pub type Stored {
  Stored(seq: Int, at: Timestamp, kind: String, event: String)
}

/// What the store keeps beside an occurrence's entries, so that queues and
/// superseding can find it without decoding an entry. The desk writes it
/// with every append.
pub type Head {
  Head(
    /// The decision point's name.
    point: String,
    subject: Subject,
    /// Where the occurrence stands. `Pending` while the record has not
    /// begun (expected, or holding only failed attempts). Store it with `status_name`.
    status: Status,
    /// The decision sets whose queues the occurrence waits in. Empty
    /// unless the status is `Awaiting`.
    awaiting: List(String),
    /// When the occurrence next needs attention: the end of its validity
    /// while it waits, the end of its hold while it is held.
    due: Option(Timestamp),
    /// When the recommendation arrived, or the first attempt when there is
    /// no recommendation yet. A queue orders by `due`, then by this.
    arrived: Timestamp,
    /// Who has approved the output that stands. A queue leaves a card out
    /// for a validator who already approved it.
    approved: List(String),
    /// Who may not decide this occurrence whatever sets they hold: whoever
    /// already approved the output that stands, and the person who asked
    /// or recommended it as their own act when every alternative of the
    /// eligibility bars them. A queue leaves the card out for them. Someone
    /// barred only under the one alternative they qualify for (the
    /// requester holding only `finance` under
    /// `Either([SomeoneElseHolding("finance"), AnyoneHolding("head")])`)
    /// is not listed, so a queue may still show them the card, and `open`
    /// refuses them with `NotEligible`. Empty unless the status is
    /// `Awaiting`.
    may_not_decide: List(String),
    /// Sampled, released, and not yet reviewed.
    review_pending: Bool,
    /// The bundle the occurrence belongs to, `None` for one proposed
    /// alone and for a record that has not begun. `members` finds the
    /// occurrences of a bundle by it.
    bundle: Option(Bundle),
  )
}

/// Where an occurrence stands, as its head keeps it: the nine statuses of
/// `decisions/occurrence.Status` without their payloads, and `Pending` for
/// a record that has not begun: a recommendation is expected
/// (`decisions.expect`) or only failed attempts are recorded. A record
/// superseded before it began is `Expired`.
pub type Status {
  Pending
  Recommended
  Awaiting
  Accepted
  Held
  Released
  Rejected
  Expired
  Withdrawn
  Refused
}

/// Every status, in the order of `Status`.
pub const statuses = [
  Pending,
  Recommended,
  Awaiting,
  Accepted,
  Held,
  Released,
  Rejected,
  Expired,
  Withdrawn,
  Refused,
]

/// The stable name a store keeps for a status, such as `"awaiting"`.
pub fn status_name(status: Status) -> String {
  case status {
    Pending -> "pending"
    Recommended -> "recommended"
    Awaiting -> "awaiting"
    Accepted -> "accepted"
    Held -> "held"
    Released -> "released"
    Rejected -> "rejected"
    Expired -> "expired"
    Withdrawn -> "withdrawn"
    Refused -> "refused"
  }
}

/// The status a stored name stands for.
pub fn parse_status(name: String) -> Result(Status, Nil) {
  case name {
    "pending" -> Ok(Pending)
    "recommended" -> Ok(Recommended)
    "awaiting" -> Ok(Awaiting)
    "accepted" -> Ok(Accepted)
    "held" -> Ok(Held)
    "released" -> Ok(Released)
    "rejected" -> Ok(Rejected)
    "expired" -> Ok(Expired)
    "withdrawn" -> Ok(Withdrawn)
    "refused" -> Ok(Refused)
    _ -> Error(Nil)
  }
}

/// Whether `waiting` returns a record with this status: it has not begun,
/// or it is recommended, awaiting or held, so nothing has been released
/// and an event can still supersede it.
pub fn is_waiting(status: Status) -> Bool {
  case status {
    Pending | Recommended | Awaiting | Held -> True
    Accepted | Released | Rejected | Expired | Withdrawn | Refused -> False
  }
}

/// Whether an occurrence with this status has settled: nothing changes its
/// outcome any more. A record that has not begun is `Pending`, not
/// settled; one superseded or lapsed before it began is `Expired`.
pub fn is_settled(status: Status) -> Bool {
  case status {
    Released | Rejected | Expired | Withdrawn | Refused -> True
    Pending | Recommended | Awaiting | Accepted | Held -> False
  }
}

/// Why the store refused or failed.
pub type StoreError {
  /// The write breaks the contract: a sequence number the store already
  /// holds, a second `released` entry, or entries that do not follow the
  /// last one. Roll the transaction back. Running it again from the start
  /// reloads the record, so it is safe, but a conflict that repeats points
  /// at a second writer that does not take the lock.
  Conflict(detail: String)
  /// Contention: a deadlock, or a lock wait that timed out. The store
  /// wrote nothing. Roll the transaction back and run it again from the
  /// start; that is safe.
  Contended(detail: String)
  /// The store could not do it and the outcome is unknown: a lost
  /// connection, a timeout after the commit was sent. Roll back; before
  /// running it again, read the record to see whether it committed (every
  /// verb is safe to repeat on what it finds: `recommend_once` finds its
  /// occurrence, a verdict sent again on the same card stands).
  Unavailable(detail: String)
}

/// A wake-up the store holds: deliver `decisions.wake` (or the point's
/// `decisions.waker`) for `occurrence` at `at`.
pub type Wake {
  Wake(point: String, occurrence: String, at: Timestamp)
}

/// A durable notice that an occurrence of `point` settled.
pub type Notice {
  Notice(point: String, occurrence: String)
}

/// Everything the desk needs from a store. Every function runs in the
/// caller's transaction `tx`.
pub type Port(tx) {
  Port(
    /// The occurrence's entries in sequence order, and a lock on its id
    /// for the rest of the transaction. **The lock is taken when no entry
    /// exists too**: a second transaction that loads the same id waits
    /// until the first ends, then sees what it stored. Empty when there is
    /// none.
    ///
    /// The core also loads ids that never hold entries, purely as locks:
    /// `decisions.happened` loads `decisions.subject_lock(point, subject)`
    /// (prefix `decisions.subject-lock:`) to serialise on a subject. Loading
    /// must not create a row, head or anything else `waiting` or an
    /// inspection could see; the lock alone must last until the
    /// transaction ends.
    load: fn(tx, String) -> Result(List(Stored), StoreError),
    /// Append entries after the last one and replace the head. The first
    /// entry has `seq` 1 and each next one the next number. The store
    /// refuses with `Conflict` a sequence number it already holds, a gap,
    /// and a second `released` entry for one occurrence. Entries are never
    /// changed or removed.
    append: fn(tx, String, Head, List(Stored)) -> Result(Nil, StoreError),
    /// The ids of a point's occurrences about a subject whose head status
    /// is `Pending`, `Recommended`, `Awaiting` or `Held` (`is_waiting`):
    /// records that have not begun, and occurrences nothing of which has
    /// been released. In ascending id order, so that
    /// every transaction locks several occurrences in one order. An adapter
    /// may leave out an occurrence it has set aside as poison (a record
    /// that no longer decodes), so that one bad record does not stop a
    /// supersession; the PostgreSQL adapter does.
    waiting: fn(tx, String, Subject) -> Result(List(String), StoreError),
    /// Replace every pending wake-up of a point's occurrence with one at
    /// each of these times. An empty list cancels them all. A wake-up the
    /// store already delivered is not affected.
    schedule: fn(tx, String, String, List(Timestamp)) -> Result(Nil, StoreError),
    /// Admit a durable notice that a point's occurrence settled. The desk
    /// calls it once per occurrence.
    settled: fn(tx, String, String) -> Result(Nil, StoreError),
    /// Run `body` inside a savepoint. When it returns `Error`, everything
    /// it wrote is undone and the transaction stays usable; when it
    /// returns `Ok`, its writes stay. The outer `Result` is the savepoint's
    /// own failure. The body's error text belongs to the desk: pass it
    /// back unchanged and do not interpret it. When the body raises, undo
    /// its writes and let the raise continue.
    atomically: fn(tx, fn(tx) -> Result(List(Ref), String)) ->
      Result(Result(List(Ref), String), StoreError),
    /// The wall clock at the moment of the call, at any resolution: the
    /// desk keeps whole milliseconds (rounded down), and every time it
    /// stores, schedules or puts on a head is a whole millisecond. It is
    /// not the start of the transaction: in PostgreSQL `clock_timestamp()`, not `now()`. The
    /// desk reads it after `load` has taken the lock, so a verb that waited
    /// for the lock is stamped with when it ran, and it never stores an
    /// entry earlier than the one before it. One process cannot check this
    /// clause honestly (a frozen clock looks the same), so
    /// `decisions/conformance` does not; the multi-process suites do.
    now: fn(tx) -> Timestamp,
    /// A new, unique occurrence id.
    new_id: fn(tx) -> String,
    /// The ids and heads of every occurrence, of any point, whose head
    /// names the bundle with this key, in ascending id order. It reads what
    /// is committed and what this transaction wrote, and takes no lock. A
    /// record set aside as poison is still returned, with the head it had.
    members: fn(tx, String) -> Result(List(#(String, Head)), StoreError),
  )
}

/// What an adapter lets tests see of its store. `decisions/conformance`
/// and `decisions/testing` read through it; the desk never does.
pub type Inspection(tx) {
  Inspection(
    /// The ids of every record of a point, in any order.
    occurrences: fn(tx, String) -> Result(List(String), StoreError),
    /// The head of a record, `None` when there is none.
    head: fn(tx, String) -> Result(Option(Head), StoreError),
    /// Every pending wake-up.
    wakes: fn(tx) -> Result(List(Wake), StoreError),
    /// Every settlement notice admitted, in the order admitted.
    notices: fn(tx) -> Result(List(Notice), StoreError),
  )
}

/// The error as one line of text.
pub fn describe(error: StoreError) -> String {
  case error {
    Conflict(detail:) -> "conflict: " <> detail
    Contended(detail:) -> "contention, nothing written: " <> detail
    Unavailable(detail:) -> "store unavailable: " <> detail
  }
}
