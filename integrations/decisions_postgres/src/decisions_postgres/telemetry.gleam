//// The events `decisions_postgres` emits through Sinal, for metrics and
//// logs. Each is emitted after the transaction it describes committed.
//// They are observations: a handler that misses one, or a forwarder that
//// drops one, loses nothing of the record. The record and the tables
//// `decisions_wakes` and `decisions_settled` are what is true.
////
//// | Event | When |
//// | --- | --- |
//// | `[decisions_postgres, wake, delivered]` | A wake-up's job ran `decisions.wake` and the wake-up is done |
//// | `[decisions_postgres, wake, rescheduled]` | A wake-up arrived before its time and will be delivered again |
//// | `[decisions_postgres, settlement, delivered]` | A settlement notice reached what follows the occurrence |
//// | `[decisions_postgres, record, set_aside]` | A wake-up, a notice or an occurrence was set aside as poisoned |
////
//// ```gleam
//// import decisions_postgres/telemetry
//// import sinal
////
//// let attachment =
////   sinal.observe(telemetry.set_aside(), fn(_, aside) {
////     log_warning(aside.point <> " " <> aside.occurrence <> ": " <> aside.reason)
////   })
//// ```
////
//// Handlers run in the worker's process unless the application routes the
//// prefix `["decisions_postgres"]` to a Sinal forwarder.
////
//// Every event's metadata names the store that emitted it as its first
//// field, `source` (set with `decisions_postgres.with_name`), so two
//// applications on one node can each count their own.

import sinal.{type Event}
import sinal/fields

/// How many things the event counts; always 1.
pub type Count {
  Count(count: Int)
}

/// A wake-up the worker delivered.
pub type Delivered {
  Delivered(
    /// The name of the store that emitted it (`decisions_postgres.with_name`).
    source: String,
    /// The wake-up's row in `decisions_wakes`.
    wake: Int,
    point: String,
    occurrence: String,
    /// Milliseconds from the wake-up's time to its delivery, by the
    /// database's clock.
    lag_ms: Int,
  )
}

/// A wake-up that arrived early and goes back to the queue.
pub type Rescheduled {
  Rescheduled(
    source: String,
    wake: Int,
    point: String,
    occurrence: String,
    /// When it will be delivered again, in Unix milliseconds.
    until_ms: Int,
  )
}

/// A settlement notice delivered to what follows.
pub type Settled {
  Settled(source: String, notice: Int, point: String, occurrence: String)
}

/// What was set aside.
pub type Kind {
  /// A wake-up whose delivery cannot succeed: its occurrence does not
  /// decode, or no desk serves its point.
  WakeUp
  /// A settlement notice whose follower failed on every attempt, or that
  /// no follower serves.
  Notice
  /// An occurrence whose entries do not decode with its point's codec. It
  /// leaves every queue.
  Occurrence
}

/// A record set aside so that it no longer blocks anything.
pub type SetAside {
  SetAside(
    source: String,
    kind: Kind,
    point: String,
    occurrence: String,
    reason: String,
  )
}

/// `[decisions_postgres, wake, delivered]`.
pub fn wake_delivered() -> Event(Count, Delivered) {
  sinal.event(["decisions_postgres", "wake", "delivered"], count(), {
    use source <- fields.include(fields.string("source"), get: fn(d: Delivered) {
      d.source
    })
    use wake <- fields.include(fields.int("wake"), get: fn(d) { d.wake })
    use point <- fields.include(fields.string("point"), get: fn(d) { d.point })
    use occurrence <- fields.include(fields.string("occurrence"), get: fn(d) {
      d.occurrence
    })
    use lag_ms <- fields.include(fields.int("lag_ms"), get: fn(d) { d.lag_ms })
    fields.success(Delivered(source:, wake:, point:, occurrence:, lag_ms:))
  })
}

/// `[decisions_postgres, wake, rescheduled]`.
pub fn wake_rescheduled() -> Event(Count, Rescheduled) {
  sinal.event(["decisions_postgres", "wake", "rescheduled"], count(), {
    use source <- fields.include(
      fields.string("source"),
      get: fn(r: Rescheduled) { r.source },
    )
    use wake <- fields.include(fields.int("wake"), get: fn(r) { r.wake })
    use point <- fields.include(fields.string("point"), get: fn(r) { r.point })
    use occurrence <- fields.include(fields.string("occurrence"), get: fn(r) {
      r.occurrence
    })
    use until_ms <- fields.include(fields.int("until_ms"), get: fn(r) {
      r.until_ms
    })
    fields.success(Rescheduled(source:, wake:, point:, occurrence:, until_ms:))
  })
}

/// `[decisions_postgres, settlement, delivered]`.
pub fn settlement_delivered() -> Event(Count, Settled) {
  sinal.event(["decisions_postgres", "settlement", "delivered"], count(), {
    use source <- fields.include(fields.string("source"), get: fn(s: Settled) {
      s.source
    })
    use notice <- fields.include(fields.int("notice"), get: fn(s) { s.notice })
    use point <- fields.include(fields.string("point"), get: fn(s) { s.point })
    use occurrence <- fields.include(fields.string("occurrence"), get: fn(s) {
      s.occurrence
    })
    fields.success(Settled(source:, notice:, point:, occurrence:))
  })
}

/// `[decisions_postgres, record, set_aside]`.
pub fn set_aside() -> Event(Count, SetAside) {
  sinal.event(["decisions_postgres", "record", "set_aside"], count(), {
    use source <- fields.include(fields.string("source"), get: fn(s: SetAside) {
      s.source
    })
    use kind <- fields.include(
      fields.enum("kind", [WakeUp, Notice, Occurrence], kind_name),
      get: fn(s) { s.kind },
    )
    use point <- fields.include(fields.string("point"), get: fn(s) { s.point })
    use occurrence <- fields.include(fields.string("occurrence"), get: fn(s) {
      s.occurrence
    })
    use reason <- fields.include(fields.string("reason"), get: fn(s) {
      s.reason
    })
    fields.success(SetAside(source:, kind:, point:, occurrence:, reason:))
  })
}

/// The kind's name in the event's metadata.
pub fn kind_name(kind: Kind) -> String {
  case kind {
    WakeUp -> "wake_up"
    Notice -> "notice"
    Occurrence -> "occurrence"
  }
}

fn count() -> fields.Fields(Count) {
  use count <- fields.include(fields.int("count"), get: fn(c: Count) { c.count })
  fields.success(Count(count:))
}
