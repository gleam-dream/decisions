//// The race and crash scenarios of conditions A and B, written once
//// against any store. `decisions_otp` runs them against its in-memory
//// store; a database adapter runs the very same scenarios against its
//// database by building a `Target` and calling `run`.
////
//// A race starts every process at a gate and releases them in shuffled
//// order (`race`). A crash is `process.kill` at a named point
//// (`KillPoint`). Every scenario ends with `decisions/testing.check`
//// (invariants I1 to I9) over the points it used.
////
//// | Scenario | What it shows |
//// | --- | --- |
//// | A1 | forty verdicts, eight wake-ups and a superseding event on one occurrence: one verdict stands, the tool runs at most once, every loser gets a typed refusal |
//// | A2 | sixteen validators drain a queue: each occurrence is decided once and nobody blocks |
//// | A3 | a withdrawal, a wake-up and the clock passing the hold race: each trial ends withdrawn with no send or released with one, and both endings occur |
//// | A4 | a random walk of eight processes over fifty occurrences: every invariant, and every earlier record is a prefix of the later |
//// | held superseded | a held occurrence whose hold has ended, raced by its wake-up and a superseding event: each trial ends released (the wake-up came first) or superseded with nothing released, never both |
//// | admissions | eight transactions about one subject, each `happened` then `expect` of its own key, all open before any commits: the subject lock orders them, so exactly one key is left pending, every other key was superseded before it began, and the lock's id holds nothing |
//// | expect | a key expected with `decisions.expect`, raced by a slow model's recommendation and a superseding event: never a stale occurrence left waiting; the same sequence without `expect` leaves one, which is why the verb exists |
//// | one key | concurrent `recommend_once` on one key: one occurrence, one effect |
//// | clauses | a load of an absent or present id waits for the transaction that holds it (seen positively: the load returns after the holder is let go); uncommitted writes, wake-ups and notices are invisible, and a commit appears to a racing reader all at once; a process killed inside a transaction or a savepoint leaves nothing and releases its lock; concurrent `happened` and `decide` do not deadlock; wake-ups and notices survive a store restart, and so does every commit acknowledged while four processes commit through the restart; `now` is the wall clock at the moment of the call, so a transaction that stays open sees time move; `schedule` leaves alone a wake-up a delivery already took |
//// | B1 | a worker killed during the model, and after the commit before acknowledging: one occurrence per trigger |
//// | B2 | a process killed inside the verdict after the tool wrote: no write, the occurrence still waits, a second verdict succeeds once |
//// | B4 | the runtime killed with holds pending and started again after they ended: each released once |
//// | B5 | a random child of the runtime killed every 50 ms while occurrences move; the triggers arrive in waves paced by the kills, so at least five children die while work is in flight at any load: all settle |
//// | B6 | a record that no longer decodes is set aside at once; a settlement handler and a trigger that always fail are set aside after three attempts; the jobs behind them are delivered |
//// | B7 | a model that raises and one that hangs: a typed failure within the deadline, on the record |
//// | own deadline | four keys expected with one deadline of their own, the store restarted before it: each expires once at the deadline, a late recommendation is recorded expired, a late failure and a late verdict are refused |
//// | every notice | a record superseded before it began, one lapsed at its own deadline, two lapsed and recommended late (before and after their wake-up), and one rejected: the runtime hands each settlement notice to the point's follower exactly once, none dropped or set aside |
//// | bundles | a quarter of A2's queue in bundles of five, each admitted in one transaction, every member decided at once from its own process after a random wait: the follower that sees a bundle complete recommends its follow-on under a key derived from the bundle, so each bundle starts exactly one follow-on, never none and never two |
////
//// A database adapter's test runs them like this:
////
//// ```gleam
//// import decisions_otp/stress
////
//// pub fn stress_test() {
////   let assert Ok(Nil) = stress.run(fresh_target, stress.default_load())
//// }
//// ```

import decisions.{type Desk, type Refusal, Gated}
import decisions/conformance.{type Adapter}
import decisions/entry
import decisions/fact.{type Key}
import decisions/model
import decisions/occurrence
import decisions/policy.{type Policy, AnyoneHolding, Never, Proceed}
import decisions/store.{type Stored}
import decisions/testing
import decisions/vocabulary.{
  type Recommender, type Subject, Approve, ApproveRejectOrCorrect, Correct,
  Manifest, Person, Reason, Recommendation, Ref, Reject, Right, RuleFired, Rules,
  Subject, Trigger, Validator,
}
import decisions/wire
import decisions_otp/backlog.{type Backlog, type Submitted}
import decisions_otp/isolated
import decisions_otp/runtime
import decisions_otp/store as memory
import decisions_otp/telemetry
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp
import sinal

/// A store under test: what the scenarios need beyond the conformance
/// `Adapter`.
pub type Target(tx) {
  Target(
    /// The port, the inspection and the transaction function. The
    /// scenarios read and write only inside transactions.
    adapter: Adapter(tx),
    /// The store's backlog, for the scenarios that run the runtime.
    backlog: Backlog(tx),
    /// Add a row to an application table, in the caller's transaction. A
    /// gated tool writes its effects with it.
    add: fn(tx, String, String) -> Result(Nil, String),
    /// Every row of an application table, as values.
    rows: fn(tx, String) -> Result(List(String), String),
    /// The first occurrences of a decision set's queue, at most the given
    /// number, in queue order: the soonest due first, then by arrival.
    queue: fn(String, Int) -> Result(List(String), String),
    /// Move the store's clock forward. Every process sees the move.
    advance: fn(Duration) -> Nil,
    /// Damage the first stored entry of an occurrence so that it no longer
    /// decodes, bypassing the port.
    poison: fn(String) -> Result(Nil, String),
    /// Stop the store and start it again over what it committed, as a
    /// database restarts. Returns the target over the restarted store.
    restart: fn() -> Result(Target(tx), String),
  )
}

/// How much work each scenario does. `default_load` is the size STRESS.md
/// states; a slower store may run `light_load`.
pub type Load {
  Load(
    /// Trials of A1.
    a1_trials: Int,
    /// Occurrences A2 drains.
    a2_queue: Int,
    /// Trials of A3.
    a3_trials: Int,
    /// Verbs each of A4's eight processes performs.
    a4_steps: Int,
    /// Triggers B5 moves through the runtime.
    b5_triggers: Int,
    /// Held replies in B4.
    b4_holds: Int,
  )
}

/// The load of STRESS.md: A1 with 20 trials, A2 with 200, A3 with 200
/// trials, A4 with 200 steps per process, B4 with 100 holds and B5 with
/// 500 triggers.
pub fn default_load() -> Load {
  Load(
    a1_trials: 20,
    a2_queue: 200,
    a3_trials: 200,
    a4_steps: 200,
    b5_triggers: 500,
    b4_holds: 100,
  )
}

/// A quarter of the default load, for a store whose round trips are slow.
pub fn light_load() -> Load {
  Load(
    a1_trials: 12,
    a2_queue: 50,
    a3_trials: 50,
    a4_steps: 50,
    b5_triggers: 120,
    b4_holds: 25,
  )
}

/// One scenario.
pub type Scenario(tx) {
  Scenario(name: String, run: fn(Target(tx), Load) -> Result(Nil, String))
}

/// A scenario that did not pass, and what it saw.
pub type Failure {
  /// `fresh` could not build a target.
  SetupFailed(reason: String)
  /// The scenario ran and saw something the contract forbids.
  Failed(scenario: String, saw: String)
}

/// Where a scenario kills a process.
pub type KillPoint {
  /// A worker, while its model computes.
  DuringModel
  /// A worker, after its recommendation committed and before it
  /// acknowledged the trigger.
  AfterCommitBeforeAck
  /// A validator's process, inside the verdict's transaction, after the
  /// gated tool wrote.
  InsideVerdictAfterToolWrote
}

/// Kill the calling process at `point`. It does not return.
pub fn kill_here(at point: KillPoint) -> a {
  let _ = point
  process.kill(process.self())
  process.sleep_forever()
  panic as "a killed process ran on"
}

/// Every scenario, in the order `run` runs them.
pub fn scenarios() -> List(Scenario(tx)) {
  [
    Scenario("A1 forty verdicts, eight wake-ups and a superseding event", a1),
    Scenario("A2 sixteen validators drain a queue", a2),
    Scenario("A3 a withdrawal races the hold's end", a3),
    Scenario("A4 a random walk keeps every invariant", a4),
    Scenario(
      "a held occurrence superseded under a race releases nothing",
      held_superseded,
    ),
    Scenario("expect closes the superseding window", expect_closes_window),
    Scenario(
      "concurrent admissions about one subject leave one key pending",
      admissions,
    ),
    Scenario("recommend_once on one key from many processes", one_key),
    Scenario("a load of an absent id waits for the holder", absent_waits),
    Scenario("a load of a present id waits for the holder", present_waits),
    Scenario("uncommitted writes are invisible", uncommitted_invisible),
    Scenario("a process killed in a transaction leaves nothing", killed_in_tx),
    Scenario(
      "a process killed in a savepoint leaves nothing",
      killed_in_savepoint,
    ),
    Scenario("happened and decide do not deadlock", no_deadlock),
    Scenario("wake-ups and notices survive a store restart", survive_restart),
    Scenario("now is the wall clock at the moment of the call", wall_clock),
    Scenario("schedule leaves a delivered wake-up alone", delivered_alone),
    Scenario("B1 a worker killed during the model or after the commit", b1),
    Scenario("B2 a process killed inside the verdict", b2),
    Scenario("B4 the runtime restarts with holds pending", b4),
    Scenario("B5 chaos while occurrences move", b5),
    Scenario("B6 poison is set aside", b6),
    Scenario("B7 a model that raises or hangs", b7),
    Scenario(
      "an expected record expires at its own deadline through a restart",
      own_deadline,
    ),
    Scenario(
      "every settlement notice reaches the follower, begun or not",
      every_notice,
    ),
    Scenario("each bundle starts exactly one follow-on", bundles),
  ]
}

/// Every scenario's name.
pub fn names() -> List(String) {
  list.map(scenarios(), fn(scenario: Scenario(Nil)) { scenario.name })
}

/// Run every scenario, each on a fresh target, and report every failure.
/// `fresh` builds a target; its adapter's `cleanup` runs after each
/// scenario.
pub fn run(
  fresh: fn() -> Result(Target(tx), String),
  load: Load,
) -> Result(Nil, List(Failure)) {
  let failures =
    list.filter_map(scenarios(), fn(scenario) {
      case run_scenario(scenario, fresh, load) {
        Ok(Nil) -> Error(Nil)
        Error(failure) -> Ok(failure)
      }
    })
  case failures {
    [] -> Ok(Nil)
    _ -> Error(failures)
  }
}

/// Run one scenario on a fresh target.
pub fn run_scenario(
  scenario: Scenario(tx),
  fresh: fn() -> Result(Target(tx), String),
  load: Load,
) -> Result(Nil, Failure) {
  use target <- result.try(fresh() |> result.map_error(SetupFailed))
  let outcome = scenario.run(target, load)
  target.adapter.cleanup()
  outcome |> result.map_error(Failed(scenario.name, _))
}

/// A target over a new process-safe in-memory store, started with
/// `config` and linked to the caller.
pub fn in_memory(config: memory.Config) -> Result(Target(memory.Tx), String) {
  memory.start(config)
  |> result.replace_error("the store did not start")
  |> result.map(over_store(_, config))
}

/// A target over a running process-safe store.
pub fn over_store(s: memory.Store, config: memory.Config) -> Target(memory.Tx) {
  Target(
    adapter: conformance.Adapter(
      port: memory.port(),
      inspect: memory.inspection(),
      transaction: fn(body) { memory.transaction(s, body) },
      cleanup: fn() { memory.stop(s) },
    ),
    backlog: memory.backlog(s),
    add: fn(tx, table, row) { Ok(memory.add(tx, table, row)) },
    rows: fn(tx, table) {
      Ok(list.map(memory.rows(tx, table), fn(pair) { pair.1 }))
    },
    queue: fn(set, limit) { Ok(memory.queue_page(s, set, limit)) },
    advance: fn(by) { memory.advance(s, by) },
    poison: fn(id) { Ok(memory.tamper(s, id, 1, "{not json")) },
    restart: fn() {
      memory.restart(s, config)
      |> result.replace_error("the store did not restart")
      |> result.map(over_store(_, config))
    },
  )
}

// -- Races -------------------------------------------------------------------------------

/// Run `work` on each item in a process of its own, linked to the caller.
/// Every process waits at a gate until all are ready, then the gates open
/// in shuffled order, so no process is given a head start. The results
/// come back in the items' order.
pub fn race(items: List(a), work: fn(a) -> b) -> List(b) {
  let ready = process.new_subject()
  let reply = process.new_subject()
  let count = list.length(items)
  list.index_map(items, fn(item, index) {
    process.spawn(fn() {
      let gate = process.new_subject()
      process.send(ready, gate)
      let assert Ok(Nil) = process.receive(gate, 60_000)
      process.send(reply, #(index, work(item)))
    })
  })
  let gates = list.map(list.repeat(Nil, count), fn(_) { receive(ready) })
  list.each(list.shuffle(gates), process.send(_, Nil))
  list.map(list.repeat(Nil, count), fn(_) { receive(reply) })
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> list.map(fn(pair) { pair.1 })
}

fn receive(subject: process.Subject(a)) -> a {
  case process.receive(subject, 60_000) {
    Ok(value) -> value
    Error(Nil) -> panic as "a racing process did not answer within a minute"
  }
}

// -- Lab ----------------------------------------------------------------------------------

/// What a verb's transaction came to.
type Said {
  Refused(Refusal)
  StoreSaid(String)
}

/// Run `body` in one transaction of the target and return what it
/// returned, or why it did not commit.
fn within(
  target: Target(tx),
  body: fn(tx) -> Result(a, Refusal),
) -> Result(a, Said) {
  let box = process.new_subject()
  let committed =
    target.adapter.transaction(fn(tx) {
      let outcome = body(tx)
      process.send(box, outcome)
      case outcome {
        Ok(_) -> Ok("")
        Error(refusal) -> Error(decisions.describe(refusal))
      }
    })
  case committed, process.receive(box, 0) {
    Ok(_), Ok(Ok(value)) -> Ok(value)
    Error(_), Ok(Error(refusal)) -> Error(Refused(refusal))
    Error(reason), _ -> Error(StoreSaid(reason))
    Ok(_), _ -> Error(StoreSaid("the transaction committed without an answer"))
  }
}

/// Run `body` in one transaction of the target, roll it back when it
/// fails, and return what it returned. Every read of the scenarios runs in
/// one too: the port has no value that stands for "no transaction".
pub fn transaction(
  target: Target(tx),
  body: fn(tx) -> Result(a, String),
) -> Result(a, String) {
  let box = process.new_subject()
  use _ <- result.try(
    target.adapter.transaction(fn(tx) {
      use value <- result.map(body(tx))
      process.send(box, value)
      ""
    }),
  )
  process.receive(box, 0)
  |> result.replace_error("the transaction committed without an answer")
}

fn said(said: Said) -> String {
  case said {
    Refused(refusal) -> "refused: " <> decisions.describe(refusal)
    StoreSaid(reason) -> "the store said: " <> reason
  }
}

fn unique(target: Target(tx), prefix: String) -> String {
  case transaction(target, fn(tx) { Ok(target.adapter.port.new_id(tx)) }) {
    Ok(id) -> prefix <> "-" <> id
    Error(reason) -> panic as { "no new id: " <> reason }
  }
}

fn score() -> Key(Float) {
  fact.number("score")
}

const ana = Subject(kind: "person", id: "ana")

const clinica = Subject(kind: "company", id: "clinica-x")

fn point(name: String, hold: Option(Duration)) -> decisions.Point(String) {
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

fn asking(set: String) -> Policy {
  well_formed(version: 1, rules: [], otherwise: AnyoneHolding(set))
}

fn proceeding() -> Policy {
  well_formed(
    version: 1,
    rules: [policy.When(policy.Always, Proceed(Never, hold: None))],
    otherwise: policy.AnyoneHolding("nobody"),
  )
}

/// A desk whose gated tool adds `key=output` to the table named after
/// the point.
fn desk(
  target: Target(tx),
  point: decisions.Point(String),
  policy: Policy,
) -> Desk(String, tx) {
  let table = decisions.name(point)
  decisions.desk(
    point,
    drives: fn(_) {
      Gated(name: table, guard: fn(_, _) { Ok([]) }, execute: fn(tx, released) {
        target.add(
          tx,
          table,
          decisions.key(released) <> "=" <> decisions.output(released),
        )
        |> result.map_error(vocabulary.Refuse)
      })
    },
    under: fn(_) { Ok(policy) },
    over: target.adapter.port,
  )
}

fn effects(
  target: Target(tx),
  desk: Desk(String, tx),
) -> Result(List(String), String) {
  transaction(target, target.rows(_, decisions.name(decisions.point_of(desk))))
}

fn audit(target: Target(tx), desk: Desk(String, tx)) -> testing.Audit(tx) {
  testing.audit(desk, effects: fn(tx) {
    target.rows(tx, decisions.name(decisions.point_of(desk)))
    |> result.map(list.length)
  })
}

fn invariants(
  target: Target(tx),
  desks: List(Desk(String, tx)),
) -> Result(Nil, String) {
  use tx <- transaction(target)
  testing.check(tx, target.adapter.inspect, list.map(desks, audit(target, _)))
  |> result.replace(Nil)
  |> result.map_error(fn(violations) {
    "invariants broken: " <> string.inspect(violations)
  })
}

fn recommend(
  desk: Desk(String, tx),
  tx: tx,
  key: String,
  about about: Subject,
  output output: String,
  by by: Recommender,
  score value: Float,
) -> Result(occurrence.Occurrence(String), Refusal) {
  decisions.recommend_once(
    desk,
    tx,
    key:,
    proposal: decisions.proposal(
      trigger: Trigger(kind: "stress", id: key),
      about:,
      context: Manifest(refs: [Ref("input", key, "1")], renderer: "stress-1"),
      recommending: Recommendation(
        output:,
        by:,
        explanation: RuleFired("stress"),
        signals: [fact.set(score(), value)],
        reads: [],
      ),
    ),
  )
}

fn open_and_decide(
  desk: Desk(String, tx),
  tx: tx,
  id: String,
  validator: vocabulary.Validator,
  verdict: vocabulary.Verdict(String),
) -> Result(occurrence.Occurrence(String), Refusal) {
  use card <- result.try(
    decisions.open(desk, tx, occurrence: id, by: validator, latest: fn(ref) {
      ref.revision
    }),
  )
  decisions.decide(desk, tx, card, verdict)
}

fn read(
  target: Target(tx),
  desk: Desk(String, tx),
  id: String,
) -> Result(occurrence.Occurrence(String), String) {
  use tx <- transaction(target)
  decisions.read(desk, tx, occurrence: id)
  |> result.map_error(decisions.describe)
}

fn expect(holds: Bool, otherwise: String) -> Result(Nil, String) {
  case holds {
    True -> Ok(Nil)
    False -> Error(otherwise)
  }
}

fn numbers(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..numbers(from + 1, to)]
  }
}

fn wait_until(condition: fn() -> Bool, within ms: Int) -> Bool {
  case condition(), ms <= 0 {
    True, _ -> True
    False, True -> False
    False, False -> {
      process.sleep(5)
      wait_until(condition, ms - 5)
    }
  }
}

/// The heap limit of the scenarios' isolated models: far above what they
/// use.
fn stress_heap() -> isolated.HeapLimit {
  let assert Ok(heap) = isolated.heap_limit(megabytes: 256)
  heap
}

fn store_text(result: Result(a, store.StoreError)) -> Result(a, String) {
  result.map_error(result, store.describe)
}

fn load_entries(
  target: Target(tx),
  id: String,
) -> Result(List(Stored), String) {
  use tx <- transaction(target)
  target.adapter.port.load(tx, id) |> store_text
}

fn status_of(target: Target(tx), id: String) -> Result(String, String) {
  use head <- result.try(
    transaction(target, fn(tx) {
      target.adapter.inspect.head(tx, id) |> store_text
    }),
  )
  case head {
    Some(head) -> Ok(store.status_name(head.status))
    None -> Ok("absent")
  }
}

// -- A1 -----------------------------------------------------------------------------------

fn a1(target: Target(tx), load: Load) -> Result(Nil, String) {
  let desk =
    desk(target, point(unique(target, "refund"), None), asking("finance"))
  use endings <- result.try(
    list.try_map(numbers(1, load.a1_trials), fn(trial) {
      let key = unique(target, "refund-" <> int.to_string(trial))
      use _ <- result.try(
        within(target, recommend(
          desk,
          _,
          key,
          about: ana,
          output: "80.00",
          by: Rules("refund-rules", "1"),
          score: 0.5,
        ))
        |> result.map_error(said),
      )
      let results =
        race(numbers(1, 49), fn(n) {
          case n {
            _ if n <= 40 -> {
              let validator =
                Validator(subject: "v" <> int.to_string(n), holds: ["finance"])
              let verdict = case n % 2 {
                0 -> Approve
                _ -> Reject(Reason("not_due", None))
              }
              within(target, open_and_decide(desk, _, key, validator, verdict))
              |> result.replace(Nil)
            }
            _ if n <= 48 ->
              within(target, decisions.wake(desk, _, occurrence: key))
              |> result.replace(Nil)
            _ ->
              within(target, decisions.happened(
                desk,
                _,
                "superseded",
                about: ana,
              ))
              |> result.replace(Nil)
          }
        })
      use final <- result.try(read(target, desk, key))
      let verdicts = occurrence.verdicts(final)
      use rows <- result.try(effects(target, desk))
      let sent =
        list.count(rows, fn(row) { string.starts_with(row, decisions_key(key)) })
      let deciders = list.take(results, 40)
      let stood = list.count(deciders, result.is_ok)
      use Nil <- result.try(expect(
        list.length(verdicts) <= 1,
        "several verdicts stood on " <> key,
      ))
      use Nil <- result.try(expect(
        sent
          == case final.status {
          occurrence.Released(..) -> 1
          _ -> 0
        },
        int.to_string(sent)
          <> " effects for an occurrence ended "
          <> occurrence.status_name(final.status),
      ))
      use Nil <- result.try(expect(
        stood == list.length(verdicts),
        int.to_string(stood) <> " verdicts returned Ok",
      ))
      use Nil <- result.try(
        list.try_each(results, fn(outcome) {
          case outcome {
            Ok(Nil) -> Ok(Nil)
            Error(Refused(decisions.AlreadyDecided(_)))
            | Error(Refused(decisions.NotAwaiting)) -> Ok(Nil)
            Error(other) -> Error("a loser was told " <> said(other))
          }
        }),
      )
      Ok(occurrence.status_name(final.status))
    }),
  )
  use Nil <- result.try(expect(
    list.length(list.unique(endings)) >= 2,
    "every trial ended " <> string.join(list.unique(endings), ", "),
  ))
  invariants(target, [desk])
}

/// The prefix of the effect row a release of `key` writes.
fn decisions_key(key: String) -> String {
  "release:" <> key <> "="
}

// -- A2 -----------------------------------------------------------------------------------

fn a2(target: Target(tx), load: Load) -> Result(Nil, String) {
  let desk =
    desk(target, point(unique(target, "classify"), None), asking("support"))
  let keys =
    list.map(numbers(1, load.a2_queue), fn(n) {
      unique(target, "post-" <> int.to_string(n))
    })
  use Nil <- result.try(
    within(target, fn(tx) {
      list.try_each(keys, fn(key) {
        recommend(
          desk,
          tx,
          key,
          about: clinica,
          output: "ok",
          by: Rules("rules", "1"),
          score: 0.5,
        )
        |> result.replace(Nil)
      })
    })
    |> result.map_error(said),
  )
  let decided =
    race(numbers(1, 16), fn(n) {
      let validator =
        Validator(subject: "v" <> int.to_string(n), holds: ["support"])
      list.shuffle(keys)
      |> list.try_fold(0, fn(done, key) {
        case within(target, open_and_decide(desk, _, key, validator, Approve)) {
          Ok(_) -> Ok(done + 1)
          Error(Refused(decisions.AlreadyDecided(_)))
          | Error(Refused(decisions.NotAwaiting)) -> Ok(done)
          Error(other) -> Error(said(other))
        }
      })
    })
  use counts <- result.try(result.all(decided))
  use rows <- result.try(effects(target, desk))
  use waiting <- result.try(
    transaction(target, fn(tx) {
      target.adapter.port.waiting(
        tx,
        decisions.name(decisions.point_of(desk)),
        clinica,
      )
      |> store_text
    }),
  )
  use Nil <- result.try(expect(
    int.sum(counts) == load.a2_queue,
    int.to_string(int.sum(counts)) <> " decided",
  ))
  use Nil <- result.try(expect(
    list.length(rows) == load.a2_queue,
    int.to_string(list.length(rows)) <> " effects",
  ))
  use Nil <- result.try(expect(waiting == [], "occurrences still wait"))
  invariants(target, [desk])
}

// -- A3 -----------------------------------------------------------------------------------

/// A held reply; one process withdraws, one delivers the wake-up, and one
/// moves the clock past the hold, all at once. Then one more wake-up, as
/// the sweeper would deliver. With the clock deciding, a withdrawal before
/// the hold ended wins, and a wake-up after it releases.
fn a3(target: Target(tx), load: Load) -> Result(Nil, String) {
  let desk =
    desk(
      target,
      point(unique(target, "reply"), Some(duration.minutes(2))),
      proceeding(),
    )
  use endings <- result.try(
    list.try_map(numbers(1, load.a3_trials), fn(trial) {
      let key = unique(target, "reply-" <> int.to_string(trial))
      use held <- result.try(
        within(target, recommend(
          desk,
          _,
          key,
          about: ana,
          output: "Olá, Ana.",
          by: Person("bia"),
          score: 1.0,
        ))
        |> result.map_error(said),
      )
      use Nil <- result.try(case held.status {
        occurrence.Held(..) -> Ok(Nil)
        other -> Error("expected held, found " <> occurrence.status_name(other))
      })
      let _ =
        race([0, 1, 2], fn(n) {
          case n {
            0 ->
              within(target, decisions.withdraw(
                desk,
                _,
                occurrence: key,
                by: "bia",
              ))
              |> result.replace(Nil)
            1 ->
              within(target, decisions.wake(desk, _, occurrence: key))
              |> result.replace(Nil)
            // The clock passes the hold while the occurrence is locked, so
            // the three are ordered by the lock, as equals.
            _ ->
              within(target, fn(tx) {
                use _ <- result.try(decisions.read(desk, tx, occurrence: key))
                Ok(target.advance(duration.minutes(3)))
              })
          }
        })
      let _ = within(target, decisions.wake(desk, _, occurrence: key))
      use final <- result.try(read(target, desk, key))
      use rows <- result.try(effects(target, desk))
      let sent =
        list.count(rows, fn(row) { string.starts_with(row, decisions_key(key)) })
      case final.status, sent {
        occurrence.Withdrawn(_), 0 -> Ok("withdrawn")
        occurrence.Released(..), 1 -> Ok("released")
        other, _ ->
          Error(
            key
            <> " ended "
            <> occurrence.status_name(other)
            <> " with "
            <> int.to_string(sent)
            <> " sends",
          )
      }
    }),
  )
  use Nil <- result.try(expect(
    list.contains(endings, "withdrawn") && list.contains(endings, "released"),
    "every trial ended " <> string.join(list.unique(endings), ", "),
  ))
  invariants(target, [desk])
}

// -- A4 -----------------------------------------------------------------------------------

fn a4(target: Target(tx), load: Load) -> Result(Nil, String) {
  let desk =
    desk(
      target,
      point(unique(target, "walk"), Some(duration.minutes(1))),
      asking("finance"),
    )
  let prefix = unique(target, "walk")
  let key = fn() { prefix <> "-" <> int.to_string(int.random(50)) }
  let who = fn() {
    Validator(subject: "v" <> int.to_string(int.random(6)), holds: ["finance"])
  }
  let walked =
    race(numbers(1, 8), fn(_) {
      list.try_fold(numbers(1, load.a4_steps), [], fn(snapshots, step) {
        let id = key()
        let outcome = case int.random(9) {
          0 | 1 ->
            within(target, recommend(
              desk,
              _,
              id,
              about: case int.random(2) {
                0 -> ana
                _ -> clinica
              },
              output: "draft",
              by: Rules("rules", "1"),
              score: 0.5,
            ))
            |> result.replace(Nil)
          2 | 3 ->
            within(target, open_and_decide(desk, _, id, who(), Approve))
            |> result.replace(Nil)
          4 ->
            within(
              target,
              open_and_decide(desk, _, id, who(), case int.random(2) {
                0 -> Reject(Reason("no", None))
                _ -> Correct("edited", Reason("tone", None))
              }),
            )
            |> result.replace(Nil)
          5 ->
            within(target, decisions.withdraw(
              desk,
              _,
              occurrence: id,
              by: "v" <> int.to_string(int.random(6)),
            ))
            |> result.replace(Nil)
          6 -> {
            target.advance(duration.seconds(20))
            within(target, decisions.wake(desk, _, occurrence: id))
            |> result.replace(Nil)
          }
          7 ->
            within(target, decisions.happened(desk, _, "superseded", about: ana))
            |> result.replace(Nil)
          _ ->
            within(target, decisions.assess(
              desk,
              _,
              occurrence: id,
              finding: vocabulary.Assessment(
                finding: Right,
                evidence: Ref("audit", id, "1"),
                source: "audit",
                known_at: target.backlog.now(),
              ),
            ))
            |> result.replace(Nil)
        }
        case outcome {
          Error(StoreSaid(reason)) -> Error("the store said " <> reason)
          _ ->
            case step % 20 {
              0 ->
                load_snapshot(target, id)
                |> result.map(fn(s) { [s, ..snapshots] })
              _ -> Ok(snapshots)
            }
        }
      })
    })
  use snapshots <- result.try(result.all(walked) |> result.map(list.flatten))
  use Nil <- result.try(
    list.try_each(snapshots, fn(snapshot) {
      use now <- result.try(load_entries(target, snapshot.0))
      expect(
        list.take(now, list.length(snapshot.1)) == snapshot.1,
        "I7: the record of "
          <> snapshot.0
          <> " is not an extension of what it was",
      )
    }),
  )
  use ids <- result.try(
    transaction(target, fn(tx) {
      target.adapter.inspect.occurrences(
        tx,
        decisions.name(decisions.point_of(desk)),
      )
      |> store_text
    }),
  )
  use statuses <- result.try(list.try_map(ids, status_of(target, _)))
  use Nil <- result.try(expect(
    list.length(list.unique(statuses)) >= 3,
    "the walk reached only " <> string.join(list.unique(statuses), ", "),
  ))
  invariants(target, [desk])
}

fn load_snapshot(
  target: Target(tx),
  id: String,
) -> Result(#(String, List(Stored)), String) {
  load_entries(target, id) |> result.map(fn(entries) { #(id, entries) })
}

// -- Superseding -----------------------------------------------------------------------

/// A held reply whose hold has ended; its wake-up and a superseding
/// event about its subject race. Either the wake-up came first and the
/// reply was released, once, or the event came first and the reply
/// expired superseded, with nothing released and no wake-up left.
fn held_superseded(target: Target(tx), load: Load) -> Result(Nil, String) {
  let desk =
    desk(
      target,
      point(unique(target, "held"), Some(duration.minutes(2))),
      proceeding(),
    )
  use _endings <- result.try(
    list.try_map(numbers(1, load.a3_trials), fn(trial) {
      let key = unique(target, "held-" <> int.to_string(trial))
      let about = Subject("person", key)
      use held <- result.try(
        within(target, recommend(
          desk,
          _,
          key,
          about:,
          output: "Olá",
          by: Person("bia"),
          score: 1.0,
        ))
        |> result.map_error(said),
      )
      use Nil <- result.try(case held.status {
        occurrence.Held(..) -> Ok(Nil)
        other -> Error("expected held, found " <> occurrence.status_name(other))
      })
      target.advance(duration.minutes(3))
      let raced =
        race([0, 1], fn(n) {
          case n {
            0 ->
              within(target, decisions.wake(desk, _, occurrence: key))
              |> result.replace(Nil)
            _ ->
              within(target, decisions.happened(desk, _, "superseded", about:))
              |> result.replace(Nil)
          }
        })
      use Nil <- result.try(
        list.try_each(raced, fn(outcome) {
          case outcome {
            Error(StoreSaid(reason)) -> Error("the store said " <> reason)
            _ -> Ok(Nil)
          }
        }),
      )
      // What the sweeper would deliver after the race.
      let _ = within(target, decisions.wake(desk, _, occurrence: key))
      use final <- result.try(read(target, desk, key))
      use rows <- result.try(effects(target, desk))
      let sent =
        list.count(rows, fn(row) { string.starts_with(row, decisions_key(key)) })
      case final.status, sent {
        occurrence.Released(..), 1 -> Ok("released")
        occurrence.Expired(vocabulary.Superseded(_)), 0 -> Ok("superseded")
        other, _ ->
          Error(
            key
            <> " ended "
            <> occurrence.status_name(other)
            <> " with "
            <> int.to_string(sent)
            <> " sends",
          )
      }
    }),
  )
  invariants(target, [desk])
}

/// A trigger's key is expected; a slow model's recommendation and a
/// superseding event about the subject race. With `expect`, whichever
/// comes first, nothing stale is left waiting: the recommendation came
/// first and the event expired it, or the event came first and the late
/// recommendation was refused with `SupersededBefore`. Then the same
/// sequence without `expect`, the event first: the late recommendation
/// waits although a newer event superseded its subject. That is the
/// window `expect` closes.
fn expect_closes_window(target: Target(tx), load: Load) -> Result(Nil, String) {
  let desk =
    desk(target, point(unique(target, "expected"), None), asking("finance"))
  let name = decisions.name(decisions.point_of(desk))
  use Nil <- result.try(
    list.try_each(numbers(1, int.max(4, load.a1_trials)), fn(trial) {
      let key = unique(target, "expected-" <> int.to_string(trial))
      let about = Subject("person", key)
      use Nil <- result.try(
        within(target, decisions.expect(
          desk,
          _,
          key:,
          trigger: Trigger("stress", key),
          about:,
        ))
        |> result.map_error(said),
      )
      let raced =
        race([0, 1], fn(n) {
          case n {
            0 -> {
              // The slow model.
              process.sleep(int.random(4))
              within(target, recommend(
                desk,
                _,
                key,
                about:,
                output: "late",
                by: Rules("rules", "1"),
                score: 0.5,
              ))
              |> result.replace(Nil)
            }
            _ ->
              within(target, decisions.happened(desk, _, "superseded", about:))
              |> result.replace(Nil)
          }
        })
      use Nil <- result.try(
        list.try_each(raced, fn(outcome) {
          case outcome {
            Ok(Nil) | Error(Refused(decisions.SupersededBefore(_))) -> Ok(Nil)
            Error(other) -> Error("a racer was told " <> said(other))
          }
        }),
      )
      use waiting <- result.try(
        transaction(target, fn(tx) {
          target.adapter.port.waiting(tx, name, about)
          |> store_text
        }),
      )
      expect(
        waiting == [],
        "with expect, a stale occurrence waits: " <> string.inspect(waiting),
      )
    }),
  )
  // Without `expect`: the event first, then the slow model's answer.
  let key = unique(target, "unexpected")
  let about = Subject("person", key)
  use _ <- result.try(
    within(target, decisions.happened(desk, _, "superseded", about:))
    |> result.map_error(said),
  )
  use _ <- result.try(
    within(target, recommend(
      desk,
      _,
      key,
      about:,
      output: "stale",
      by: Rules("rules", "1"),
      score: 0.5,
    ))
    |> result.map_error(said),
  )
  use waiting <- result.try(
    transaction(target, fn(tx) {
      target.adapter.port.waiting(tx, name, about)
      |> store_text
    }),
  )
  use Nil <- result.try(expect(
    waiting == [key],
    "without expect, the window should leave the late occurrence waiting; found "
      <> string.inspect(waiting),
  ))
  invariants(target, [desk])
}

/// Eight admissions about one subject of one point, each one transaction
/// of `happened` then `expect` of its own key. Every transaction is open
/// before any of them goes on (a barrier inside the transactions), so
/// they meet at the subject lock `happened` takes. Afterwards exactly one
/// key is pending; every other key was reported in a later admission's
/// `not_begun`, and its `recommend_once` is refused with
/// `SupersededBefore`. An admission refused as `Contended` is tried again;
/// any other failure fails the scenario. The lock's id holds no entries
/// and is in neither `waiting` nor the heads.
fn admissions(target: Target(tx), _load: Load) -> Result(Nil, String) {
  let desk =
    desk(target, point(unique(target, "admitted"), None), asking("finance"))
  let name = decisions.name(decisions.point_of(desk))
  let about = Subject("person", unique(target, "admitted"))
  let keys =
    list.map(numbers(1, 8), fn(n) {
      unique(target, "admit-" <> int.to_string(n))
    })
  // The barrier: each admission opens its transaction and reports in; a
  // releaser lets them all go only once every one has reported in, so all
  // the transactions are open before any of them commits.
  let ready = process.new_subject()
  process.spawn(fn() {
    let arrived = process.new_subject()
    process.send(ready, arrived)
    let gates =
      list.filter_map(keys, fn(_) { process.receive(arrived, 60_000) })
    list.each(gates, process.send(_, Nil))
  })
  use arrived <- result.try(
    process.receive(ready, 5000) |> result.replace_error("no releaser"),
  )
  let admitted =
    race(keys, fn(key) { admit(target, desk, about, key, Some(arrived), 0) })
  use not_begun <- result.try(result.all(admitted) |> result.map(list.flatten))
  use statuses <- result.try(
    list.try_map(keys, fn(key) {
      status_of(target, key) |> result.map(fn(status) { #(key, status) })
    }),
  )
  let pending =
    list.filter_map(statuses, fn(pair) {
      case pair.1 == "pending" {
        True -> Ok(pair.0)
        False -> Error(Nil)
      }
    })
  use Nil <- result.try(expect(
    list.length(pending) == 1,
    "pending after the admissions: " <> string.inspect(statuses),
  ))
  let superseded = list.filter(keys, fn(key) { !list.contains(pending, key) })
  use Nil <- result.try(expect(
    list.all(superseded, list.contains(not_begun, _)),
    "keys superseded but never reported in not_begun: "
      <> string.inspect(
      list.filter(superseded, fn(key) { !list.contains(not_begun, key) }),
    ),
  ))
  use Nil <- result.try(
    list.try_each(superseded, fn(key) {
      case
        within(target, recommend(
          desk,
          _,
          key,
          about:,
          output: "late",
          by: Rules("rules", "1"),
          score: 0.5,
        ))
      {
        Error(Refused(decisions.SupersededBefore(_))) -> Ok(Nil)
        other ->
          Error(key <> ": a late recommendation gave " <> string.inspect(other))
      }
    }),
  )
  let lock = decisions.subject_lock(point: name, subject: about)
  use held <- result.try(load_entries(target, lock))
  use head <- result.try(
    transaction(target, fn(tx) {
      target.adapter.inspect.head(tx, lock) |> store_text
    }),
  )
  use waiting <- result.try(
    transaction(target, fn(tx) {
      target.adapter.port.waiting(tx, name, about)
      |> store_text
    }),
  )
  use ids <- result.try(
    transaction(target, fn(tx) {
      target.adapter.inspect.occurrences(tx, name)
      |> store_text
    }),
  )
  use Nil <- result.try(expect(
    held == []
      && head == None
      && !list.contains(waiting, lock)
      && !list.contains(ids, lock),
    "the subject lock's id is visible: "
      <> string.inspect(#(held, head, waiting, ids)),
  ))
  invariants(target, [desk])
}

/// One admission: open the transaction, meet the barrier on the first
/// try, then `happened` and `expect`. Returns the keys `happened`
/// reported as superseded before they began. `Contended` is tried again,
/// at most 20 times.
fn admit(
  target: Target(tx),
  desk: Desk(String, tx),
  about: Subject,
  key: String,
  barrier: Option(process.Subject(process.Subject(Nil))),
  tries: Int,
) -> Result(List(String), String) {
  let attempt =
    within(target, fn(tx) {
      case barrier {
        Some(arrived) -> {
          let go = process.new_subject()
          process.send(arrived, go)
          let _ = process.receive(go, 60_000)
          Nil
        }
        None -> Nil
      }
      use done <- result.try(decisions.happened(desk, tx, "superseded", about:))
      use Nil <- result.try(decisions.expect(
        desk,
        tx,
        key:,
        trigger: Trigger("stress", key),
        about:,
      ))
      Ok(done.not_begun)
    })
  case attempt {
    Ok(not_begun) -> Ok(not_begun)
    Error(Refused(decisions.StoreFailed(store.Contended(_)))) if tries < 20 ->
      admit(target, desk, about, key, None, tries + 1)
    Error(other) -> Error(key <> ": an admission failed: " <> said(other))
  }
}

// -- One key --------------------------------------------------------------------------------

fn one_key(target: Target(tx), _load: Load) -> Result(Nil, String) {
  let desk = desk(target, point(unique(target, "auto"), None), proceeding())
  let key = unique(target, "trigger")
  let results =
    race(numbers(1, 32), fn(_) {
      within(target, recommend(
        desk,
        _,
        key,
        about: ana,
        output: "done",
        by: Rules("rules", "1"),
        score: 1.0,
      ))
      |> result.map(fn(found) { found.id })
    })
  use ids <- result.try(result.all(results) |> result.map_error(said))
  use rows <- result.try(effects(target, desk))
  use found <- result.try(
    transaction(target, fn(tx) {
      target.adapter.inspect.occurrences(
        tx,
        decisions.name(decisions.point_of(desk)),
      )
      |> store_text
    }),
  )
  use Nil <- result.try(expect(
    list.unique(ids) == [key],
    "the deliveries saw " <> string.inspect(list.unique(ids)),
  ))
  use Nil <- result.try(expect(
    found == [key],
    "the store holds " <> string.inspect(found),
  ))
  use Nil <- result.try(expect(
    list.length(rows) == 1,
    int.to_string(list.length(rows)) <> " effects",
  ))
  invariants(target, [desk])
}

// -- The contract's multi-process clauses ------------------------------------------------------

/// What the second transaction of `wall_clock` reports.
type Clocked {
  Waiting
  Locked(at: timestamp.Timestamp)
}

type Step {
  Holding
  Trying
  Loaded(entries: Int, at: Int)
  Ended(Result(Nil, String))
}

/// A transaction in another process that runs `body`, says it holds, and
/// waits for `go` before it ends with what `body` returned.
fn holder(
  target: Target(tx),
  steps: process.Subject(Step),
  body: fn(tx) -> Result(Nil, String),
) -> #(Pid, process.Subject(Nil)) {
  let gate = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let go = process.new_subject()
      process.send(gate, go)
      let ended =
        transaction(target, fn(tx) {
          use Nil <- result.try(body(tx))
          process.send(steps, Holding)
          let _ = process.receive(go, 60_000)
          Ok(Nil)
        })
      process.send(steps, Ended(ended))
    })
  let assert Ok(go) = process.receive(gate, 5000)
  #(pid, go)
}

fn waits(target: Target(tx), existing: Bool) -> Result(Nil, String) {
  let desk =
    desk(target, point(unique(target, "lock"), None), asking("finance"))
  let name = decisions.name(decisions.point_of(desk))
  let id = unique(target, "lock")
  let first = stored_entry(1, "recommended")
  use Nil <- result.try(
    transaction(target, fn(tx) {
      case existing {
        True -> append(target, tx, id, name, [first])
        False -> Ok(Nil)
      }
    }),
  )
  let steps = process.new_subject()
  let #(_, go) =
    holder(target, steps, fn(tx) {
      use found <- result.try(target.adapter.port.load(tx, id) |> store_text)
      append(target, tx, id, name, [
        stored_entry(list.length(found) + 1, "opened"),
      ])
    })
  use Nil <- result.try(case process.receive(steps, 5000) {
    Ok(Holding) -> Ok(Nil)
    other ->
      Error("the first transaction did not hold: " <> string.inspect(other))
  })
  let second = process.new_subject()
  process.spawn_unlinked(fn() {
    let loaded =
      transaction(target, fn(tx) {
        process.send(second, Trying)
        use found <- result.try(target.adapter.port.load(tx, id) |> store_text)
        process.send(second, Loaded(list.length(found), at: monotonic_us()))
        Ok(Nil)
      })
    process.send(second, Ended(loaded))
  })
  // Seen positively: the second transaction asked for the id, and its load
  // returned only after the first was let go.
  use Nil <- result.try(expect(
    process.receive(second, 5000) == Ok(Trying),
    "the second transaction did not start",
  ))
  process.sleep(50)
  let released_at = monotonic_us()
  process.send(go, Nil)
  let expected = case existing {
    True -> 2
    False -> 1
  }
  use Nil <- result.try(case process.receive(second, 5000) {
    Ok(Loaded(n, at:)) if n == expected && at >= released_at -> Ok(Nil)
    Ok(Loaded(_, at:)) if at < released_at ->
      Error("a second transaction loaded the id while the first held it")
    other ->
      Error(
        "after the first committed, the second saw " <> string.inspect(other),
      )
  })
  expect(
    process.receive(steps, 5000) == Ok(Ended(Ok(Nil))),
    "the first transaction did not commit",
  )
}

fn absent_waits(target: Target(tx), _load: Load) -> Result(Nil, String) {
  waits(target, False)
}

fn present_waits(target: Target(tx), _load: Load) -> Result(Nil, String) {
  waits(target, True)
}

fn stored_entry(seq: Int, kind: String) -> Stored {
  store.Stored(
    seq:,
    at: wire.from_milliseconds(1_800_000_000_000 + seq * 1000),
    kind:,
    event: "{\"seq\":" <> int.to_string(seq) <> "}",
  )
}

fn head(target: Target(tx), name: String, status: store.Status) -> store.Head {
  store.Head(
    point: name,
    subject: ana,
    status:,
    awaiting: [],
    due: None,
    arrived: target.backlog.now(),
    approved: [],
    may_not_decide: [],
    review_pending: False,
    bundle: None,
  )
}

fn append(
  target: Target(tx),
  tx: tx,
  id: String,
  name: String,
  entries: List(Stored),
) -> Result(Nil, String) {
  target.adapter.port.append(
    tx,
    id,
    head(target, name, store.Recommended),
    entries,
  )
  |> store_text
}

/// Everything one transaction writes about `id`: entries, a head, a
/// wake-up, a settlement notice and an application row.
fn write_everything(
  target: Target(tx),
  tx: tx,
  id: String,
  name: String,
) -> Result(Nil, String) {
  let port = target.adapter.port
  use Nil <- result.try(
    append(target, tx, id, name, [stored_entry(1, "recommended")]),
  )
  use Nil <- result.try(
    port.schedule(tx, name, id, [target.backlog.now()]) |> store_text,
  )
  use Nil <- result.try(port.settled(tx, name, id) |> store_text)
  use Nil <- result.try(target.add(tx, name, id))
  target.add(tx, name, id <> "-second")
}

/// Whether anything of `id` is visible to another transaction.
fn traces(
  target: Target(tx),
  id: String,
  name: String,
) -> Result(List(String), String) {
  use handle <- transaction(target)
  let inspect = target.adapter.inspect
  use head <- result.try(inspect.head(handle, id) |> store_text)
  use wakes <- result.try(inspect.wakes(handle) |> store_text)
  use notices <- result.try(inspect.notices(handle) |> store_text)
  use waiting <- result.try(
    target.adapter.port.waiting(handle, name, ana) |> store_text,
  )
  use rows <- result.try(target.rows(handle, name))
  Ok(
    list.flatten([
      case head {
        Some(_) -> ["head"]
        None -> []
      },
      case list.any(wakes, fn(wake) { wake.occurrence == id }) {
        True -> ["wake-up"]
        False -> []
      },
      case list.any(notices, fn(notice) { notice.occurrence == id }) {
        True -> ["notice"]
        False -> []
      },
      case list.contains(waiting, id) {
        True -> ["waiting"]
        False -> []
      },
      case rows {
        [] -> []
        _ -> ["row"]
      },
    ]),
  )
}

fn uncommitted_invisible(
  target: Target(tx),
  _load: Load,
) -> Result(Nil, String) {
  let name = unique(target, "hidden")
  let id = unique(target, "hidden")
  let steps = process.new_subject()
  let #(_, go) = holder(target, steps, write_everything(target, _, id, name))
  use Nil <- result.try(expect(
    process.receive(steps, 5000) == Ok(Holding),
    "the writer did not hold",
  ))
  use seen <- result.try(traces(target, id, name))
  use Nil <- result.try(expect(
    seen == [],
    "uncommitted, another transaction saw: " <> string.join(seen, ", "),
  ))
  // A reader races the commit: one read of a table the commit writes two
  // rows to sees none of them or both, never one.
  let observed = process.new_subject()
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let stop = process.new_subject()
    process.send(ready, stop)
    observe_rows(target, name, stop, observed, [])
  })
  use stop <- result.try(
    process.receive(ready, 5000)
    |> result.replace_error("the reader did not start"),
  )
  process.sleep(5)
  process.send(go, Nil)
  use Nil <- result.try(expect(
    process.receive(steps, 5000) == Ok(Ended(Ok(Nil))),
    "the writer did not commit",
  ))
  process.send(stop, Nil)
  use counts <- result.try(
    process.receive(observed, 5000)
    |> result.replace_error("the reader did not report"),
  )
  use Nil <- result.try(expect(
    list.all(counts, fn(count) { count == 0 || count == 2 }),
    "a reader saw a commit in part: " <> string.inspect(list.unique(counts)),
  ))
  use Nil <- result.try(expect(
    list.contains(counts, 2),
    "the reader never saw the commit",
  ))
  use seen <- result.try(traces(target, id, name))
  expect(
    list.length(seen) == 5,
    "committed, another transaction saw only: " <> string.join(seen, ", "),
  )
}

fn observe_rows(
  target: Target(tx),
  table: String,
  stop: process.Subject(Nil),
  observed: process.Subject(List(Int)),
  counts: List(Int),
) -> Nil {
  let count =
    transaction(target, target.rows(_, table))
    |> result.map(list.length)
    |> result.unwrap(-1)
  case process.receive(stop, 0) {
    // Told to stop after the commit: one more read, which certainly
    // started after it.
    Ok(Nil) -> {
      let last =
        transaction(target, target.rows(_, table))
        |> result.map(list.length)
        |> result.unwrap(-1)
      process.send(observed, [last, count, ..counts])
    }
    Error(Nil) -> observe_rows(target, table, stop, observed, [count, ..counts])
  }
}

/// A process opens a transaction, runs `body`, which calls `hold` where
/// the process is to be killed, and is killed there.
fn killed(
  target: Target(tx),
  body: fn(tx, String, String, fn() -> Nil) -> Result(Nil, String),
) -> Result(Nil, String) {
  let name = unique(target, "killed")
  let id = unique(target, "killed")
  let steps = process.new_subject()
  let hold = fn() {
    process.send(steps, Holding)
    process.sleep_forever()
  }
  let pid =
    process.spawn_unlinked(fn() {
      transaction(target, fn(tx) { body(tx, id, name, hold) })
    })
  use Nil <- result.try(expect(
    process.receive(steps, 5000) == Ok(Holding),
    "the victim did not hold",
  ))
  let monitor = process.monitor(pid)
  process.kill(pid)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(5000)
  use seen <- result.try(traces(target, id, name))
  use Nil <- result.try(expect(
    seen == [],
    "after the kill, the store kept: " <> string.join(seen, ", "),
  ))
  // The lock died with the process: a load returns at once.
  let loaded = process.new_subject()
  process.spawn_unlinked(fn() { process.send(loaded, load_entries(target, id)) })
  case process.receive(loaded, 2000) {
    Ok(Ok([])) -> Ok(Nil)
    Ok(other) ->
      Error("a load after the kill returned " <> string.inspect(other))
    Error(Nil) -> Error("the killed process's lock was not released")
  }
}

fn killed_in_tx(target: Target(tx), _load: Load) -> Result(Nil, String) {
  killed(target, fn(tx, id, name, hold) {
    use Nil <- result.try(write_everything(target, tx, id, name))
    Ok(hold())
  })
}

fn killed_in_savepoint(target: Target(tx), _load: Load) -> Result(Nil, String) {
  killed(target, fn(tx, id, name, hold) {
    target.adapter.port.atomically(tx, fn(tx) {
      case write_everything(target, tx, id, name) {
        Ok(Nil) -> Ok(hold()) |> result.replace([])
        Error(reason) -> Error(vocabulary.Unsure(reason))
      }
    })
    |> store_text
    |> result.try(fn(inner) {
      result.replace(inner, Nil) |> result.map_error(fn(stop) { stop.reason })
    })
  })
}

fn no_deadlock(target: Target(tx), _load: Load) -> Result(Nil, String) {
  let desk =
    desk(target, point(unique(target, "busy"), None), asking("finance"))
  let keys =
    list.map(numbers(1, 40), fn(n) {
      unique(target, "busy-" <> int.to_string(n))
    })
  use Nil <- result.try(
    within(target, fn(tx) {
      list.try_each(keys, fn(key) {
        recommend(
          desk,
          tx,
          key,
          about: ana,
          output: "x",
          by: Rules("rules", "1"),
          score: 0.5,
        )
        |> result.replace(Nil)
      })
    })
    |> result.map_error(said),
  )
  let results =
    race(numbers(1, 30), fn(n) {
      case n % 6 {
        0 ->
          within(target, decisions.happened(desk, _, "superseded", about: ana))
          |> result.replace(Nil)
        1 ->
          within(target, recommend(
            desk,
            _,
            unique(target, "late"),
            about: ana,
            output: "y",
            by: Rules("rules", "1"),
            score: 0.5,
          ))
          |> result.replace(Nil)
        _ -> {
          let assert [key, ..] = list.shuffle(keys)
          within(target, open_and_decide(
            desk,
            _,
            key,
            Validator("v" <> int.to_string(n), ["finance"]),
            Approve,
          ))
          |> result.replace(Nil)
        }
      }
    })
  use Nil <- result.try(
    list.try_each(results, fn(outcome) {
      case outcome {
        Error(StoreSaid(reason)) -> Error("the store said " <> reason)
        Error(Refused(decisions.StoreFailed(error))) ->
          Error("a verb failed: " <> store.describe(error))
        _ -> Ok(Nil)
      }
    }),
  )
  invariants(target, [desk])
}

fn survive_restart(target: Target(tx), _load: Load) -> Result(Nil, String) {
  let held =
    desk(
      target,
      point(unique(target, "kept"), Some(duration.minutes(2))),
      proceeding(),
    )
  let settled =
    desk(target, point(unique(target, "noticed"), None), proceeding())
  use Nil <- result.try(
    within(target, fn(tx) {
      use _ <- result.try(recommend(
        held,
        tx,
        unique(target, "kept"),
        about: ana,
        output: "a",
        by: Person("bia"),
        score: 1.0,
      ))
      recommend(
        settled,
        tx,
        unique(target, "noticed"),
        about: ana,
        output: "b",
        by: Rules("rules", "1"),
        score: 1.0,
      )
      |> result.replace(Nil)
    })
    |> result.map_error(said),
  )
  use wakes <- result.try(
    transaction(target, fn(tx) {
      target.adapter.inspect.wakes(tx) |> store_text
    }),
  )
  use notices <- result.try(target.backlog.undelivered(1000) |> store_text)
  // Commits in flight: four processes commit rows and report each commit
  // acknowledged, while the store restarts under them.
  let table = unique(target, "in-flight")
  let acked = process.new_subject()
  let writers =
    list.map(numbers(1, 4), fn(n) {
      process.spawn_unlinked(fn() { write_rows(target, table, n, 0, acked) })
    })
  // Restart once a commit has been acknowledged, so commits are in flight.
  use first_ack <- result.try(
    process.receive(acked, 10_000)
    |> result.replace_error("no commit was acknowledged before the restart"),
  )
  use again <- result.try(target.restart())
  list.each(writers, process.kill)
  let acknowledged = drain_strings(acked, [first_ack])
  use kept <- result.try(transaction(again, fn(tx) { again.rows(tx, table) }))
  use Nil <- result.try(expect(
    acknowledged != [],
    "no commit was acknowledged before the restart",
  ))
  use Nil <- result.try(expect(
    list.all(acknowledged, list.contains(kept, _)),
    int.to_string(
      list.count(acknowledged, fn(key) { !list.contains(kept, key) }),
    )
      <> " acknowledged commits were lost in the restart",
  ))
  use wakes_after <- result.try(
    transaction(again, fn(tx) { again.adapter.inspect.wakes(tx) |> store_text }),
  )
  use notices_after <- result.try(again.backlog.undelivered(1000) |> store_text)
  use Nil <- result.try(expect(
    wakes != [] && wakes_after == wakes,
    "wake-ups before and after: " <> string.inspect(#(wakes, wakes_after)),
  ))
  use Nil <- result.try(expect(
    notices != [] && notices_after == notices,
    "notices before and after: " <> string.inspect(#(notices, notices_after)),
  ))
  let result =
    invariants(again, [rebuilt(again, held), rebuilt(again, settled)])
  again.adapter.cleanup()
  result
}

/// A transaction that stays open sees the clock move, and so does one
/// that waited for a lock: `now` is read at the moment of the call.
fn wall_clock(target: Target(tx), _load: Load) -> Result(Nil, String) {
  let port = target.adapter.port
  let id = unique(target, "clock")
  let readings = process.new_subject()
  let steps = process.new_subject()
  let #(_, go) =
    holder(target, steps, fn(tx) {
      use _ <- result.try(port.load(tx, id) |> store_text)
      use first <- result.try(port.now(tx) |> store_text)
      process.sleep(30)
      use second <- result.try(port.now(tx) |> store_text)
      process.send(readings, #(first, second))
      Ok(Nil)
    })
  use Nil <- result.try(expect(
    process.receive(steps, 5000) == Ok(Holding),
    "the first transaction did not hold",
  ))
  use #(first, second) <- result.try(
    process.receive(readings, 0) |> result.replace_error("no readings"),
  )
  use Nil <- result.try(expect(
    elapsed(first, second) >= 20,
    "an open transaction read the clock 30 ms apart and saw "
      <> int.to_string(elapsed(first, second))
      <> " ms pass",
  ))
  // A second transaction starts now, waits for the lock, and reads the
  // clock after it got the lock: later than when it started.
  let waited = process.new_subject()
  process.spawn_unlinked(fn() {
    let _ =
      transaction(target, fn(tx) {
        process.send(waited, Waiting)
        use _ <- result.try(port.load(tx, id) |> store_text)
        use now <- result.try(port.now(tx) |> store_text)
        process.send(waited, Locked(now))
        Ok(Nil)
      })
  })
  use Nil <- result.try(expect(
    process.receive(waited, 5000) == Ok(Waiting),
    "the second transaction did not start",
  ))
  // The holder is let go at `released` on the store's clock; the second
  // transaction got the lock after that, so `now` read then is later.
  process.sleep(20)
  let released = target.backlog.now()
  process.send(go, Nil)
  use locked <- result.try(case process.receive(waited, 5000) {
    Ok(Locked(at)) -> Ok(at)
    _ -> Error("the second transaction did not get the lock")
  })
  use Nil <- result.try(expect(
    process.receive(steps, 5000) == Ok(Ended(Ok(Nil))),
    "the first transaction did not commit",
  ))
  expect(
    timestamp.compare(locked, released) != order.Lt,
    "a transaction that got its lock after "
      <> string.inspect(released)
      <> " read the clock as "
      <> string.inspect(locked),
  )
}

fn elapsed(from: timestamp.Timestamp, to: timestamp.Timestamp) -> Int {
  timestamp.difference(from, to) |> duration.to_milliseconds
}

/// A delivery takes a wake-up and holds its transaction open while
/// another transaction schedules the occurrence's wake-ups again: the
/// delivered one stays delivered, and only the new ones are pending.
fn delivered_alone(target: Target(tx), _load: Load) -> Result(Nil, String) {
  let port = target.adapter.port
  let name = unique(target, "delivered")
  let id = unique(target, "delivered")
  let at = fn(seconds) {
    timestamp.add(target.backlog.now(), duration.seconds(seconds))
    |> wire.milliseconds
    |> wire.from_milliseconds
  }
  let first = at(-1)
  let later = at(60)
  let latest = at(120)
  use Nil <- result.try(
    transaction(target, fn(tx) {
      port.schedule(tx, name, id, [first]) |> store_text
    }),
  )
  let wake = store.Wake(point: name, occurrence: id, at: first)
  let steps = process.new_subject()
  let #(_, go) =
    holder(target, steps, fn(tx) {
      use taken <- result.try(target.backlog.take_wake(tx, wake) |> store_text)
      expect(taken, "the delivery did not find the wake-up")
    })
  use Nil <- result.try(expect(
    process.receive(steps, 5000) == Ok(Holding),
    "the delivery did not hold",
  ))
  let scheduled = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(
      scheduled,
      transaction(target, fn(tx) {
        port.schedule(tx, name, id, [first, later]) |> store_text
      }),
    )
  })
  process.sleep(30)
  process.send(go, Nil)
  use Nil <- result.try(expect(
    process.receive(steps, 5000) == Ok(Ended(Ok(Nil))),
    "the delivery did not commit",
  ))
  use Nil <- result.try(
    process.receive(scheduled, 5000)
    |> result.replace_error("schedule did not return")
    |> result.flatten,
  )
  let pending = fn() {
    transaction(target, fn(tx) {
      target.adapter.inspect.wakes(tx) |> store_text
    })
    |> result.map(fn(wakes) {
      list.filter_map(wakes, fn(wake) {
        case wake.occurrence == id {
          True -> Ok(wake.at)
          False -> Error(Nil)
        }
      })
      |> list.sort(timestamp.compare)
    })
  }
  use now <- result.try(pending())
  use Nil <- result.try(expect(
    now == [first, later],
    "after the schedule, pending: " <> string.inspect(now),
  ))
  // A wake-up delivered and committed is not brought back by a schedule
  // that replaces the others.
  use taken <- result.try(
    transaction(target, fn(tx) {
      target.backlog.take_wake(tx, wake)
      |> store_text
      |> result.try(expect(_, "the wake-up was gone"))
    })
    |> result.replace(True),
  )
  use Nil <- result.try(
    transaction(target, fn(tx) {
      port.schedule(tx, name, id, [later, latest])
      |> store_text
    }),
  )
  use now <- result.try(pending())
  use Nil <- result.try(expect(
    taken && now == [later, latest],
    "after the second schedule, pending: " <> string.inspect(now),
  ))
  use again <- result.try(
    transaction(target, fn(tx) {
      target.backlog.take_wake(tx, wake)
      |> store_text
      |> result.try(fn(found) {
        expect(!found, "a delivered wake-up came back")
      })
    })
    |> result.replace(True),
  )
  expect(again, "")
}

fn write_rows(
  target: Target(tx),
  table: String,
  writer: Int,
  n: Int,
  acked: process.Subject(String),
) -> Nil {
  let key = int.to_string(writer) <> "-" <> int.to_string(n)
  case transaction(target, fn(tx) { target.add(tx, table, key) }) {
    Ok(Nil) -> process.send(acked, key)
    Error(_) -> Nil
  }
  write_rows(target, table, writer, n + 1, acked)
}

fn drain_strings(
  subject: process.Subject(String),
  so_far: List(String),
) -> List(String) {
  case process.receive(subject, 0) {
    Ok(value) -> drain_strings(subject, [value, ..so_far])
    Error(Nil) -> so_far
  }
}

/// The same desk over the restarted target.
fn rebuilt(target: Target(tx), old: Desk(String, tx)) -> Desk(String, tx) {
  desk(target, decisions.point_of(old), proceeding())
}

// -- The runtime ---------------------------------------------------------------------------

/// Start the runtime in a process of its own, so that killing the runtime
/// does not take the caller with it. Returns the supervisor.
fn start_runtime(config: runtime.Config(tx)) -> Result(Pid, String) {
  let reply = process.new_subject()
  process.spawn_unlinked(fn() {
    case runtime.start(config) {
      Ok(started) -> {
        process.send(reply, Ok(started.pid))
        process.sleep_forever()
      }
      Error(error) -> process.send(reply, Error(string.inspect(error)))
    }
  })
  process.receive(reply, 5000)
  |> result.unwrap(Error("the runtime did not start"))
}

/// Kill the runtime and wait until the supervisor and every child are
/// gone, so that nothing of it acts after this returns.
fn stop_runtime(supervisor: Pid) -> Nil {
  let children = list.map(runtime.children(supervisor), fn(pair) { pair.1 })
  list.each([supervisor, ..children], fn(pid) {
    let monitor = process.monitor(pid)
    process.kill(pid)
    let _ =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(_) { Nil })
      |> process.selector_receive(5000)
    Nil
  })
}

fn quick(config: runtime.Config(tx)) -> runtime.Config(tx) {
  runtime.Config(..config, poll: duration.milliseconds(5))
}

fn nothing(_submitted: Submitted) -> Result(Nil, decisions.HandlerFailure) {
  Ok(Nil)
}

/// Count one more attempt at `key`, in a transaction of its own, and
/// return how many there have been.
fn attempt(target: Target(tx), key: String) -> Int {
  let _ = transaction(target, fn(tx) { target.add(tx, "attempts", key) })
  transaction(target, target.rows(_, "attempts"))
  |> result.unwrap([])
  |> list.count(fn(row) { row == key })
}

fn b1(target: Target(tx), _load: Load) -> Result(Nil, String) {
  let desk = desk(target, point(unique(target, "auto"), None), proceeding())
  let keys =
    list.map(numbers(1, 20), fn(n) { unique(target, "t-" <> int.to_string(n)) })
  let assert [_, _, _, _, _, _, in_model, _, after_commit, ..] = keys
  let work = fn(submitted: Submitted) {
    let nth = attempt(target, submitted.key)
    // The model: slow enough to be killed in.
    process.sleep(3)
    case submitted.payload, nth {
      "dies_in_model", 1 -> kill_here(at: DuringModel)
      _, _ -> Nil
    }
    let recommended =
      within(target, recommend(
        desk,
        _,
        submitted.key,
        about: ana,
        output: "done",
        by: Rules("rules", "1"),
        score: 1.0,
      ))
    case submitted.payload, nth {
      "dies_after_commit", 1 -> kill_here(at: AfterCommitBeforeAck)
      _, _ -> Nil
    }
    recommended
    |> result.replace(Nil)
    |> result.map_error(fn(e) { decisions.ApplicationFailed(said(e)) })
  }
  use Nil <- result.try(
    transaction(target, fn(tx) {
      list.try_each(keys, fn(key) {
        target.backlog.submit(tx, key, case key {
          _ if key == in_model -> "dies_in_model"
          _ if key == after_commit -> "dies_after_commit"
          _ -> "ordinary"
        })
        |> store_text
      })
    }),
  )
  let config =
    runtime.config(
      target.backlog,
      points: [runtime.point(desk, settled: runtime.nothing_follows)],
      work:,
    )
    |> quick
  // A worker reports each trigger it finished.
  let worked = process.new_subject()
  let attachment =
    sinal.observe(telemetry.trigger_worked(), fn(_, about) {
      process.send(worked, about.occurrence)
    })
  use tree <- result.try(start_runtime(runtime.Config(..config, workers: 4)))
  let name = decisions.name(decisions.point_of(desk))
  let done = all_worked(worked, keys, 20_000)
  stop_runtime(tree)
  let _ = sinal.detach(attachment)
  use Nil <- result.try(expect(done, "the triggers were not all worked"))
  use ids <- result.try(
    transaction(target, fn(tx) {
      target.adapter.inspect.occurrences(tx, name)
      |> store_text
    }),
  )
  use rows <- result.try(effects(target, desk))
  use aside <- result.try(target.backlog.aside() |> store_text)
  use Nil <- result.try(expect(
    list.sort(ids, string.compare) == list.sort(keys, string.compare),
    "the occurrences are " <> string.inspect(ids),
  ))
  use Nil <- result.try(expect(
    list.length(rows) == 20,
    int.to_string(list.length(rows)) <> " effects",
  ))
  use Nil <- result.try(expect(
    aside == [],
    "set aside: " <> string.inspect(aside),
  ))
  invariants(target, [desk])
}

/// Wait until every key was reported worked.
fn all_worked(
  worked: process.Subject(String),
  keys: List(String),
  ms: Int,
) -> Bool {
  case keys, ms <= 0 {
    [], _ -> True
    _, True -> False
    _, False -> {
      let started = monotonic_ms()
      case process.receive(worked, ms) {
        Ok(key) ->
          all_worked(
            worked,
            list.filter(keys, fn(k) { k != key }),
            ms - { monotonic_ms() - started },
          )
        Error(Nil) -> False
      }
    }
  }
}

fn b2(target: Target(tx), _load: Load) -> Result(Nil, String) {
  let point = point(unique(target, "invoice"), None)
  let sound = desk(target, point, asking("finance"))
  let table = decisions.name(point)
  let lethal =
    decisions.desk(
      point,
      drives: fn(_) {
        Gated(
          name: table,
          guard: fn(_, _) { Ok([]) },
          execute: fn(tx, released) {
            let _ = target.add(tx, table, decisions.key(released))
            kill_here(at: InsideVerdictAfterToolWrote)
          },
        )
      },
      under: fn(_) { Ok(asking("finance")) },
      over: target.adapter.port,
    )
  let key = unique(target, "invoice")
  use _ <- result.try(
    within(target, recommend(
      sound,
      _,
      key,
      about: clinica,
      output: "800.00",
      by: Rules("rules", "1"),
      score: 0.5,
    ))
    |> result.map_error(said),
  )
  use before <- result.try(load_entries(target, key))
  let bia = Validator("bia", ["finance"])
  let victim =
    process.spawn_unlinked(fn() {
      within(target, open_and_decide(lethal, _, key, bia, Approve))
    })
  let monitor = process.monitor(victim)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(5000)
  use rows <- result.try(effects(target, sound))
  use after <- result.try(load_entries(target, key))
  use status <- result.try(status_of(target, key))
  use Nil <- result.try(expect(
    rows == [],
    "the killed verdict left " <> string.inspect(rows),
  ))
  use Nil <- result.try(expect(
    after == before,
    "the killed verdict changed the record",
  ))
  use Nil <- result.try(expect(
    status == "awaiting",
    "the occurrence is " <> status,
  ))
  use released <- result.try(
    within(target, open_and_decide(sound, _, key, bia, Approve))
    |> result.map_error(said),
  )
  use Nil <- result.try(case released.status {
    occurrence.Released(..) -> Ok(Nil)
    other -> Error("the second verdict ended " <> occurrence.status_name(other))
  })
  use rows <- result.try(effects(target, sound))
  use Nil <- result.try(expect(
    list.length(rows) == 1,
    int.to_string(list.length(rows)) <> " invoices",
  ))
  invariants(target, [sound])
}

fn b4(target: Target(tx), load: Load) -> Result(Nil, String) {
  let replies =
    desk(
      target,
      point(unique(target, "reply"), Some(duration.minutes(2))),
      proceeding(),
    )
  let refunds =
    desk(target, point(unique(target, "refund"), None), asking("finance"))
  let config =
    runtime.config(
      target.backlog,
      points: [
        runtime.point(replies, settled: runtime.nothing_follows),
        runtime.point(refunds, settled: runtime.nothing_follows),
      ],
      work: nothing,
    )
    |> quick
  use first <- result.try(start_runtime(config))
  use Nil <- result.try(
    within(target, fn(tx) {
      use Nil <- result.try(
        list.try_each(numbers(1, load.b4_holds), fn(n) {
          recommend(
            replies,
            tx,
            unique(target, "reply-" <> int.to_string(n)),
            about: ana,
            output: "Olá",
            by: Person("bia"),
            score: 1.0,
          )
          |> result.replace(Nil)
        }),
      )
      list.try_each(numbers(1, 50), fn(n) {
        recommend(
          refunds,
          tx,
          unique(target, "refund-" <> int.to_string(n)),
          about: clinica,
          output: "80.00",
          by: Rules("rules", "1"),
          score: 0.5,
        )
        |> result.replace(Nil)
      })
    })
    |> result.map_error(said),
  )
  // The node stops. Time passes with nobody to deliver anything.
  stop_runtime(first)
  target.advance(duration.minutes(3))
  process.sleep(20)
  use rows <- result.try(effects(target, replies))
  use Nil <- result.try(expect(rows == [], "replies were sent with no runtime"))
  use second <- result.try(start_runtime(config))
  let all_sent =
    wait_until(
      fn() {
        case effects(target, replies), target.backlog.undelivered(10) {
          Ok(rows), Ok([]) -> list.length(rows) == load.b4_holds
          _, _ -> False
        }
      },
      within: 20_000,
    )
  stop_runtime(second)
  use rows <- result.try(effects(target, replies))
  use waiting <- result.try(
    transaction(target, fn(tx) {
      target.adapter.port.waiting(
        tx,
        decisions.name(decisions.point_of(refunds)),
        clinica,
      )
      |> store_text
    }),
  )
  use Nil <- result.try(expect(
    all_sent,
    int.to_string(list.length(rows)) <> " replies sent after the restart",
  ))
  use Nil <- result.try(expect(
    list.length(list.unique(rows)) == load.b4_holds,
    "a reply was sent twice",
  ))
  use Nil <- result.try(expect(
    list.length(waiting) == 50,
    int.to_string(list.length(waiting)) <> " refunds wait",
  ))
  invariants(target, [replies, refunds])
}

/// Four keys expected with one deadline of their own (`expect_until`): one
/// whose model keeps failing, one recommended and waiting for a verdict,
/// one whose model answers after the deadline but before any wake-up is
/// delivered, and one whose model answers only after its wake-up expired
/// it. The store restarts before the deadline, time passes it, and the
/// runtime started over the restarted store expires what is still pending.
/// Both late recommendations are recorded expired, each record has one
/// settlement notice, a late failure is refused, and a verdict is refused.
fn own_deadline(target: Target(tx), _load: Load) -> Result(Nil, String) {
  let replies =
    desk(target, point(unique(target, "own-deadline"), None), asking("finance"))
  let failing = unique(target, "failing")
  let waiting = unique(target, "waiting")
  let late = unique(target, "late")
  let late_first = unique(target, "late-first")
  let deadline =
    timestamp.add(target.backlog.now(), duration.minutes(1))
    |> wire.milliseconds
    |> wire.from_milliseconds
  let expect_until = fn(desk, tx, key) {
    decisions.expect_until(
      desk,
      tx,
      key:,
      trigger: Trigger("stress", key),
      about: ana,
      valid_until: deadline,
    )
  }
  let fail = fn(desk, tx, key) {
    decisions.record_failure(
      desk,
      tx,
      key:,
      trigger: Trigger("stress", key),
      about: ana,
      failure: model.Raised("the provider is down"),
    )
  }
  use Nil <- result.try(
    within(target, fn(tx) {
      use Nil <- result.try(expect_until(replies, tx, failing))
      use Nil <- result.try(expect_until(replies, tx, waiting))
      use Nil <- result.try(expect_until(replies, tx, late))
      use Nil <- result.try(expect_until(replies, tx, late_first))
      use _ <- result.try(fail(replies, tx, failing))
      recommend(
        replies,
        tx,
        waiting,
        about: ana,
        output: "Olá",
        by: Rules("rules", "1"),
        score: 0.5,
      )
      |> result.replace(Nil)
    })
    |> result.map_error(said),
  )
  use again <- result.try(target.restart())
  let replies = rebuilt_asking(again, replies)
  again.advance(duration.minutes(2))
  // Past the deadline, before any runtime delivers a wake-up.
  use first <- result.try(
    within(again, recommend(
      replies,
      _,
      late_first,
      about: ana,
      output: "tarde",
      by: Rules("rules", "1"),
      score: 0.5,
    ))
    |> result.map_error(said),
  )
  use Nil <- result.try(expect(
    first.status == occurrence.Expired(vocabulary.DeadlinePassed)
      && first.policy_version == None
      && kinds(first) == ["expected", "expired", "recommended"],
    "the recommendation before the wake-up is " <> string.inspect(first.status),
  ))
  let config =
    runtime.config(
      again.backlog,
      points: [runtime.point(replies, settled: runtime.nothing_follows)],
      work: nothing,
    )
    |> quick
  use supervisor <- result.try(start_runtime(config))
  let status = fn(id) {
    transaction(again, fn(tx) {
      again.adapter.inspect.head(tx, id) |> store_text
    })
    |> result.map(option.map(_, fn(head: store.Head) { head.status }))
  }
  let expired =
    wait_until(
      fn() {
        list.all([failing, waiting, late, late_first], fn(id) {
          status(id) == Ok(Some(store.Expired))
        })
      },
      within: 20_000,
    )
  stop_runtime(supervisor)
  use Nil <- result.try(expect(
    expired,
    "after the deadline: "
      <> string.inspect(list.map([failing, waiting, late, late_first], status)),
  ))
  use known <- result.try(read(again, replies, waiting))
  use Nil <- result.try(expect(
    known.status == occurrence.Expired(vocabulary.DeadlinePassed)
      && known.valid_until == Some(deadline),
    "the waiting occurrence ended " <> string.inspect(known.status),
  ))
  use Nil <- result.try(
    case
      within(again, open_and_decide(
        replies,
        _,
        waiting,
        vocabulary.Validator(subject: "bia", holds: ["finance"]),
        vocabulary.Approve,
      ))
    {
      Error(Refused(decisions.NotAwaiting)) -> Ok(Nil)
      other -> Error("a verdict after the deadline: " <> string.inspect(other))
    },
  )
  use Nil <- result.try(case within(again, fail(replies, _, failing)) {
    Error(Refused(decisions.DeadlinePassedBefore(at))) if at == deadline ->
      Ok(Nil)
    other -> Error("a failure after the deadline: " <> string.inspect(other))
  })
  use recorded <- result.try(
    within(again, recommend(
      replies,
      _,
      late,
      about: ana,
      output: "tarde",
      by: Rules("rules", "1"),
      score: 0.5,
    ))
    |> result.map_error(said),
  )
  use Nil <- result.try(expect(
    recorded.status == occurrence.Expired(vocabulary.DeadlinePassed)
      && recorded.policy_version == None
      && kinds(recorded) == ["expected", "expired", "recommended"],
    "the late recommendation is " <> string.inspect(recorded.status),
  ))
  use rows <- result.try(effects(again, replies))
  use Nil <- result.try(expect(rows == [], "something was released"))
  use notices <- result.try(
    transaction(again, fn(tx) {
      again.adapter.inspect.notices(tx) |> store_text
    }),
  )
  let noticed = fn(id) {
    list.count(notices, fn(notice: store.Notice) { notice.occurrence == id })
  }
  use Nil <- result.try(expect(
    list.all([failing, waiting, late, late_first], fn(id) { noticed(id) == 1 }),
    "settlement notices: "
      <> string.inspect(
      list.map([failing, waiting, late, late_first], fn(id) {
        #(id, noticed(id))
      }),
    ),
  ))
  let result = invariants(again, [replies])
  again.adapter.cleanup()
  result
}

fn kinds(known: occurrence.Occurrence(o)) -> List(String) {
  list.map(known.entries, fn(e) { entry.kind(e.event) })
}

/// Five records about five subjects end four ways; the runtime delivers
/// their settlement notices. The follower writes one row per call in the
/// delivery's transaction, with no de-duplication, so a notice dropped or
/// delivered twice shows.
fn every_notice(target: Target(tx), _load: Load) -> Result(Nil, String) {
  let desk =
    desk(target, point(unique(target, "notices"), None), asking("finance"))
  let table = unique(target, "followed")
  let key = fn(name) { unique(target, name) }
  let #(superseded, lapsed, late, woken, rejected) = #(
    key("superseded"),
    key("lapsed"),
    key("late"),
    key("woken"),
    key("rejected"),
  )
  let about = fn(id) { Subject("person", id) }
  let deadline =
    timestamp.add(target.backlog.now(), duration.minutes(1))
    |> wire.milliseconds
    |> wire.from_milliseconds
  let expect_by = fn(tx, id) {
    decisions.expect_until(
      desk,
      tx,
      key: id,
      trigger: Trigger("stress", id),
      about: about(id),
      valid_until: deadline,
    )
  }
  use Nil <- result.try(
    within(target, fn(tx) {
      use Nil <- result.try(decisions.expect(
        desk,
        tx,
        key: superseded,
        trigger: Trigger("stress", superseded),
        about: about(superseded),
      ))
      use _ <- result.try(decisions.happened(
        desk,
        tx,
        "superseded",
        about: about(superseded),
      ))
      use Nil <- result.try(expect_by(tx, lapsed))
      use Nil <- result.try(expect_by(tx, late))
      use Nil <- result.try(expect_by(tx, woken))
      use _ <- result.try(recommend(
        desk,
        tx,
        rejected,
        about: about(rejected),
        output: "no",
        by: Rules("rules", "1"),
        score: 0.5,
      ))
      open_and_decide(
        desk,
        tx,
        rejected,
        Validator(subject: "bia", holds: ["finance"]),
        Reject(Reason("no", None)),
      )
      |> result.replace(Nil)
    })
    |> result.map_error(said),
  )
  // Past the deadline, the late key is recommended before any wake-up; the
  // woken key is expired by its wake-up first, which admits its notice
  // while it has not begun, and recommended after: its notice is read at
  // delivery, as begun.
  target.advance(duration.minutes(2))
  use _ <- result.try(
    within(target, decisions.wake(desk, _, occurrence: woken))
    |> result.map_error(said),
  )
  use _ <- result.try(
    within(target, recommend(
      desk,
      _,
      woken,
      about: about(woken),
      output: "tarde",
      by: Rules("rules", "1"),
      score: 0.5,
    ))
    |> result.map_error(said),
  )
  use _ <- result.try(
    within(target, recommend(
      desk,
      _,
      late,
      about: about(late),
      output: "tarde",
      by: Rules("rules", "1"),
      score: 0.5,
    ))
    |> result.map_error(said),
  )
  let follow = fn(tx, record: decisions.Record(String)) {
    target.add(tx, table, handed(record))
    |> result.map_error(decisions.ApplicationFailed)
  }
  let config =
    runtime.config(
      target.backlog,
      points: [runtime.point(desk, settled: follow)],
      work: nothing,
    )
    |> quick
  use supervisor <- result.try(start_runtime(config))
  let rows = fn() {
    transaction(target, target.rows(_, table)) |> result.unwrap([])
  }
  let keys = [superseded, lapsed, late, woken, rejected]
  let settled =
    wait_until(
      fn() {
        list.length(rows()) >= list.length(keys)
        || {
          // The head first: a lapse and its notice commit together, so
          // an empty backlog read after it holds no notice of the lapse.
          transaction(target, fn(tx) {
            target.adapter.inspect.head(tx, lapsed) |> store_text
          })
          |> result.map(option.map(_, fn(head: store.Head) { head.status }))
          == Ok(Some(store.Expired))
          && target.backlog.undelivered(100) == Ok([])
        }
      },
      within: 20_000,
    )
  // Let a delivery in flight finish before counting.
  process.sleep(50)
  stop_runtime(supervisor)
  let followed = rows()
  use undelivered <- result.try(target.backlog.undelivered(100) |> store_text)
  use aside <- result.try(target.backlog.aside() |> store_text)
  use Nil <- result.try(expect(
    settled,
    "the runtime did not settle its notices",
  ))
  let wanted = [
    superseded <> " not begun, superseded",
    lapsed <> " not begun, deadline passed",
    late <> " begun, expired, deadline passed",
    woken <> " begun, expired, deadline passed",
    rejected <> " begun, rejected",
  ]
  use Nil <- result.try(expect(
    list.sort(followed, string.compare) == list.sort(wanted, string.compare),
    "the follower was handed "
      <> string.inspect(followed)
      <> " where "
      <> string.inspect(wanted)
      <> " was due",
  ))
  use Nil <- result.try(expect(
    undelivered == [] && aside == [],
    "notices left: " <> string.inspect(#(undelivered, aside)),
  ))
  use notices <- result.try(
    transaction(target, fn(tx) {
      target.adapter.inspect.notices(tx) |> store_text
    }),
  )
  use Nil <- result.try(expect(
    list.all(keys, fn(id) {
      list.count(notices, fn(notice: store.Notice) { notice.occurrence == id })
      == 1
    }),
    "settlement notices: " <> string.inspect(notices),
  ))
  invariants(target, [desk])
}

/// What a follower was handed, as one line: the key, whether the record
/// had begun, and how it ended.
fn handed(record: decisions.Record(String)) -> String {
  let cause = fn(cause) {
    case cause {
      vocabulary.Superseded(_) -> "superseded"
      vocabulary.DeadlinePassed -> "deadline passed"
    }
  }
  case record {
    decisions.NotBegun(pending) ->
      pending.id
      <> " not begun, "
      <> option.map(pending.ended, cause) |> option.unwrap("not ended")
    decisions.Begun(known) ->
      known.id
      <> " begun, "
      <> occurrence.status_name(known.status)
      <> case known.status {
        occurrence.Expired(ended) -> ", " <> cause(ended)
        _ -> ""
      }
  }
}

/// The key of a record handed to a follower.
fn key_of(record: decisions.Record(o)) -> String {
  case record {
    decisions.Begun(known) -> known.id
    decisions.NotBegun(pending) -> pending.id
  }
}

/// The same asking desk over the restarted target.
fn rebuilt_asking(
  target: Target(tx),
  old: Desk(String, tx),
) -> Desk(String, tx) {
  desk(target, decisions.point_of(old), asking("finance"))
}

fn b5(target: Target(tx), load: Load) -> Result(Nil, String) {
  let automatic =
    desk(target, point(unique(target, "auto"), None), proceeding())
  let held =
    desk(
      target,
      point(unique(target, "held"), Some(duration.milliseconds(30))),
      proceeding(),
    )
  let asked =
    desk(target, point(unique(target, "asked"), None), asking("support"))
  let slow =
    model.new(fn(_, _) {
      process.sleep(2 + int.random(8))
      Ok(
        Recommendation(
          output: "done",
          by: Rules("rules", "1"),
          explanation: RuleFired("stress"),
          signals: [fact.set(score(), 1.0)],
          reads: [],
        ),
      )
    })
    |> isolated.model(within: duration.seconds(2), heap: stress_heap())
  let work = fn(submitted: Submitted) {
    let chosen = case submitted.payload {
      "auto" -> automatic
      "held" -> held
      _ -> asked
    }
    isolated.recommend(
      chosen,
      in: within_attempted(target, _),
      request: isolated.Request(
        source: "stress",
        key: submitted.key,
        trigger: Trigger("stress", submitted.key),
        about: ana,
        context: Manifest(refs: [], renderer: "stress-1"),
        sources: model.recorded(context: [], reads: []),
      ),
      model: slow,
    )
    |> result.map_error(decisions.DeskRefused)
    |> result.try(fn(attempted) {
      case attempted {
        isolated.Recommended(_)
        | isolated.Skipped(_)
        | isolated.Superseded(_)
        | isolated.Lapsed(_) -> Ok(Nil)
        isolated.Failed(failure:, ..) ->
          Error(decisions.ApplicationFailed(model.describe(failure)))
      }
    })
  }
  // What follows a settlement: one row per occurrence, written in the
  // delivery's own transaction.
  let follow = fn(tx, record: decisions.Record(String)) {
    let id = key_of(record)
    {
      use rows <- result.try(target.rows(tx, "followed"))
      case list.contains(rows, id) {
        True -> Ok(Nil)
        False -> target.add(tx, "followed", id)
      }
    }
    |> result.map_error(decisions.ApplicationFailed)
  }
  let triggers = load.b5_triggers
  let prefix = unique(target, "c")
  let submit = fn(batch: List(Int)) {
    transaction(target, fn(tx) {
      list.try_each(batch, fn(n) {
        target.backlog.submit(
          tx,
          prefix <> "-" <> int.to_string(n),
          case n % 3 {
            0 -> "auto"
            1 -> "held"
            _ -> "ask"
          },
        )
        |> store_text
      })
    })
  }
  let config =
    runtime.Config(
      ..runtime.config(
        target.backlog,
        points: [
          runtime.point(automatic, settled: follow),
          runtime.point(held, settled: follow),
          runtime.point(asked, settled: follow),
        ],
        work:,
      ),
      workers: 8,
    )
    |> quick
  use tree <- result.try(start_runtime(config))
  let asked_name = decisions.name(decisions.point_of(asked))
  let validators =
    list.map(numbers(1, 4), fn(n) {
      process.spawn_unlinked(fn() {
        validate(
          target,
          asked,
          asked_name,
          Validator("v" <> int.to_string(n), ["support"]),
        )
      })
    })
  // Time passes, so holds end.
  let clock = process.spawn_unlinked(fn() { tick(target) })
  let kills = process.new_subject()
  let chaos = process.spawn_unlinked(fn() { kill_one(tree, kills) })
  // The triggers arrive in six waves, and each wave after the first waits
  // for a kill, so at least five children die while occurrences move,
  // however fast the store is.
  let waves =
    list.sized_chunk(numbers(1, triggers), int.max(1, { triggers + 5 } / 6))
  use killed_while_feeding <- result.try(
    list.index_map(waves, fn(wave, index) { #(index, wave) })
    |> list.try_fold(0, fn(killed, pair) {
      let #(index, wave) = pair
      use killed <- result.try(case index {
        0 -> Ok(killed)
        _ -> await_kill(kills) |> result.replace(killed + 1)
      })
      submit(wave) |> result.replace(killed)
    }),
  )
  // A load too small for six waves still waits for five kills.
  use killed_while_feeding <- result.try(
    list.try_fold(
      numbers(killed_while_feeding + 1, 5),
      killed_while_feeding,
      fn(killed, _) { await_kill(kills) |> result.replace(killed + 1) },
    ),
  )
  let settled =
    wait_until(
      fn() {
        case transaction(target, target.rows(_, "followed")) {
          Ok(rows) -> list.length(rows) == triggers
          Error(_) -> False
        }
      },
      within: 60_000,
    )
  process.kill(chaos)
  list.each(validators, process.kill)
  process.kill(clock)
  process.sleep(20)
  stop_runtime(tree)
  let killed = killed_while_feeding + drain(kills, 0)
  use followed <- result.try(
    transaction(target, fn(tx) { target.rows(tx, "followed") }),
  )
  use aside <- result.try(target.backlog.aside() |> store_text)
  use auto_rows <- result.try(effects(target, automatic))
  use held_rows <- result.try(effects(target, held))
  use asked_rows <- result.try(effects(target, asked))
  use Nil <- result.try(expect(
    settled,
    int.to_string(list.length(followed))
      <> " of "
      <> int.to_string(triggers)
      <> " settled",
  ))
  use Nil <- result.try(expect(
    killed >= 5,
    "only " <> int.to_string(killed) <> " children were killed",
  ))
  use Nil <- result.try(expect(
    aside == [],
    "set aside: " <> string.inspect(aside),
  ))
  use Nil <- result.try(expect(
    list.length(auto_rows) == triggers / 3
      && list.length(held_rows) == { triggers + 2 } / 3
      && list.length(asked_rows) == { triggers + 1 } / 3,
    "effects "
      <> string.inspect(#(
      list.length(auto_rows),
      list.length(held_rows),
      list.length(asked_rows),
    )),
  ))
  invariants(target, [automatic, held, asked])
}

fn await_kill(kills: process.Subject(Nil)) -> Result(Nil, String) {
  process.receive(kills, 10_000)
  |> result.replace_error("no child of the runtime was killed within 10 s")
}

fn within_attempted(
  target: Target(tx),
  body: fn(tx) -> Result(isolated.Attempted(String), Refusal),
) -> Result(isolated.Attempted(String), Refusal) {
  case within(target, body) {
    Ok(value) -> Ok(value)
    Error(Refused(refusal)) -> Error(refusal)
    Error(StoreSaid(reason)) ->
      Error(decisions.StoreFailed(store.Unavailable(reason)))
  }
}

fn validate(
  target: Target(tx),
  desk: Desk(String, tx),
  name: String,
  validator: vocabulary.Validator,
) -> Nil {
  case
    transaction(target, fn(tx) {
      target.adapter.port.waiting(tx, name, ana) |> store_text
    })
  {
    Ok([_, ..] as waiting) -> {
      let assert [id, ..] = list.shuffle(waiting)
      let _ = within(target, open_and_decide(desk, _, id, validator, Approve))
      Nil
    }
    _ -> process.sleep(3)
  }
  validate(target, desk, name, validator)
}

fn tick(target: Target(tx)) -> Nil {
  process.sleep(10)
  target.advance(duration.milliseconds(30))
  tick(target)
}

fn kill_one(tree: Pid, kills: process.Subject(Nil)) -> Nil {
  process.sleep(50)
  case list.shuffle(runtime.children(tree)) {
    [#(_, child), ..] -> {
      process.kill(child)
      process.send(kills, Nil)
    }
    [] -> Nil
  }
  kill_one(tree, kills)
}

fn drain(subject: process.Subject(Nil), count: Int) -> Int {
  case process.receive(subject, 0) {
    Ok(Nil) -> drain(subject, count + 1)
    Error(Nil) -> count
  }
}

fn b6(target: Target(tx), _load: Load) -> Result(Nil, String) {
  let healthy =
    desk(
      target,
      point(unique(target, "reply"), Some(duration.minutes(1))),
      proceeding(),
    )
  let poisoned_point = unique(target, "poisoned")
  let poisoned =
    desk(target, point(poisoned_point, Some(duration.minutes(1))), proceeding())
  let failing =
    desk(target, point(unique(target, "failing"), None), proceeding())
  let keys = [unique(target, "a"), unique(target, "b")]
  let bad = unique(target, "bad")
  let doomed = unique(target, "doomed")
  use Nil <- result.try(
    within(target, fn(tx) {
      use Nil <- result.try(
        list.try_each(keys, fn(key) {
          recommend(
            healthy,
            tx,
            key,
            about: ana,
            output: "Olá",
            by: Person("bia"),
            score: 1.0,
          )
          |> result.replace(Nil)
        }),
      )
      use _ <- result.try(recommend(
        poisoned,
        tx,
        bad,
        about: ana,
        output: "Olá",
        by: Person("bia"),
        score: 1.0,
      ))
      recommend(
        failing,
        tx,
        unique(target, "f"),
        about: ana,
        output: "x",
        by: Rules("rules", "1"),
        score: 1.0,
      )
      |> result.replace(Nil)
    })
    |> result.map_error(said),
  )
  use Nil <- result.try(
    transaction(target, fn(tx) {
      target.backlog.submit(tx, doomed, "") |> store_text
    }),
  )
  use Nil <- result.try(target.poison(bad))
  // The bad record is visible as what it is: a typed refusal, not a crash.
  use Nil <- result.try(
    transaction(target, fn(tx) {
      case decisions.read(poisoned, tx, occurrence: bad) {
        Error(decisions.Unreadable(_)) -> Ok(Nil)
        other -> Error("the poisoned record read as " <> string.inspect(other))
      }
    }),
  )
  target.advance(duration.minutes(2))
  // Three attempts, set here so the scenario does not depend on the
  // runtime's default.
  let config =
    runtime.Config(
      ..runtime.config(
        target.backlog,
        points: [
          runtime.point(healthy, settled: runtime.nothing_follows),
          runtime.point(poisoned, settled: runtime.nothing_follows),
          runtime.point(failing, settled: fn(_, _) {
            Error(decisions.ApplicationFailed("what follows always fails"))
          }),
        ],
        work: fn(_) {
          Error(decisions.ApplicationFailed("this trigger always fails"))
        },
      ),
      attempts: 3,
    )
    |> quick
  use tree <- result.try(start_runtime(config))
  let done =
    wait_until(
      fn() {
        case effects(target, healthy), target.backlog.aside() {
          Ok(rows), Ok(aside) ->
            list.length(rows) == 2 && list.length(aside) == 3
          _, _ -> False
        }
      },
      within: 20_000,
    )
  stop_runtime(tree)
  use aside <- result.try(target.backlog.aside() |> store_text)
  use Nil <- result.try(expect(done, "set aside: " <> string.inspect(aside)))
  let kinds =
    list.map(aside, fn(entry) {
      case entry.job {
        backlog.WakeJob(wake) if wake.occurrence == bad -> "poisoned wake-up"
        backlog.NoticeJob(_) -> "failing notice"
        backlog.TriggerJob(submitted) if submitted.key == doomed ->
          "failing trigger"
        _ -> "something else"
      }
    })
    |> list.sort(string.compare)
  use Nil <- result.try(expect(
    kinds == ["failing notice", "failing trigger", "poisoned wake-up"],
    "set aside: " <> string.inspect(kinds),
  ))
  // A record that does not decode is set aside at once; a handler that
  // keeps failing, after three attempts.
  let attempts =
    list.map(aside, fn(entry) {
      case entry.job {
        backlog.WakeJob(_) -> #("wake-up", entry.attempts)
        backlog.NoticeJob(_) -> #("notice", entry.attempts)
        backlog.TriggerJob(_) -> #("trigger", entry.attempts)
      }
    })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  use Nil <- result.try(expect(
    attempts == [#("notice", 3), #("trigger", 3), #("wake-up", 0)],
    "attempts: " <> string.inspect(attempts),
  ))
  // The record that does not decode is set aside with its wake-up: it no
  // longer waits, so no supersession and no queue meets it again.
  use still <- result.try(
    transaction(target, fn(tx) {
      target.adapter.port.waiting(tx, poisoned_point, ana) |> store_text
    }),
  )
  use Nil <- result.try(expect(
    !list.contains(still, bad),
    "the poisoned record still waits: " <> string.inspect(still),
  ))
  invariants(target, [healthy])
}

fn b7(target: Target(tx), _load: Load) -> Result(Nil, String) {
  let desk = desk(target, point(unique(target, "modelled"), None), proceeding())
  let key = unique(target, "modelled")
  let request =
    isolated.Request(
      source: "stress",
      key:,
      trigger: Trigger("stress", key),
      about: ana,
      context: Manifest(refs: [], renderer: "stress-1"),
      sources: model.recorded(context: [], reads: []),
    )
  let raises = model.new(fn(_, _) { panic as "the model raised" })
  let hangs =
    model.new(fn(_, _) {
      process.sleep_forever()
      Error(model.Declined("unreachable"))
    })
  let sound =
    model.new(fn(_, _) {
      Ok(
        Recommendation(
          "ok",
          Rules("r", "1"),
          RuleFired("r"),
          [fact.set(score(), 1.0)],
          [],
        ),
      )
    })
  let run = fn(chosen, ms) {
    isolated.recommend(
      desk,
      in: within_attempted(target, _),
      request:,
      model: isolated.model(
        chosen,
        within: duration.milliseconds(ms),
        heap: stress_heap(),
      ),
    )
  }
  use Nil <- result.try(case run(raises, 1000) {
    Ok(isolated.Failed(failure: model.Raised(_), attempts: [_])) -> Ok(Nil)
    other -> Error("a model that raises gave " <> string.inspect(other))
  })
  let started = monotonic_ms()
  let hung = run(hangs, 50)
  let took = monotonic_ms() - started
  use Nil <- result.try(case hung {
    Ok(isolated.Failed(failure: model.Deadline(_), attempts: [_, _])) -> Ok(Nil)
    other -> Error("a model that hangs gave " <> string.inspect(other))
  })
  use Nil <- result.try(expect(
    took >= 50,
    "the deadline of 50 ms took " <> int.to_string(took) <> " ms",
  ))
  // The caller is alive, and a sound model recommends under the same key
  // with both failed attempts kept at the start of the record.
  use Nil <- result.try(case run(sound, 1000) {
    Ok(isolated.Recommended(known)) ->
      expect(
        list.length(known.attempts) == 2,
        int.to_string(list.length(known.attempts)) <> " attempts on the record",
      )
    other -> Error("a sound model gave " <> string.inspect(other))
  })
  invariants(target, [desk])
}

@external(erlang, "decisions_otp_ffi", "monotonic_us")
fn monotonic_us() -> Int

fn monotonic_ms() -> Int {
  monotonic_us() / 1000
}

/// Bundles of five whose members settle at once: the follower of whichever
/// member commits last sees the bundle complete, and `recommend_once`
/// under the bundle's follow-on key turns every other follower that sees
/// it complete into nothing. Each bundle starts exactly one follow-on.
fn bundles(target: Target(tx), load: Load) -> Result(Nil, String) {
  let size = 5
  let count = int.max(4, load.a2_queue / 4)
  let items =
    desk(target, point(unique(target, "bundle.items"), None), asking("finance"))
  let follow_on =
    desk(target, point(unique(target, "bundle.follow_on"), None), proceeding())
  let bundles = list.map(numbers(1, count), fn(_) { unique(target, "bundle") })
  let member = fn(bundle, n) { bundle <> "/" <> int.to_string(n) }
  use Nil <- result.try(
    list.try_each(bundles, fn(bundle) {
      within(target, decisions.recommend_bundle(
        items,
        _,
        bundle:,
        items: list.map(numbers(1, size), fn(n) {
          #(
            int.to_string(n),
            stress_proposal(member(bundle, n), "line " <> int.to_string(n)),
          )
        }),
      ))
      |> result.replace(Nil)
      |> result.map_error(said)
    }),
  )
  let follow = fn(tx, record: decisions.Record(String)) {
    case record {
      decisions.Begun(occurrence: known) ->
        case known.bundle {
          Some(bundle) -> {
            use members <- result.try(
              decisions.members(
                items,
                tx,
                bundle: vocabulary.bundle_key(bundle),
              )
              |> result.map_error(decisions.DeskRefused),
            )
            case decisions.is_complete(members) {
              False -> Ok(Nil)
              True ->
                decisions.recommend_once(
                  follow_on,
                  tx,
                  key: "after:" <> vocabulary.bundle_key(bundle),
                  proposal: stress_proposal(
                    "after:" <> vocabulary.bundle_key(bundle),
                    vocabulary.bundle_key(bundle),
                  ),
                )
                |> result.replace(Nil)
                |> result.map_error(decisions.DeskRefused)
            }
          }
          None -> Ok(Nil)
        }
      decisions.NotBegun(_) -> Ok(Nil)
    }
  }
  let config =
    runtime.config(
      target.backlog,
      points: [
        runtime.point(items, settled: follow),
        runtime.point(follow_on, settled: runtime.nothing_follows),
      ],
      work: nothing,
    )
    |> quick
  use supervisor <- result.try(start_runtime(config))
  let ids =
    list.flat_map(bundles, fn(bundle) {
      list.map(numbers(1, size), member(bundle, _))
    })
  let bia = Validator(subject: "bia", holds: ["finance"])
  let decided =
    race(ids, fn(id) {
      process.sleep(int.random(100))
      let verdict = case int.random(3) {
        0 -> Reject(Reason("no", None))
        _ -> Approve
      }
      until_decided(target, items, id, bia, verdict, 50)
    })
  let started = fn() {
    effects(target, follow_on) |> result.map(list.length) |> result.unwrap(0)
  }
  let settled =
    wait_until(
      fn() { started() >= count && target.backlog.undelivered(100) == Ok([]) },
      within: 30_000,
    )
  // Let a delivery in flight finish before counting.
  process.sleep(50)
  stop_runtime(supervisor)
  use aside <- result.try(target.backlog.aside() |> store_text)
  use Nil <- result.try(list.try_each(decided, fn(outcome) { outcome }))
  use Nil <- result.try(expect(
    settled,
    "the follow-ons did not all start: "
      <> int.to_string(started())
      <> " of "
      <> int.to_string(count),
  ))
  use Nil <- result.try(expect(
    aside == [],
    "jobs were set aside: " <> string.inspect(aside),
  ))
  use started_for <- result.try(effects(target, follow_on))
  use Nil <- result.try(expect(
    list.length(started_for) == count
      && list.sort(started_for, string.compare)
      == list.sort(
      list.map(bundles, fn(bundle) {
        "release:after:" <> bundle <> "=" <> bundle
      }),
      string.compare,
    ),
    "the follow-ons started were " <> string.inspect(started_for),
  ))
  invariants(target, [items, follow_on])
}

/// Decide `id`, trying again while the store is contended.
fn until_decided(
  target: Target(tx),
  desk: Desk(String, tx),
  id: String,
  validator: vocabulary.Validator,
  verdict: vocabulary.Verdict(String),
  tries: Int,
) -> Result(Nil, String) {
  case within(target, open_and_decide(desk, _, id, validator, verdict)) {
    Ok(_) -> Ok(Nil)
    Error(_) if tries > 0 -> {
      process.sleep(int.random(10))
      until_decided(target, desk, id, validator, verdict, tries - 1)
    }
    Error(said_) -> Error("deciding " <> id <> ": " <> said(said_))
  }
}

fn stress_proposal(key: String, output: String) -> decisions.Proposal(String) {
  decisions.proposal(
    trigger: Trigger("stress", key),
    about: ana,
    context: Manifest(refs: [Ref("input", key, "1")], renderer: "stress-1"),
    recommending: Recommendation(
      output:,
      by: Rules("rules", "1"),
      explanation: RuleFired("stress"),
      signals: [],
      reads: [],
    ),
  )
}

/// A policy this module writes as a literal, which is well formed.
fn well_formed(
  version version: Int,
  rules rules: List(policy.Rule),
  otherwise otherwise: policy.Eligible,
) -> Policy {
  let assert Ok(made) = policy.new(version:, rules:, otherwise:)
  made
}
