//// The supervised runtime: the processes that deliver what the record
//// says is owed. Add it to the application's supervision tree with
//// `supervised`.
////
//// | Process | Owns | Keeps in memory | Killed: what is lost | Restarted by |
//// | --- | --- | --- | --- | --- |
//// | sweeper | delivering due wake-ups, and delivering again at `until` a wake-up that arrived early | the batch of due wake-ups in hand | nothing: a wake-up leaves the backlog only in the transaction that acts on it, which the kill rolls back | the runtime's supervisor |
//// | dispatcher | delivering each settlement to what follows it | the batch of notices in hand | nothing: a notice is marked delivered in the transaction that runs what follows | the runtime's supervisor |
//// | worker (`workers` of them) | turning one trigger at a time into a recommendation | the trigger in hand | nothing: the claim dies with the worker and another takes the trigger; `recommend_once` makes a second delivery harmless | the runtime's supervisor |
////
//// **Owning it.** `supervised(config)` is a child specification;
//// `supervised_from(configure)` configures the runtime at every start,
//// for a store started by the same tree (`store.supervised`). The restart
//// tolerance is `Config.intensity` and `Config.period`. A `Control` in
//// `Config.control` lets the application pause and resume the runtime
//// and find its supervisor and children by name (`pause`, `resume`,
//// `supervisor_of`, `children_of`); with a control, the tree's first
//// child is the switch that holds "paused".
////
//// **Restart strategy.** One-for-one. No child holds state another needs
//// and none holds a handle to another, so a death is no reason to restart
//// a sibling. The children start in the order sweeper, dispatcher,
//// workers; the order carries no dependency, because each reads only the
//// store. By default the supervisor allows 100 restarts in 5 seconds: a child killed
//// now and then is restarted at once, while a child that crashes on
//// every start (a store that has stopped) exhausts the allowance quickly
//// and takes the runtime down to the application's supervisor, which
//// decides.
////
//// **Bounds.** Each child's mailbox holds at most one message, the next
//// look, which the child sends itself. Each look reads at most `batch`
//// jobs. Workers number `workers`. Nothing else is queued in memory: the
//// backlog is the queue.
////
//// **Failure.** A delivery that does not commit is rolled back. What
//// happens to its job is decided by `decisions.handling` and by nothing
//// else, the same rule `decisions_postgres` follows. A handler returns a
//// `decisions.HandlerFailure`; a refusal of a verb the runtime calls
//// itself is handled as `DeskRefused(refusal)`, a handler that raises as
//// `ApplicationFailed`, and a backlog call or a commit that fails, or a
//// commit whose outcome is unknown, as `Redeliver`: nothing says the
//// handler failed, so it is not counted.
////
//// **Timing.** A `Redeliver` job (a wake-up, a notice, or a trigger, for
//// each worker) is delivered again two looks later (about two `poll`s); a
//// `Backoff` job after the store's backoff (`store.Config.retry_backoff`,
//// doubled after each failure, at most 64 times). `decisions_postgres`
//// classifies by the same `handling` with the same default of 20
//// attempts, and times its retries with Grind; see its README.
////
//// | `handling` | Example | What the runtime does |
//// | --- | --- | --- |
//// | `Redeliver` | `DeskRefused(StoreFailed(Contended(..)))` or `StoreFailed(Unavailable(..))`; a failed backlog call or commit, or a commit whose outcome is unknown | not counted; the child leaves it out of its next look and goes on with the jobs behind it, then delivers it again; reported by `[decisions, job, failed]` with `attempts` 0 |
//// | `Backoff` | `ApplicationFailed(reason)` or a handler that raises; `DeskRefused` of `StoreFailed(Conflict(..))`, `NoPolicy`, `ConsultFailed` (such as a policy step that consults a point the desk has no handler for) or `ToolUnsure` | **counted**; the job, a wake-up as much as a notice or a trigger, waits out the store's backoff (`Backlog.failed`) and is delivered again; after `attempts` failures (default 20) it is set aside |
//// | `SetAside` | `DeskRefused` of `Unreadable`, `Unpublishable`, `InvalidFacts`, `Unencodable` or `KeyTaken` | sets the job aside at once |
//// | `Drop` | `DeskRefused(UnknownOccurrence)`, `NotAwaiting` and every other refusal | removes the job as done; reported by `[decisions, job, dropped]` |
////
//// A job set aside leaves its queue and stays readable
//// (`decisions_otp/backlog.Backlog.aside`); `[decisions, job, set_aside]`
//// reports it, and the jobs behind it go on. A job for a point the runtime
//// was not given is set aside at once. A look that only met transient
//// failures waits `poll` before the next.
////
//// **Delivery is at least once.** A kill between the commit and the next
//// look can deliver a job again: a settlement handler must be safe to run
//// twice unless it writes only in the transaction it is handed, where the
//// notice is marked delivered in the same commit.
////
//// ```gleam
//// import decisions_otp/runtime
//// import decisions_otp/store
////
//// let config =
////   runtime.config(
////     store.backlog(s),
////     points: [
////       runtime.point(refunds, settled: tell_the_customer),
////       runtime.point(replies, settled: runtime.nothing_follows),
////     ],
////     work: classify_message,
////   )
//// static_supervisor.new(static_supervisor.OneForOne)
//// |> static_supervisor.add(runtime.supervised(config))
//// ```

import decisions.{type Desk, type HandlerFailure, type Refusal}
import decisions/occurrence.{type Occurrence}
import decisions/store.{type Wake, Wake}
import decisions/wire
import decisions_otp/backlog.{
  type Backlog, type Handled, type Job, type Pending, type Submitted, Acted,
  Counted, Gone, NoticeJob, TriggerJob, WakeJob,
}
import decisions_otp/telemetry
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import sinal

/// A decision point the runtime serves: how to wake its occurrences and
/// what follows when one settles. Build it with `point`.
pub opaque type Wired(tx) {
  Wired(
    name: String,
    wake: fn(tx, String) -> Result(Option(Timestamp), Refusal),
    settled: fn(tx, String) -> Result(Nil, Fault),
  )
}

/// A point to serve. `settled` runs in the transaction that marks the
/// settlement delivered, with the occurrence as the record holds it; its
/// writes in that transaction commit with the delivery. Return `Error` to
/// roll the delivery back: `DeskRefused(refusal)` for a verb of a desk
/// that refused, `ApplicationFailed(reason)` for the application's own
/// work. See "Failure" above for what each does.
///
/// A record that settled before it began (expected with
/// `decisions.expect`, then superseded) has no occurrence to hand to
/// `settled`: its notice is dropped as done and reported by
/// `[decisions, job, dropped]`. The same goes for a trigger whose
/// `recommend_once` or `record_failure` meets `SupersededBefore`: return
/// `DeskRefused(refusal)` and the trigger is dropped with the refusal as
/// its reason.
pub fn point(
  desk: Desk(o, tx),
  settled settled: fn(tx, Occurrence(o)) -> Result(Nil, HandlerFailure),
) -> Wired(tx) {
  let #(name, wake) = decisions.waker(desk)
  Wired(name:, wake:, settled: fn(tx, id) {
    use known <- result.try(
      decisions.read(desk, tx, occurrence: id) |> result.map_error(refused),
    )
    settled(tx, known) |> result.map_error(from_handler)
  })
}

/// For a point where nothing follows a settlement.
pub fn nothing_follows(
  _tx: tx,
  _occurrence: Occurrence(o),
) -> Result(Nil, HandlerFailure) {
  Ok(Nil)
}

/// Everything the runtime needs. Build it with `config`, which requires
/// every handler, and change the rest by record update.
pub type Config(tx) {
  Config(
    backlog: Backlog(tx),
    /// Every point whose wake-ups and settlements the runtime delivers.
    points: List(Wired(tx)),
    /// How a trigger becomes a recommendation. It runs outside any
    /// transaction, because a model is slow, and ends by calling
    /// `decisions.recommend_once` with the trigger's key in a transaction
    /// of its own. It is delivered at least once.
    work: fn(Submitted) -> Result(Nil, HandlerFailure),
    /// How many triggers are worked at once.
    workers: Int,
    /// How long an idle process waits before it looks again.
    poll: Duration,
    /// How many jobs one look reads, at most.
    batch: Int,
    /// How many failed attempts set a job aside.
    attempts: Int,
    /// Who this runtime is, as its telemetry events say (`source`), so
    /// that two runtimes on one node can tell their events apart.
    name: String,
    /// The supervisor's restart tolerance: at most `intensity` restarts
    /// in `period` seconds before the runtime exits to its own
    /// supervisor.
    intensity: Int,
    period: Int,
    /// A control the application keeps, to pause and resume the runtime
    /// and find its children without knowing how they are numbered.
    control: Option(Control),
  )
}

/// A configuration with every handler, four workers, a poll of 100 ms, a
/// batch of 100, twenty attempts (as `decisions_postgres`), the name `"decisions_otp"`, a restart
/// tolerance of 100 in 5 seconds, and no control.
pub fn config(
  backlog: Backlog(tx),
  points points: List(Wired(tx)),
  work work: fn(Submitted) -> Result(Nil, HandlerFailure),
) -> Config(tx) {
  Config(
    backlog:,
    points:,
    work:,
    workers: 4,
    poll: duration.milliseconds(100),
    batch: 100,
    attempts: 20,
    name: "decisions_otp",
    intensity: 100,
    period: 5,
    control: None,
  )
}

/// A name by which an application reaches its runtime: pause it, resume
/// it, find its supervisor and children. Make one with `new_control` at
/// start-up, put it in `Config.control`, and keep it: each control is an
/// atom, and atoms are never collected.
pub opaque type Control {
  Control(name: process.Name(Switch))
}

/// A new control. Call it once per runtime, at start-up.
pub fn new_control(prefix: String) -> Control {
  Control(process.new_name(prefix))
}

/// What the runtime's switch is asked.
pub opaque type Switch {
  SetPaused(paused: Bool, reply: Subject(Nil))
  IsPaused(reply: Subject(Bool))
  Parent(reply: Subject(Pid))
}

/// Stop the runtime from delivering anything: each child finishes the job
/// in hand and then only waits. Its processes stay up. A paused runtime
/// whose switch restarts (its supervisor restarted it) runs again.
/// `Error(Nil)` when no runtime holds this control.
pub fn pause(control: Control) -> Result(Nil, Nil) {
  call(control, SetPaused(True, _))
}

/// Let a paused runtime deliver again.
pub fn resume(control: Control) -> Result(Nil, Nil) {
  call(control, SetPaused(False, _))
}

/// Whether the runtime is paused.
pub fn is_paused(control: Control) -> Result(Bool, Nil) {
  call(control, IsPaused)
}

/// The runtime's supervisor, for an application that stops it with its
/// own supervisor.
pub fn supervisor_of(control: Control) -> Result(Pid, Nil) {
  call(control, Parent)
}

/// The runtime's live children with their roles.
pub fn children_of(control: Control) -> Result(List(#(Role, Pid)), Nil) {
  supervisor_of(control) |> result.map(children)
}

fn call(control: Control, make: fn(Subject(a)) -> Switch) -> Result(a, Nil) {
  case process.named(control.name) {
    Error(Nil) -> Error(Nil)
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      process.send(process.named_subject(control.name), make(reply))
      let answer =
        process.new_selector()
        |> process.select_map(reply, Ok)
        |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
        |> process.selector_receive(5000)
      process.demonitor_process(monitor)
      case answer {
        Ok(Ok(value)) -> Ok(value)
        _ -> Error(Nil)
      }
    }
  }
}

fn switch(control: Control) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    actor.new(False)
    |> actor.named(control.name)
    |> actor.on_message(fn(paused, message) {
      case message {
        SetPaused(paused:, reply:) -> {
          process.send(reply, Nil)
          actor.continue(paused)
        }
        IsPaused(reply:) -> {
          process.send(reply, paused)
          actor.continue(paused)
        }
        Parent(reply:) -> {
          process.send(reply, parent())
          actor.continue(paused)
        }
      }
    })
    |> actor.start
    |> result.map(fn(started) { actor.Started(pid: started.pid, data: Nil) })
  })
}

/// Whether the runtime is paused, as its children see it at each look. A
/// switch that does not answer counts as running.
fn running(config: Config(tx)) -> Bool {
  case config.control {
    None -> True
    Some(control) ->
      case call(control, IsPaused) {
        Ok(True) -> False
        _ -> True
      }
  }
}

/// The runtime as a child of the application's supervisor.
pub fn supervised(
  config: Config(tx),
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  tree(config) |> supervisor.supervised
}

/// The runtime as a child of the application's supervisor, configured
/// when it starts, and again at every restart. Use it when the
/// configuration needs a handle that only exists once an earlier child
/// started, such as a store started with `store.supervised`:
/// `supervised_from(fn() { store.named(name) |> result.replace_error("no
/// store") |> result.map(build) })`. An `Error` fails the start.
pub fn supervised_from(
  configure: fn() -> Result(Config(tx), String),
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  supervision.supervisor(fn() {
    case configure() {
      Ok(config) -> tree(config) |> supervisor.start
      Error(reason) -> Error(actor.InitFailed(reason))
    }
  })
}

/// Start the runtime's supervisor, linked to the caller. Prefer
/// `supervised` in an application; this is for tests and scripts.
pub fn start(
  config: Config(tx),
) -> Result(actor.Started(supervisor.Supervisor), actor.StartError) {
  tree(config) |> supervisor.start
}

/// What a child of the runtime does.
pub type Role {
  /// Delivers due wake-ups.
  Sweeper
  /// Delivers settlement notices.
  Dispatcher
  /// Works triggers; `number` counts from 1.
  Worker(number: Int)
}

/// The live children of a runtime's supervisor, with their roles, for an
/// operator or a test that kills them.
pub fn children(supervisor: Pid) -> List(#(Role, Pid)) {
  which_children(supervisor)
  |> list.filter_map(fn(pair) {
    case pair.1 {
      Some(role) -> Ok(#(role, pair.0))
      None -> Error(Nil)
    }
  })
}

fn tree(config: Config(tx)) -> supervisor.Builder {
  let builder =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.restart_tolerance(
      intensity: config.intensity,
      period: config.period,
    )
  let builder = case config.control {
    Some(control) -> supervisor.add(builder, switch(control))
    None -> builder
  }
  let builder =
    builder
    |> supervisor.add(child(config, Sweeper, sweep))
    |> supervisor.add(child(config, Dispatcher, dispatch))
  list.fold(numbers(config.workers), builder, fn(builder, n) {
    supervisor.add(builder, child(config, Worker(n), work))
  })
}

fn numbers(count: Int) -> List(Int) {
  case count <= 0 {
    True -> []
    False -> list.append(numbers(count - 1), [count])
  }
}

type Look {
  Look
}

/// A process that looks, works, and looks again: at once when it found
/// something, after `poll` when it did not. Its mailbox holds at most the
/// one `Look` it sends itself.
fn child(
  config: Config(tx),
  role: Role,
  look: fn(Config(tx), Skips) -> #(Bool, Skips),
) -> supervision.ChildSpecification(Subject(Look)) {
  supervision.worker(fn() {
    actor.new_with_initialiser(1000, fn(self) {
      set_role(role)
      process.send(self, Look)
      Ok(actor.initialised(#(self, dict.new())) |> actor.returning(self))
    })
    |> actor.on_message(fn(state, _look) {
      let #(self, skips) = state
      let #(found, skips) = case running(config) {
        True -> look(config, skips)
        False -> #(False, skips)
      }
      case found {
        True -> process.send(self, Look)
        False -> {
          let _ =
            process.send_after(
              self,
              duration.to_milliseconds(config.poll),
              Look,
            )
          Nil
        }
      }
      actor.continue(#(self, skips))
    })
    |> actor.start
  })
}

/// Jobs a child leaves alone until a monotonic time in milliseconds,
/// because their last delivery could not move them (`Redeliver`): the
/// jobs behind them go on. It holds at most the jobs of a few looks, and
/// a child that restarts forgets it, which only means one early retry.
type Skips =
  Dict(String, Int)

/// Deliver a batch of jobs read past the ones skipped, and skip for one
/// `poll` each that did not move.
fn deliver_batch(
  config: Config(tx),
  skips: Skips,
  read: fn(Int) -> Result(List(job), a),
  key: fn(job) -> String,
  deliver: fn(job) -> Bool,
) -> #(Bool, Skips) {
  let now = monotonic_us() / 1000
  let skips = dict.filter(skips, fn(_, until) { until > now })
  case read(config.batch + dict.size(skips)) {
    Error(_) -> #(False, skips)
    Ok(jobs) -> {
      let jobs =
        jobs
        |> list.filter(fn(job) { !dict.has_key(skips, key(job)) })
        |> list.take(config.batch)
      // Past the next look, which comes after `poll`: the next look reads
      // past the skipped jobs, the one after tries them again.
      let until = now + 2 * duration.to_milliseconds(config.poll) + 1
      list.fold(jobs, #(False, skips), fn(acc, job) {
        case deliver(job) {
          True -> #(True, acc.1)
          False -> #(acc.0, dict.insert(acc.1, key(job), until))
        }
      })
    }
  }
}

// -- Why a delivery did not commit -----------------------------------------------------

/// Why one delivery rolled back, and what that means for the job.
/// Why a delivery rolled back, as what to do with its job and the reason
/// to report. The action is `decisions.handling`'s, and nothing else's.
type Fault {
  Fault(handling: decisions.Handling, reason: String)
}

/// The one rule both runtimes follow: `decisions.handling` decides; this
/// only adds the text for the report.
/// A handler that raised failed as the application's own work does.
fn raised(crash: Crash) -> Fault {
  from_handler(decisions.ApplicationFailed("raised: " <> string.inspect(crash)))
}

fn from_handler(failure: HandlerFailure) -> Fault {
  Fault(handling: decisions.handling(failure), reason: explain(failure))
}

fn explain(failure: HandlerFailure) -> String {
  case failure {
    decisions.DeskRefused(refusal:) -> decisions.describe(refusal)
    decisions.ApplicationFailed(reason:) -> reason
  }
}

/// A refusal of a desk verb the runtime itself called.
fn refused(refusal: Refusal) -> Fault {
  from_handler(decisions.DeskRefused(refusal))
}

fn store_fault(error: store.StoreError) -> Fault {
  Fault(decisions.Redeliver, store.describe(error))
}

/// Run `body` in one transaction of the backlog, keeping the fault that
/// rolled it back. An exception is a failing handler; a commit that fails
/// without a fault of the body's is transient.
fn run(
  config: Config(tx),
  body: fn(tx) -> Result(Handled, Fault),
) -> Result(Handled, Fault) {
  let faults = process.new_subject()
  let outcome =
    attempt(fn() {
      config.backlog.transaction(fn(tx) {
        // A handler that raises is caught here, inside the transaction,
        // so that it is told apart from the store failing to commit.
        let handled = case attempt(fn() { body(tx) }) {
          Ok(handled) -> handled
          Error(crash) -> Error(raised(crash))
        }
        case handled {
          Ok(handled) -> Ok(handled)
          Error(fault) -> {
            process.send(faults, fault)
            Error(fault.reason)
          }
        }
      })
    })
  case outcome {
    Ok(Ok(handled)) -> Ok(handled)
    Ok(Error(reason)) ->
      case process.receive(faults, 0) {
        Ok(fault) -> Error(fault)
        Error(Nil) -> Error(Fault(decisions.Redeliver, reason))
      }
    // The transaction itself raised after the body: the store stopped, or
    // its commit's outcome is unknown. Nothing says the handler failed, so
    // the job is delivered again without counting.
    Error(crash) ->
      Error(Fault(
        decisions.Redeliver,
        "the commit's outcome is unknown: " <> string.inspect(crash),
      ))
  }
}

// -- The sweeper ---------------------------------------------------------------------

fn sweep(config: Config(tx), skips: Skips) -> #(Bool, Skips) {
  let backlog = config.backlog
  deliver_batch(
    config,
    skips,
    fn(limit) { backlog.due(backlog.now(), limit) },
    fn(wake: Wake) {
      wake.point
      <> "\u{0}"
      <> wake.occurrence
      <> "\u{0}"
      <> int.to_string(wire.milliseconds(wake.at))
    },
    deliver_wake(config, _),
  )
}

/// Deliver one wake-up; `True` when the backlog moved.
fn deliver_wake(config: Config(tx), wake: Wake) -> Bool {
  let backlog = config.backlog
  let started = monotonic_us()
  case find(config, wake.point) {
    Error(Nil) ->
      set_aside_now(
        config,
        WakeJob(wake),
        "no point named " <> wake.point <> " is wired",
      )
    Ok(wired) -> {
      let delivered =
        run(config, fn(tx) {
          use taken <- result.try(
            backlog.take_wake(tx, wake) |> result.map_error(store_fault),
          )
          case taken {
            False -> Ok(Gone)
            True ->
              case wired.wake(tx, wake.occurrence) {
                Ok(None) -> Ok(Acted(None))
                Ok(Some(until)) ->
                  backlog.add_wake(tx, Wake(..wake, at: until))
                  |> result.map_error(store_fault)
                  |> result.replace(Acted(Some(until)))
                Error(refusal) -> Error(refused(refusal))
              }
          }
        })
      case delivered {
        Ok(Acted(again)) -> {
          sinal.emit(
            telemetry.wake_delivered(),
            telemetry.Took(monotonic_us() - started),
            telemetry.WakeDelivered(
              source: config.name,
              point: wake.point,
              occurrence: wake.occurrence,
              correlation: telemetry.about(
                config.name,
                wake.point,
                wake.occurrence,
              ).correlation,
              outcome: case again {
                Some(_) -> telemetry.WakeRescheduled
                None -> telemetry.WakeActed
              },
              again: option.map(again, wire.milliseconds),
            ),
          )
          True
        }
        Ok(_) -> True
        Error(fault) -> fail(config, WakeJob(wake), fault, started)
      }
    }
  }
}

// -- The dispatcher --------------------------------------------------------------------

fn dispatch(config: Config(tx), skips: Skips) -> #(Bool, Skips) {
  deliver_batch(
    config,
    skips,
    config.backlog.undelivered,
    fn(pending: Pending) { int.to_string(pending.id) },
    deliver_notice(config, _),
  )
}

fn deliver_notice(config: Config(tx), pending: Pending) -> Bool {
  let backlog = config.backlog
  let notice = pending.notice
  let started = monotonic_us()
  case find(config, notice.point) {
    Error(Nil) ->
      set_aside_now(
        config,
        NoticeJob(pending),
        "no point named " <> notice.point <> " is wired",
      )
    Ok(wired) -> {
      let delivered =
        run(config, fn(tx) {
          use taken <- result.try(
            backlog.deliver_notice(tx, pending) |> result.map_error(store_fault),
          )
          case taken {
            False -> Ok(Gone)
            True ->
              wired.settled(tx, notice.occurrence)
              |> result.replace(Acted(None))
          }
        })
      case delivered {
        Ok(Acted(_)) -> {
          sinal.emit(
            telemetry.settlement_delivered(),
            telemetry.Took(monotonic_us() - started),
            telemetry.about(config.name, notice.point, notice.occurrence),
          )
          True
        }
        Ok(_) -> True
        Error(fault) -> fail(config, NoticeJob(pending), fault, started)
      }
    }
  }
}

// -- A worker ----------------------------------------------------------------------------

/// One look of a worker. A trigger it could not move last time
/// (`Redeliver`) is left out for two looks, like the sweeper's and the
/// dispatcher's jobs: the worker claims it, keeps the claim so that no
/// claim hands it back, and goes on to the next trigger; it releases the
/// claims it held when the look ends. A lone worker so makes progress on
/// the other triggers, and the stuck one is delivered again two looks
/// later, never in a loop.
fn work(config: Config(tx), skips: Skips) -> #(Bool, Skips) {
  let now = monotonic_us() / 1000
  let skips = dict.filter(skips, fn(_, until) { until > now })
  let #(found, held) = claim_unskipped(config, skips, dict.size(skips), [])
  let outcome = case found {
    None -> #(False, skips)
    Some(submitted) ->
      case work_one(config, submitted) {
        True -> #(True, skips)
        False -> #(
          False,
          dict.insert(
            skips,
            int.to_string(submitted.id),
            now + 2 * duration.to_milliseconds(config.poll) + 1,
          ),
        )
      }
  }
  list.each(held, config.backlog.release)
  outcome
}

/// Claim the oldest trigger not in `skips`. Skipped ones met on the way
/// stay claimed by this worker (at most `left` of them) and are returned
/// to be released after the look.
fn claim_unskipped(
  config: Config(tx),
  skips: Skips,
  left: Int,
  held: List(Submitted),
) -> #(Option(Submitted), List(Submitted)) {
  case config.backlog.claim_trigger() {
    Error(_) | Ok(None) -> #(None, held)
    Ok(Some(submitted)) ->
      case dict.has_key(skips, int.to_string(submitted.id)), left > 0 {
        False, _ -> #(Some(submitted), held)
        True, True ->
          claim_unskipped(config, skips, left - 1, [submitted, ..held])
        True, False -> #(None, [submitted, ..held])
      }
  }
}

/// Work one claimed trigger; `True` when the backlog moved.
fn work_one(config: Config(tx), submitted: Submitted) -> Bool {
  let backlog = config.backlog
  let started = monotonic_us()
  let worked = case attempt(fn() { config.work(submitted) }) {
    Ok(Ok(Nil)) -> Ok(Nil)
    Ok(Error(failure)) -> Error(from_handler(failure))
    Error(crash) -> Error(raised(crash))
  }
  let progressed = case worked {
    Ok(Nil) -> {
      let finished =
        run(config, fn(tx) {
          backlog.finish_trigger(tx, submitted)
          |> result.map_error(store_fault)
          |> result.map(fn(found) {
            case found {
              True -> Acted(None)
              False -> Gone
            }
          })
        })
      case finished {
        Ok(Gone) -> True
        Ok(_) -> {
          sinal.emit(
            telemetry.trigger_worked(),
            telemetry.Took(monotonic_us() - started),
            telemetry.about(config.name, "", submitted.key),
          )
          True
        }
        Error(fault) -> fail(config, TriggerJob(submitted), fault, started)
      }
    }
    Error(fault) -> fail(config, TriggerJob(submitted), fault, started)
  }
  // The trigger's fate is committed; only now may another worker claim
  // it again.
  backlog.release(submitted)
  progressed
}

// -- Failure ------------------------------------------------------------------------------

/// Act on a fault; `True` when the backlog moved.
fn fail(config: Config(tx), job: Job, fault: Fault, started: Int) -> Bool {
  case fault {
    Fault(handling: decisions.Redeliver, reason:) -> {
      report(config, job, reason, 0, started, telemetry.job_failed())
      False
    }
    Fault(handling: decisions.SetAside, reason:) ->
      set_aside_now(config, job, reason)
    Fault(handling: decisions.Drop, reason:) ->
      drop(config, job, reason, started)
    Fault(handling: decisions.Backoff, reason:) ->
      count(config, job, reason, started)
  }
}

/// Count a failed attempt; set the job aside once it has failed
/// `attempts` times.
fn count(config: Config(tx), job: Job, reason: String, started: Int) -> Bool {
  let backlog = config.backlog
  let counted =
    run(config, fn(tx) {
      use attempts <- result.try(
        backlog.failed(tx, job, reason) |> result.map_error(store_fault),
      )
      case attempts >= config.attempts {
        True ->
          backlog.set_aside(tx, job, reason)
          |> result.map_error(store_fault)
          |> result.replace(Counted(attempts))
        False -> Ok(Counted(attempts))
      }
    })
  case counted {
    // Another delivery already took the job.
    Ok(Counted(0)) -> True
    Ok(Counted(attempts)) -> {
      report(
        config,
        job,
        reason,
        attempts,
        started,
        case attempts >= config.attempts {
          True -> telemetry.job_set_aside()
          False -> telemetry.job_failed()
        },
      )
      True
    }
    _ -> False
  }
}

/// Remove a job a new delivery cannot change, as delivered.
fn drop(config: Config(tx), job: Job, reason: String, started: Int) -> Bool {
  let backlog = config.backlog
  let dropped =
    run(config, fn(tx) {
      case job {
        WakeJob(wake:) -> backlog.take_wake(tx, wake)
        NoticeJob(pending:) -> backlog.deliver_notice(tx, pending)
        TriggerJob(submitted:) -> backlog.finish_trigger(tx, submitted)
      }
      |> result.map_error(store_fault)
      |> result.replace(Acted(None))
    })
  case dropped {
    Ok(_) -> {
      report(config, job, reason, 0, started, telemetry.job_dropped())
      True
    }
    Error(_) -> False
  }
}

fn set_aside_now(config: Config(tx), job: Job, reason: String) -> Bool {
  let backlog = config.backlog
  let started = monotonic_us()
  let done =
    run(config, fn(tx) {
      backlog.set_aside(tx, job, reason)
      |> result.map_error(store_fault)
      |> result.replace(Counted(0))
    })
  case done {
    Ok(_) -> {
      report(config, job, reason, 0, started, telemetry.job_set_aside())
      True
    }
    Error(_) -> False
  }
}

fn report(
  config: Config(tx),
  job: Job,
  reason: String,
  attempts: Int,
  started: Int,
  event: sinal.Event(telemetry.Took, telemetry.JobMetadata),
) -> Nil {
  let #(point, occurrence) = backlog.about(job)
  sinal.emit(
    event,
    telemetry.Took(monotonic_us() - started),
    telemetry.JobMetadata(
      source: config.name,
      point:,
      occurrence:,
      correlation: telemetry.about(config.name, point, occurrence).correlation,
      queue: case job {
        WakeJob(_) -> telemetry.WakeQueue
        NoticeJob(_) -> telemetry.NoticeQueue
        TriggerJob(_) -> telemetry.TriggerQueue
      },
      reason:,
      attempts:,
    ),
  )
}

// -- Helpers ------------------------------------------------------------------------------

fn find(config: Config(tx), name: String) -> Result(Wired(tx), Nil) {
  list.find(config.points, fn(wired) { wired.name == name })
}

type Crash

@external(erlang, "decisions_otp_ffi", "attempt")
fn attempt(body: fn() -> a) -> Result(a, Crash)

@external(erlang, "decisions_otp_ffi", "monotonic_us")
fn monotonic_us() -> Int

@external(erlang, "decisions_otp_ffi", "parent")
fn parent() -> Pid

@external(erlang, "decisions_otp_ffi", "set_role")
fn set_role(role: Role) -> Nil

@external(erlang, "decisions_otp_ffi", "children")
fn which_children(supervisor: Pid) -> List(#(Pid, Option(Role)))
