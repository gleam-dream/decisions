//// The durable work a runtime delivers, as a contract any store can
//// implement: wake-ups that are due, settlement notices not yet
//// delivered, and triggers not yet turned into recommendations. Each is a
//// row in the store, so the processes that deliver them keep nothing that
//// a kill could lose.
////
//// `decisions_otp/store.backlog` implements it over the process-safe
//// in-memory store. Another store implements it over its own tables and
//// can then run `decisions_otp/runtime` and the scenarios of
//// `decisions_otp/stress` unchanged.
////
//// What an implementation must guarantee:
////
//// - `take_wake`, `deliver_notice`, `finish_trigger`, `failed` and
////   `set_aside` lock the job they act on. `take_wake`, `deliver_notice` and `finish_trigger` run inside the
////   transaction that acts on the job. They return `False` when another
////   delivery already took it, so a job is acted on at most once per
////   committed transaction. Taking a wake-up locks its occurrence.
//// - `claim_trigger` claims outside any transaction, and **the claim dies
////   with the process that holds it**: a worker killed while it works a
////   trigger leaves the trigger to the next worker. It never hands out a
////   trigger already removed: check the row again after claiming it.
//// - A job set aside leaves its queue and stays readable through `aside`.
////   `set_aside` acts on a **job** (a wake-up, a notice, a trigger);
////   `set_aside_occurrence` acts on the occurrence a wake-up is about, when
////   its record cannot be acted on, so that it leaves every queue and
////   `waiting`, as in PostgreSQL.
//// - `failed` counts a failed attempt in a transaction of its own and
////   returns how many have failed so far.
//// - Reads outside a transaction (`due`, `undelivered`, `aside`) see only
////   committed rows.
////
//// ```gleam
//// import decisions_otp/backlog
//// import decisions_otp/store
////
//// let jobs = store.backlog(s)
//// let assert Ok(Nil) =
////   store.transaction(s, fn(tx) { jobs.submit(tx, "message-42", "{}") })
//// ```

import decisions/store.{type Notice, type StoreError, type Wake}
import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}

/// A settlement notice waiting for delivery, with the id the store gave it.
pub type Pending {
  Pending(id: Int, notice: Notice)
}

/// A trigger submitted for a worker: `key` becomes the occurrence's id
/// through `decisions.recommend_once`, and `payload` is the application's
/// own text.
pub type Submitted {
  Submitted(id: Int, key: String, payload: String)
}

/// One job of the backlog.
pub type Job {
  /// A wake-up for an occurrence.
  WakeJob(wake: Wake)
  /// A settlement notice.
  NoticeJob(pending: Pending)
  /// A trigger for a worker.
  TriggerJob(submitted: Submitted)
}

/// A job set aside after it failed, with why, and how many attempts
/// failed.
pub type Aside {
  Aside(job: Job, reason: String, attempts: Int, at: Timestamp)
}

/// What a runtime's transaction over the backlog found. It is the value
/// that `Backlog.transaction` carries, so one transaction function serves
/// every job.
pub type Handled {
  /// The job was acted on. `again` is when a wake-up must be delivered
  /// again, because it arrived early.
  Acted(again: Option(Timestamp))
  /// Another delivery already took the job.
  Gone
  /// A failed attempt was counted; `attempts` have failed so far.
  Counted(attempts: Int)
}

/// The backlog of one store. Every function that takes `tx` runs in the
/// caller's transaction.
pub type Backlog(tx) {
  Backlog(
    /// Run `body` in one transaction: commit on `Ok`, roll back on
    /// `Error`. When it raises, roll back and raise again.
    transaction: fn(fn(tx) -> Result(Handled, String)) ->
      Result(Handled, String),
    /// The store's clock.
    now: fn() -> Timestamp,
    /// Committed wake-ups due at the given time, the earliest first, at
    /// most the given number.
    due: fn(Timestamp, Int) -> Result(List(Wake), StoreError),
    /// Take a wake-up off the queue. `False` when it is gone.
    take_wake: fn(tx, Wake) -> Result(Bool, StoreError),
    /// Add one wake-up, leaving the occurrence's others in place.
    add_wake: fn(tx, Wake) -> Result(Nil, StoreError),
    /// Committed notices not yet delivered, oldest first, at most the
    /// given number.
    undelivered: fn(Int) -> Result(List(Pending), StoreError),
    /// Mark a notice delivered. `False` when it was already.
    deliver_notice: fn(tx, Pending) -> Result(Bool, StoreError),
    /// Admit a trigger, in the transaction that learnt of it.
    submit: fn(tx, String, String) -> Result(Nil, StoreError),
    /// Claim the oldest trigger no live process holds, for the calling
    /// process.
    claim_trigger: fn() -> Result(Option(Submitted), StoreError),
    /// Remove a worked trigger. `False` when it was gone.
    finish_trigger: fn(tx, Submitted) -> Result(Bool, StoreError),
    /// Release the calling process's claim on a trigger. The runtime
    /// calls it after the transaction that finished, counted or set aside
    /// the trigger has ended, never inside it, so that no other worker
    /// claims a trigger whose fate is not yet committed.
    release: fn(Submitted) -> Nil,
    /// Count a failed attempt at a job; returns the attempts failed so
    /// far, or 0 when the job is gone. Two transactions counting one job
    /// must not both see the same count: lock the job. It also **postpones
    /// the job**: `due`, `undelivered` and `claim_trigger` leave it out
    /// until a backoff the store chooses has passed (the in-memory store
    /// waits `Config.retry_backoff`, doubled after each failure, at most
    /// 64 times).
    failed: fn(tx, Job, String) -> Result(Int, StoreError),
    /// Take a job out of its queue and keep it, with the reason, where
    /// `aside` reads it.
    set_aside: fn(tx, Job, String) -> Result(Nil, StoreError),
    /// Set aside an occurrence whose record cannot be acted on (it no
    /// longer decodes, for one): take it out of every queue and of the
    /// port's `waiting`, and set aside each of its pending wake-ups, with
    /// the reason. The runtime calls it in the transaction that sets aside
    /// the wake-up that found the record so.
    set_aside_occurrence: fn(tx, String, String) -> Result(Nil, StoreError),
    /// Every job set aside, oldest first.
    aside: fn() -> Result(List(Aside), StoreError),
  )
}

/// The point and occurrence a job is about, or the trigger's key, for a
/// report.
pub fn about(job: Job) -> #(String, String) {
  case job {
    WakeJob(wake:) -> #(wake.point, wake.occurrence)
    NoticeJob(pending:) -> #(pending.notice.point, pending.notice.occurrence)
    TriggerJob(submitted:) -> #("", submitted.key)
  }
}
