//// Model calls that cannot hurt their caller. `model` runs a model in a
//// process of its own, held to a deadline it cannot ignore: a model that
//// raises becomes `model.Raised`, and one that has not answered in time is
//// killed and becomes `model.Deadline`. The caller is never taken down and
//// never waits longer than the deadline and the time to kill.
////
//// `recommend` is the whole step a worker takes for a trigger: run the
//// model isolated, outside any transaction, then either recommend under
//// the trigger's key, or record the failed attempt with
//// `decisions.record_failure` in a transaction of its own, so the record
//// shows that the trigger was tried and why it failed.
////
//// ```gleam
//// import decisions_otp/isolated
////
//// let guarded = isolated.model(classifier, within: duration.seconds(5))
//// let assert Ok(isolated.Recommended(occurrence)) =
////   isolated.recommend(desk, in: store.transaction(s, _), request:, model: guarded)
//// ```

import decisions.{type Desk, type Refusal}
import decisions/model.{type Failure, type Model, type Sources}
import decisions/occurrence.{type Attempt, type Occurrence}
import decisions/store.{type StoreError}
import decisions/vocabulary.{
  type Manifest, type Recommendation, type Subject, type Trigger,
}
import decisions_otp/telemetry
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import sinal

type Answer(output) {
  Ready(go: process.Subject(Bool))
  Answered(Result(Recommendation(output), Failure))
  Exited(process.ExitReason)
  TimedOut
}

/// The same model, run in a process of its own for each call, with
/// `within` to answer. The reads it received are on its recommendation,
/// exactly as `decisions/model.run` puts them there. A model's process
/// that raises is `Raised(reason)`; one that has not answered within
/// `within` is killed and is `Deadline(within)`.
///
/// The model's process dies with its caller: a watcher process kills it
/// when the caller exits, so a worker killed while its model hangs leaves
/// no model running. The model's process is not linked to the caller, so
/// its death never takes the caller down.
///
/// Each call copies `inner`, and every value its function captures, into
/// the new process; a copy does not keep sharing. Keep the model small:
/// build heavy values, such as the codec of a structured answer, inside
/// the model's function rather than capturing them.
pub fn model(inner: Model(output), within within: Duration) -> Model(output) {
  model.reporting(fn(context, sources) { call(inner, context, sources, within) })
}

fn call(
  inner: Model(output),
  context: Manifest,
  sources: Sources,
  within: Duration,
) -> Result(Recommendation(output), Failure) {
  let reply = process.new_subject()
  let caller = process.self()
  // The model's process waits for `go` before it runs, and gives up if its
  // caller dies first; the watcher is in place before `go`, so the model
  // can never outlive its caller.
  let pid =
    process.spawn_unlinked(fn() {
      let go = process.new_subject()
      process.send(reply, Starting(go))
      let on_caller = process.monitor(caller)
      let started =
        process.new_selector()
        |> process.select(go)
        |> process.select_specific_monitor(on_caller, fn(_) { False })
        |> process.selector_receive_forever
      case started {
        True -> {
          process.demonitor_process(on_caller)
          process.send(reply, Ran(model.run(inner, context, sources)))
        }
        False -> Nil
      }
    })
  let monitor = process.monitor(pid)
  let exited = fn(down) {
    case down {
      process.ProcessDown(reason:, ..) -> Exited(reason)
      process.PortDown(reason:, ..) -> Exited(reason)
    }
  }
  let selector =
    process.new_selector()
    |> process.select_map(reply, fn(message) {
      case message {
        Starting(go) -> Ready(go)
        Ran(outcome) -> Answered(outcome)
      }
    })
    |> process.select_specific_monitor(monitor, exited)
  let answer = case process.selector_receive(selector, 5000) {
    Ok(Ready(go)) -> {
      watch(caller:, model: pid)
      process.send(go, True)
      process.selector_receive(selector, duration.to_milliseconds(within))
      |> result.unwrap(TimedOut)
    }
    Ok(other) -> other
    Error(Nil) -> TimedOut
  }
  case answer {
    Answered(outcome) -> {
      process.demonitor_process(monitor)
      outcome
    }
    Ready(_) -> {
      process.demonitor_process(monitor)
      Error(model.Raised("the model's process started twice"))
    }
    // The answer may have arrived just before the exit was seen.
    Exited(reason) ->
      case process.receive(reply, 0) {
        Ok(Ran(outcome)) -> outcome
        _ ->
          Error(model.Raised(
            "the model's process exited: " <> string.inspect(reason),
          ))
      }
    TimedOut -> {
      process.kill(pid)
      // Wait for it to be gone, then drop an answer that landed as the
      // deadline fired, so none stays in the caller's mailbox.
      let _ =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_) { Nil })
        |> process.selector_receive(5000)
      let _ = process.receive(reply, 0)
      Error(model.Deadline(within))
    }
  }
}

/// Kill `model` when `caller` exits; end when `model` does.
fn watch(caller caller: process.Pid, model model: process.Pid) -> Nil {
  process.spawn_unlinked(fn() {
    let on_caller = process.monitor(caller)
    let on_model = process.monitor(model)
    let caller_died =
      process.new_selector()
      |> process.select_specific_monitor(on_caller, fn(_) { True })
      |> process.select_specific_monitor(on_model, fn(_) { False })
      |> process.selector_receive_forever
    case caller_died {
      True -> process.kill(model)
      False -> process.demonitor_process(on_caller)
    }
  })
  Nil
}

type Message(output) {
  Starting(go: process.Subject(Bool))
  Ran(Result(Recommendation(output), Failure))
}

/// Everything `recommend` needs to know about one trigger.
pub type Request {
  Request(
    /// Who sends the request, as the `[decisions, model, failed]` event
    /// says (`source`), such as the runtime's `Config.name`.
    source: String,
    /// The occurrence's id, at most one per key.
    key: String,
    trigger: Trigger,
    about: Subject,
    context: Manifest,
    sources: Sources,
  )
}

/// What `recommend` did. It may gain variants in a minor release; keep a
/// `_` branch where a new one needs no decision of yours.
pub type Attempted(output) {
  /// The model answered and the occurrence is on the record, now or from
  /// an earlier delivery of the same key.
  Recommended(occurrence: Occurrence(output))
  /// The model failed; the attempt is on the record with every earlier
  /// one. Decide on another try with `decisions/model.retryable`.
  Failed(failure: Failure, attempts: List(Attempt))
  /// `recommend_when`'s precondition said to skip, inside the
  /// recommending transaction: nothing was recommended or recorded. Skip
  /// it for good.
  Skipped(reason: String)
  /// A newer event superseded the key before anything was recommended
  /// (it was expected with `decisions.expect`): the recommendation, or
  /// the failed attempt, was refused with `SupersededBefore` and nothing
  /// was written. The trigger is done.
  Superseded(event: String)
  /// The key's own deadline (`decisions.expect_until`) passed before
  /// anything was recommended, and the model failed: the failed attempt
  /// was refused with `DeadlinePassedBefore` and nothing was written. The
  /// trigger is done. A model that answers after the deadline is not
  /// this: its recommendation is recorded and returned as `Recommended`,
  /// with the occurrence already expired.
  Lapsed(deadline: Timestamp)
}

/// Why `recommend_when`'s precondition does not let the recommendation
/// go ahead.
pub type Unmet {
  /// The precondition was checked and says to skip this trigger for good,
  /// such as "a later trigger arrived". `recommend_when` returns
  /// `Ok(Skipped(reason))`.
  Skip(reason: String)
  /// The precondition could not be checked, because the store failed.
  /// `recommend_when` returns `Error(StoreFailed(error))`, so the attempt
  /// is retried as the error's disposition says (a contended store is
  /// delivered again soon, without counting), and never taken for a skip.
  CouldNotCheck(error: StoreError)
}

/// Run `model` outside any transaction, then in a transaction of
/// `transaction`: recommend under `request.key` with
/// `decisions.recommend_once`, or record the failure with
/// `decisions.record_failure`. A `Deadline` or a `Raised` failure is
/// reported as `[decisions, model, failed]`. The caller isolates the model
/// with `model` first; `recommend` runs whatever it is given.
///
/// After the key's own deadline (`decisions.expect_until`), a failed
/// model is `Lapsed(deadline)` and nothing is written, and a model that
/// answered is `Recommended` with an occurrence that is already expired.
///
/// `transaction` runs its body in one transaction and commits on `Ok`,
/// such as `store.transaction(s, _)`. Safe to repeat: a key already
/// recommended is found, not recommended again.
pub fn recommend(
  desk: Desk(o, tx),
  in transaction: fn(fn(tx) -> Result(Attempted(o), Refusal)) ->
    Result(Attempted(o), Refusal),
  request request: Request,
  model chosen: Model(o),
) -> Result(Attempted(o), Refusal) {
  recommend_when(desk, in: transaction, request:, model: chosen, holds: fn(_) {
    Ok(Nil)
  })
}

/// `recommend`, with a precondition checked **inside the recommending
/// transaction**, after the model answered and before anything is
/// written. `holds` returns `Ok(Nil)` to go ahead, `Error(Skip(reason))`
/// to skip the trigger for good (the result is `Ok(Skipped(reason))`), or
/// `Error(CouldNotCheck(error))` when the store failed while it checked
/// (the result is `Error(StoreFailed(error))`, retried as that error's
/// disposition says). A failed model is recorded as by `recommend`,
/// without the check.
///
/// **To close the superseding window, use `decisions.expect`, not this.**
/// Call `happened` and then `expect` for the key in the transaction that
/// receives the trigger: a newer event then supersedes the key before it is
/// recommended, and the late recommendation comes back as
/// `Ok(Superseded(event))`. `recommend_when` remains the right tool for a
/// precondition that is not "a newer trigger arrived", such as "the
/// customer still has an open account" or "the feature is still switched
/// on". Such a check closes a race only when it **locks what it reads**
/// and whoever changes it takes the same lock, for example with
/// `decisions_otp/store.lock`:
///
/// ```gleam
/// holds: fn(tx) {
///   use Nil <- result.try(
///     store.lock(tx, "account:" <> id) |> result.map_error(isolated.CouldNotCheck),
///   )
///   case store.get(tx, "accounts", id) {
///     Ok("open") -> Ok(Nil)
///     _ -> Error(isolated.Skip("the account is closed"))
///   }
/// }
/// ```
pub fn recommend_when(
  desk: Desk(o, tx),
  in transaction: fn(fn(tx) -> Result(Attempted(o), Refusal)) ->
    Result(Attempted(o), Refusal),
  request request: Request,
  model chosen: Model(o),
  holds holds: fn(tx) -> Result(Nil, Unmet),
) -> Result(Attempted(o), Refusal) {
  let started = monotonic_us()
  case model.run(chosen, request.context, request.sources) {
    Ok(recommendation) ->
      transaction(fn(tx) {
        use <- check(holds(tx))
        decisions.recommend_once(
          desk,
          tx,
          key: request.key,
          proposal: decisions.proposal(
            trigger: request.trigger,
            about: request.about,
            context: request.context,
            recommending: recommendation,
          ),
        )
        |> result.map(Recommended)
        |> superseded
      })
    Error(failure) -> {
      report(desk, request, failure, started)
      transaction(fn(tx) {
        decisions.record_failure(
          desk,
          tx,
          key: request.key,
          trigger: request.trigger,
          about: request.about,
          failure:,
        )
        |> result.map(Failed(failure, _))
        |> superseded
      })
    }
  }
}

fn check(
  held: Result(Nil, Unmet),
  then: fn() -> Result(Attempted(o), Refusal),
) -> Result(Attempted(o), Refusal) {
  case held {
    Ok(Nil) -> then()
    Error(Skip(reason:)) -> Ok(Skipped(reason))
    Error(CouldNotCheck(error:)) -> Error(decisions.StoreFailed(error))
  }
}

/// A key superseded, or lapsed by its own deadline, before it was
/// recommended wrote nothing and is done:
/// say so in the result rather than as a refusal.
fn superseded(
  attempted: Result(Attempted(o), Refusal),
) -> Result(Attempted(o), Refusal) {
  case attempted {
    Error(decisions.SupersededBefore(event:)) -> Ok(Superseded(event))
    Error(decisions.DeadlinePassedBefore(deadline:)) -> Ok(Lapsed(deadline))
    other -> other
  }
}

fn report(
  desk: Desk(o, tx),
  request: Request,
  failure: Failure,
  started: Int,
) -> Nil {
  let key = request.key
  let kind: Option(telemetry.ModelFailure) = case
    model.without_evidence(failure)
  {
    model.Deadline(_) -> Some(telemetry.ModelDeadline)
    model.Raised(_) -> Some(telemetry.ModelRaised)
    _ -> None
  }
  case kind {
    None -> Nil
    Some(kind) -> {
      let point = decisions.name(decisions.point_of(desk))
      let about = telemetry.about(request.source, point, key)
      sinal.emit(
        telemetry.model_failed(),
        telemetry.Took(monotonic_us() - started),
        telemetry.ModelMetadata(
          source: request.source,
          point:,
          occurrence: key,
          correlation: about.correlation,
          failure: kind,
          reason: model.describe(failure),
        ),
      )
    }
  }
}

@external(erlang, "decisions_otp_ffi", "monotonic_us")
fn monotonic_us() -> Int
