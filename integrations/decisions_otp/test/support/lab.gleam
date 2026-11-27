//// Test support: points and desks over the process-safe store.

import decisions.{type Desk, type Point, Gated}
import decisions/fact.{type Key}
import decisions/occurrence.{type Occurrence}
import decisions/policy.{
  type Policy, AnyoneHolding, Never, PerCent, Proceed, When,
}
import decisions/vocabulary.{
  type Recommender, type Subject, ApproveRejectOrCorrect, Manifest,
  Recommendation, Ref, RuleFired, Subject, Trigger, Validator,
}
import decisions/wire
import decisions_otp/isolated
import decisions_otp/runtime as decisions_otp_runtime
import decisions_otp/store.{type Store, type Tx}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration.{type Duration}
import support/policies

pub const ana = Subject(kind: "person", id: "ana")

pub const clinica = Subject(kind: "company", id: "clinica-x")

pub const bia = Validator(subject: "bia", holds: ["finance", "support"])

pub const felipe = Validator(subject: "felipe", holds: ["finance", "support"])

@external(erlang, "decisions_otp_ffi", "quiet")
pub fn quiet() -> Nil

pub fn start() -> Store {
  quiet()
  let assert Ok(s) = store.start(config())
  s
}

/// A heap limit far above what the tests' models use.
pub fn heap() -> isolated.HeapLimit {
  let assert Ok(heap) = isolated.heap_limit(megabytes: 256)
  heap
}

/// The defaults, with a retry backoff short enough for tests.
pub fn config() -> store.Config {
  store.Config(..store.defaults(), retry_backoff: duration.milliseconds(10))
}

pub fn score() -> Key(Float) {
  fact.number("score")
}

pub fn point(name: String, hold: Option(Duration)) -> Point(String) {
  let point =
    decisions.point(name, wire.text())
    |> decisions.allowing(ApproveRejectOrCorrect)
    |> decisions.superseded_by("superseded")
    |> decisions.signal(score())
  case hold {
    Some(hold) -> decisions.with_hold(point, hold)
    None -> point
  }
}

pub fn asking(set: String) -> Policy {
  policies.checked(version: 1, rules: [], otherwise: AnyoneHolding(set))
}

pub fn proceeding() -> Policy {
  policies.checked(
    version: 1,
    rules: [policy.When(policy.Always, Proceed(Never, hold: None))],
    otherwise: policy.AnyoneHolding("nobody"),
  )
}

/// Proceed at a score of 0.9 or above and sample `share` per cent; ask
/// `support` otherwise.
pub fn scoring(share: Int) -> Policy {
  policies.checked(
    version: 2,
    rules: [
      When(policy.at_least(score(), 0.9), Proceed(PerCent(share), hold: None)),
    ],
    otherwise: AnyoneHolding("support"),
  )
}

/// A desk whose gated tool adds `key=output` to the table named after the
/// point, and calls `also` first.
pub fn desk_with(
  point: Point(String),
  policy: Policy,
  also: fn(Tx) -> Nil,
) -> Desk(String, Tx) {
  let table = decisions.name(point)
  decisions.desk(
    point,
    drives: fn(_) {
      Gated(name: table, guard: fn(_, _) { Ok([]) }, execute: fn(tx, released) {
        also(tx)
        store.add(
          tx,
          table,
          decisions.key(released) <> "=" <> decisions.output(released),
        )
        Ok(Nil)
      })
    },
    under: fn(_) { Ok(policy) },
    over: store.port(),
  )
}

pub fn desk(point: Point(String), policy: Policy) -> Desk(String, Tx) {
  desk_with(point, policy, fn(_) { Nil })
}

pub fn effects(s: Store, desk: Desk(String, Tx)) -> Int {
  within(s, store.count(_, decisions.name(decisions.point_of(desk))))
}

/// Run `body` in a transaction of its own and return what it returned:
/// an application row read or written outside a verb.
pub fn within(s: Store, body: fn(Tx) -> a) -> a {
  let assert Ok(value) = store.transaction(s, fn(tx) { Ok(body(tx)) })
  value
}

pub fn recommend(
  desk: Desk(String, Tx),
  tx: Tx,
  key: String,
  about about: Subject,
  output output: String,
  by by: Recommender,
  score value: Float,
) -> Result(Occurrence(String), decisions.Refusal) {
  decisions.recommend_once(
    desk,
    tx,
    key:,
    proposal: decisions.proposal(
      trigger: Trigger(kind: "lab", id: key),
      about:,
      context: Manifest(refs: [Ref("input", key, "1")], renderer: "lab-1"),
      recommending: Recommendation(
        output:,
        by:,
        explanation: RuleFired("lab"),
        signals: [fact.set(score(), value)],
        reads: [],
      ),
    ),
  )
}

pub fn open_and_decide(
  desk: Desk(String, Tx),
  tx: Tx,
  id: String,
  validator: vocabulary.Validator,
  verdict: vocabulary.Verdict(String),
) -> Result(Occurrence(String), decisions.Refusal) {
  use card <- result.try(
    decisions.open(desk, tx, occurrence: id, by: validator, latest: fn(ref) {
      ref.revision
    }),
  )
  decisions.decide(desk, tx, card, verdict)
}

pub fn wait_until(condition: fn() -> Bool, within ms: Int) -> Bool {
  case condition(), ms <= 0 {
    True, _ -> True
    False, True -> False
    False, False -> {
      process.sleep(5)
      wait_until(condition, ms - 5)
    }
  }
}

/// Kill `pid` and wait until it is gone.
pub fn kill(pid: Pid) -> Nil {
  let monitor = process.monitor(pid)
  process.kill(pid)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(5000)
  Nil
}

pub fn numbers(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..numbers(from + 1, to)]
  }
}

/// Start a runtime from a process of its own, so that killing it does not
/// take the test with it. Returns the supervisor.
pub fn start_runtime(config: decisions_otp_runtime.Config(tx)) -> Pid {
  let reply = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(started) = decisions_otp_runtime.start(config)
    process.send(reply, started.pid)
    process.sleep_forever()
  })
  let assert Ok(pid) = process.receive(reply, 5000)
  pid
}

/// The pid of the runtime's child in `role`.
pub fn child(supervisor: Pid, role: decisions_otp_runtime.Role) -> Pid {
  let assert Ok(pid) =
    decisions_otp_runtime.children(supervisor)
    |> list.key_find(role)
  pid
}

/// Kill a runtime and wait until its supervisor and every child are gone,
/// so that nothing of it acts after this returns.
pub fn stop_runtime(supervisor: Pid) -> Nil {
  let children =
    decisions_otp_runtime.children(supervisor) |> list.map(fn(pair) { pair.1 })
  list.each([supervisor, ..children], kill)
}
