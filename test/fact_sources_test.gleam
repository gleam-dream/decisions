//// Each fact a policy reads has one source: the output, the model's
//// signals, or a consulted point's answer.

import decisions.{Gated}
import decisions/fact
import decisions/memory
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Consult, Never, Not, Proceed, When}
import decisions/vocabulary.{
  Manifest, Recommendation, RunAnswer, Subject, Trigger,
}
import decisions/wire
import gleam/option.{None, Some}

fn proposal(signals: vocabulary.Facts) -> decisions.Proposal(String) {
  decisions.proposal(
    trigger: Trigger("payment", "1"),
    about: Subject("person", "ana"),
    context: Manifest(refs: [], renderer: "r"),
    recommending: Recommendation(
      output: "pay",
      by: vocabulary.ModelCall("payer", "1"),
      explanation: RunAnswer("r"),
      signals:,
      reads: [],
    ),
  )
}

fn cleared() -> fact.Key(Bool) {
  fact.flag("cleared")
}

fn amount() -> fact.Key(Float) {
  fact.number("amount")
}

fn score() -> fact.Key(Float) {
  fact.number("score")
}

/// "Consult compliance until it has cleared the payment; proceed once it
/// has."
fn compliance_desk() -> decisions.Desk(String, memory.Memory) {
  let assert Ok(p) =
    policy.new(
      version: 1,
      rules: [
        When(Not(policy.known(cleared())), Consult("compliance")),
        When(policy.is(cleared(), True), Proceed(Never, None)),
      ],
      otherwise: AnyoneHolding("finance"),
    )
  decisions.desk(
    decisions.point("sources.payment", wire.text())
      |> decisions.fact(amount(), fn(_) { 10.0 })
      |> decisions.signal(score())
      |> decisions.answer(cleared(), from: "compliance"),
    drives: fn(_) {
      Gated(name: "pay", guard: fn(_, _) { Ok([]) }, execute: fn(_, _) {
        Ok(Nil)
      })
    },
    under: fn(_) { Ok(p) },
    over: memory.port(),
  )
  |> decisions.consulting(fn(_, _) { Ok(Nil) })
}

pub fn a_signal_cannot_answer_for_a_consulted_point_test() {
  let db = memory.new()
  assert memory.transaction(db, decisions.recommend(
      compliance_desk(),
      _,
      proposal([fact.set(cleared(), True)]),
    ))
    == Error(decisions.InvalidFacts([policy.UndeclaredFact("cleared")]))
}

pub fn a_signal_cannot_stand_for_an_output_fact_test() {
  let db = memory.new()
  assert memory.transaction(db, decisions.recommend(
      compliance_desk(),
      _,
      proposal([fact.set(amount(), 1.0), #("score", vocabulary.Text("high"))]),
    ))
    == Error(
      decisions.InvalidFacts([
        policy.UndeclaredFact("amount"),
        policy.WrongKind(
          fact: "score",
          declared: fact.NumberFact,
          used: fact.TextFact,
        ),
      ]),
    )
}

pub fn only_the_named_point_answers_test() {
  let db = memory.new()
  let desk = compliance_desk()
  let assert Ok(made) =
    memory.transaction(db, decisions.recommend(
      desk,
      _,
      proposal([fact.set(score(), 0.9)]),
    ))
  assert made.status == occurrence.Recommended(consulting: Some("compliance"))
  let assert Ok(cleared_by_compliance) =
    memory.transaction(
      db,
      decisions.inform(desk, _, occurrence: made.id, from: "compliance", facts: [
        fact.set(cleared(), True),
      ]),
    )
  let assert occurrence.Released(..) = cleared_by_compliance.status
}

pub fn a_consulted_point_gives_only_its_declared_answer_test() {
  let db = memory.new()
  let desk = compliance_desk()
  let assert Ok(made) =
    memory.transaction(db, decisions.recommend(desk, _, proposal([])))
  assert memory.transaction(
      db,
      decisions.inform(desk, _, occurrence: made.id, from: "compliance", facts: [
        fact.set(score(), 0.1),
      ]),
    )
    == Error(decisions.InvalidFacts([policy.UndeclaredFact("score")]))
}

/// Declaring a name again replaces it, so a name has one source.
pub fn a_name_has_one_source_test() {
  let point =
    decisions.point("sources.again", wire.text())
    |> decisions.signal(cleared())
    |> decisions.answer(cleared(), from: "compliance")
  assert decisions.declared(point) == [#("cleared", fact.FlagFact)]
  let recommendation =
    Recommendation(
      output: "pay",
      by: vocabulary.ModelCall("payer", "1"),
      explanation: RunAnswer("r"),
      signals: [fact.set(cleared(), True)],
      reads: [],
    )
  assert decisions.policy_facts(point, recommendation, informed: []) == []
}
