//// What is unknown never proceeds: a rule whose condition cannot be
//// evaluated stops the policy, and the policy asks its default.

import decisions.{Gated}
import decisions/fact
import decisions/memory
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Ask, Never, Proceed, When}
import decisions/vocabulary.{
  Manifest, Recommendation, RunAnswer, Subject, Text, Trigger,
}
import decisions/wire
import gleam/option.{None}

fn proposal(signals: vocabulary.Facts) -> decisions.Proposal(String) {
  decisions.proposal(
    trigger: Trigger("message", "1"),
    about: Subject("person", "ana"),
    context: Manifest(refs: [], renderer: "r"),
    recommending: Recommendation(
      output: "pay",
      by: vocabulary.ModelCall("scorer", "1"),
      explanation: RunAnswer("r"),
      signals:,
      reads: [],
    ),
  )
}

/// "Ask risk when the risk is at least 0.5; proceed otherwise."
fn risky() -> policy.Policy {
  let assert Ok(made) =
    policy.new(
      version: 1,
      rules: [
        When(policy.at_least(risk(), 0.5), Ask(AnyoneHolding("risk"))),
        When(policy.Always, Proceed(Never, None)),
      ],
      otherwise: AnyoneHolding("risk"),
    )
  made
}

fn risk() -> fact.Key(Float) {
  fact.number("risk")
}

fn risky_desk() -> decisions.Desk(String, memory.Tx) {
  decisions.desk(
    decisions.point("unknown.risk", wire.text()) |> decisions.signal(risk()),
    drives: fn(_) {
      Gated(name: "pay", guard: fn(_, _) { Ok([]) }, execute: fn(_, _) {
        Ok(Nil)
      })
    },
    under: fn(_) { Ok(risky()) },
    over: memory.port(),
  )
}

pub fn a_missing_signal_asks_a_person_test() {
  let db = memory.new()
  let assert Ok(made) =
    memory.transaction(db, decisions.recommend(risky_desk(), _, proposal([])))
  assert made.status == occurrence.Awaiting(eligible: AnyoneHolding("risk"))
}

/// A signal of another type than the point declares never reaches the
/// policy: the recommendation is refused.
pub fn a_mistyped_signal_is_refused_test() {
  let db = memory.new()
  assert memory.transaction(db, decisions.recommend(
      risky_desk(),
      _,
      proposal([#("risk", Text("0.9"))]),
    ))
    == Error(
      decisions.InvalidFacts([
        policy.WrongKind(
          fact: "risk",
          declared: fact.NumberFact,
          used: fact.TextFact,
        ),
      ]),
    )
}

pub fn a_known_low_risk_proceeds_test() {
  let db = memory.new()
  let assert Ok(made) =
    memory.transaction(db, decisions.recommend(
      risky_desk(),
      _,
      proposal([fact.set(risk(), 0.1)]),
    ))
  let assert occurrence.Released(..) = made.status
}

/// An unknown condition stops the reading even when a later rule would
/// hold, and `Not` keeps it unknown.
pub fn an_unknown_condition_stops_the_reading_test() {
  let cleared = fact.flag("cleared")
  let assert Ok(p) =
    policy.new(
      version: 1,
      rules: [
        When(policy.Not(policy.is(cleared, True)), Ask(AnyoneHolding("x"))),
        When(policy.OwnAct, Proceed(Never, None)),
      ],
      otherwise: AnyoneHolding("default"),
    )
  let by = vocabulary.Person("ana")
  assert policy.evaluate(p, by, []) == Ask(AnyoneHolding("default"))
  assert policy.evaluate(p, by, [#("cleared", Text("yes"))])
    == Ask(AnyoneHolding("default"))
  assert policy.evaluate(p, by, [fact.set(cleared, True)])
    == Proceed(Never, None)
  assert policy.evaluate(p, by, [fact.set(cleared, False)])
    == Ask(AnyoneHolding("x"))
}
