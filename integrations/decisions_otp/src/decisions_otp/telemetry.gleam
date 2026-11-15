//// The Sinal events this package emits: a settlement delivered, a wake-up
//// delivered or rescheduled, a job that failed or was set aside, a
//// trigger worked, and a model that missed its deadline or raised.
////
//// `[decisions, job, dropped]` reports a job removed as done because a
//// new delivery could not change its outcome.
////
//// Each function returns a typed `sinal.Event`; attach a handler to it
//// with `sinal.observe` or `sinal.attach`. This module owns the events,
//// not handler registration.
////
//// Every metadata record carries `source`, which names the runtime (its
//// `Config.name`) or the isolated model's request (`Request.source`) that
//// emitted it, so two applications on one node can tell their events
//// apart; `point` and `occurrence` (for a trigger,
//// `point` is empty and `occurrence` is the trigger's key, which becomes
//// the occurrence's id), and `correlation`, which is
//// `correlation.from_key(occurrence)`: every event about one occurrence
//// shares it. Durations are in microseconds.
////
//// Events are emitted by the runtime's processes and by
//// `decisions_otp/isolated`, after the transaction they describe has
//// committed or rolled back. No verb of `decisions` emits anything, so a
//// handler never runs inside a transaction or holds a lock. A handler
//// runs synchronously in the emitting process unless the application
//// routes the `decisions` prefix to a `sinal/forwarder`: a slow handler
//// slows the sweeper, the dispatcher or a worker, never a verb.
//// Observations never control delivery.
////
//// ```gleam
//// import decisions_otp/telemetry
//// import sinal
////
//// let attachment =
////   sinal.observe(telemetry.job_set_aside(), fn(_measurements, metadata) {
////     alert(metadata.point, metadata.occurrence, metadata.reason)
////   })
//// ```

import gleam/option.{type Option}
import sinal.{type Event}
import sinal/correlation.{type Correlation}
import sinal/fields

/// How long the work took, in microseconds.
pub type Took {
  Took(duration: Int)
}

/// Who an event is about.
pub type About {
  About(
    source: String,
    point: String,
    occurrence: String,
    correlation: Correlation,
  )
}

/// Who an event is about, for `about`.
pub fn about(source: String, point: String, occurrence: String) -> About {
  About(
    source:,
    point:,
    occurrence:,
    correlation: correlation.from_key(occurrence),
  )
}

/// What a delivered wake-up did.
pub type WakeOutcome {
  /// The occurrence moved, or nothing was due any more.
  WakeActed
  /// It arrived early and is due again later.
  WakeRescheduled
}

/// `[decisions, wake, delivered]` metadata. `again` is when a rescheduled
/// wake-up is due, in milliseconds since the Unix epoch.
pub type WakeDelivered {
  WakeDelivered(
    /// Who emitted it: the runtime's or the request's `source`.
    source: String,
    point: String,
    occurrence: String,
    correlation: Correlation,
    outcome: WakeOutcome,
    again: Option(Int),
  )
}

/// The queue a job belongs to.
pub type Queue {
  /// Wake-ups.
  WakeQueue
  /// Settlement notices.
  NoticeQueue
  /// Triggers.
  TriggerQueue
}

/// `[decisions, job, failed]` and `[decisions, job, set_aside]` metadata.
pub type JobMetadata {
  JobMetadata(
    /// Who emitted it: the runtime's or the request's `source`.
    source: String,
    point: String,
    occurrence: String,
    correlation: Correlation,
    queue: Queue,
    reason: String,
    attempts: Int,
  )
}

/// Why a model has no answer, for `[decisions, model, failed]`.
pub type ModelFailure {
  /// `decisions/model.Deadline`: killed at its deadline.
  ModelDeadline
  /// `decisions/model.Raised`: the model raised.
  ModelRaised
}

/// `[decisions, model, failed]` metadata.
pub type ModelMetadata {
  ModelMetadata(
    /// Who emitted it: the runtime's or the request's `source`.
    source: String,
    point: String,
    occurrence: String,
    correlation: Correlation,
    failure: ModelFailure,
    reason: String,
  )
}

fn took() -> fields.Fields(Took) {
  use duration <- fields.include(fields.int("duration"), get: fn(m: Took) {
    m.duration
  })
  fields.success(Took(duration:))
}

fn about_fields() -> fields.Fields(About) {
  use source <- fields.include(fields.string("source"), get: fn(m: About) {
    m.source
  })
  use point <- fields.include(fields.string("point"), get: fn(m: About) {
    m.point
  })
  use occurrence <- fields.include(
    fields.string("occurrence"),
    get: fn(m: About) { m.occurrence },
  )
  use correlation <- fields.include(
    correlation.required_field(),
    get: fn(m: About) { m.correlation },
  )
  fields.success(About(source:, point:, occurrence:, correlation:))
}

/// `[decisions, settlement, delivered]`: what follows a settlement ran and
/// the notice was marked delivered, in one committed transaction.
pub fn settlement_delivered() -> Event(Took, About) {
  sinal.event(["decisions", "settlement", "delivered"], took(), about_fields())
}

/// `[decisions, trigger, worked]`: a worker's `work` succeeded and the
/// worker removed the trigger. It counts **triggers**, once each: a
/// delivery that finds the trigger already removed by another emits
/// nothing.
pub fn trigger_worked() -> Event(Took, About) {
  sinal.event(["decisions", "trigger", "worked"], took(), about_fields())
}

/// `[decisions, wake, delivered]`: a wake-up was delivered and committed;
/// `outcome` says whether it was rescheduled.
pub fn wake_delivered() -> Event(Took, WakeDelivered) {
  let metadata = {
    use source <- fields.include(
      fields.string("source"),
      get: fn(m: WakeDelivered) { m.source },
    )
    use point <- fields.include(
      fields.string("point"),
      get: fn(m: WakeDelivered) { m.point },
    )
    use occurrence <- fields.include(
      fields.string("occurrence"),
      get: fn(m: WakeDelivered) { m.occurrence },
    )
    use correlation <- fields.include(
      correlation.required_field(),
      get: fn(m: WakeDelivered) { m.correlation },
    )
    use outcome <- fields.include(
      fields.enum("outcome", [WakeActed, WakeRescheduled], wake_outcome_name),
      get: fn(m: WakeDelivered) { m.outcome },
    )
    use again <- fields.include(
      fields.optional(fields.int("again")),
      get: fn(m: WakeDelivered) { m.again },
    )
    fields.success(WakeDelivered(
      source:,
      point:,
      occurrence:,
      correlation:,
      outcome:,
      again:,
    ))
  }
  sinal.event(["decisions", "wake", "delivered"], took(), metadata)
}

/// The stable name of a wake-up outcome: `"acted"` or `"rescheduled"`.
pub fn wake_outcome_name(outcome: WakeOutcome) -> String {
  case outcome {
    WakeActed -> "acted"
    WakeRescheduled -> "rescheduled"
  }
}

/// The stable name of a queue: `"wake"`, `"notice"` or `"trigger"`.
pub fn queue_name(queue: Queue) -> String {
  case queue {
    WakeQueue -> "wake"
    NoticeQueue -> "notice"
    TriggerQueue -> "trigger"
  }
}

/// The stable name of a model failure: `"deadline"` or `"raised"`.
pub fn model_failure_name(failure: ModelFailure) -> String {
  case failure {
    ModelDeadline -> "deadline"
    ModelRaised -> "raised"
  }
}

fn job_fields() -> fields.Fields(JobMetadata) {
  use source <- fields.include(fields.string("source"), get: fn(m: JobMetadata) {
    m.source
  })
  use point <- fields.include(fields.string("point"), get: fn(m: JobMetadata) {
    m.point
  })
  use occurrence <- fields.include(
    fields.string("occurrence"),
    get: fn(m: JobMetadata) { m.occurrence },
  )
  use correlation <- fields.include(
    correlation.required_field(),
    get: fn(m: JobMetadata) { m.correlation },
  )
  use queue <- fields.include(
    fields.enum("queue", [WakeQueue, NoticeQueue, TriggerQueue], queue_name),
    get: fn(m: JobMetadata) { m.queue },
  )
  use reason <- fields.include(fields.string("reason"), get: fn(m: JobMetadata) {
    m.reason
  })
  use attempts <- fields.include(
    fields.int("attempts"),
    get: fn(m: JobMetadata) { m.attempts },
  )
  fields.success(JobMetadata(
    source:,
    point:,
    occurrence:,
    correlation:,
    queue:,
    reason:,
    attempts:,
  ))
}

/// `[decisions, job, failed]`: one attempt at a job failed and was rolled
/// back; it will be tried again. `attempts` counts the failures that set
/// a job aside; a transient failure, which does not count, carries 0.
pub fn job_failed() -> Event(Took, JobMetadata) {
  sinal.event(["decisions", "job", "failed"], took(), job_fields())
}

/// `[decisions, job, dropped]`: a delivery was refused for a reason a
/// new delivery cannot change (`decisions.disposition` is `Final`), such
/// as an occurrence that has moved on, and the job was removed as done.
pub fn job_dropped() -> Event(Took, JobMetadata) {
  sinal.event(["decisions", "job", "dropped"], took(), job_fields())
}

/// `[decisions, job, set_aside]`: a job failed as often as the runtime
/// allows, or cannot be delivered at all, and was set aside. It no longer
/// blocks anything; an operator reads it from the backlog's `aside`.
pub fn job_set_aside() -> Event(Took, JobMetadata) {
  sinal.event(["decisions", "job", "set_aside"], took(), job_fields())
}

/// `[decisions, model, failed]`: a model run by `decisions_otp/isolated`
/// missed its deadline or raised. The failed attempt is on the record.
pub fn model_failed() -> Event(Took, ModelMetadata) {
  let metadata = {
    use source <- fields.include(
      fields.string("source"),
      get: fn(m: ModelMetadata) { m.source },
    )
    use point <- fields.include(
      fields.string("point"),
      get: fn(m: ModelMetadata) { m.point },
    )
    use occurrence <- fields.include(
      fields.string("occurrence"),
      get: fn(m: ModelMetadata) { m.occurrence },
    )
    use correlation <- fields.include(
      correlation.required_field(),
      get: fn(m: ModelMetadata) { m.correlation },
    )
    use failure <- fields.include(
      fields.enum("failure", [ModelDeadline, ModelRaised], model_failure_name),
      get: fn(m: ModelMetadata) { m.failure },
    )
    use reason <- fields.include(
      fields.string("reason"),
      get: fn(m: ModelMetadata) { m.reason },
    )
    fields.success(ModelMetadata(
      source:,
      point:,
      occurrence:,
      correlation:,
      failure:,
      reason:,
    ))
  }
  sinal.event(["decisions", "model", "failed"], took(), metadata)
}
