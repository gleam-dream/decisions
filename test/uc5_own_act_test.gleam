//// Use case 5: an operator's own act on a gated tool, re-gated by the
//// policy alone.

import decisions.{type Desk, Gated}
import decisions/memory.{type Memory}
import decisions/occurrence.{type Occurrence}
import decisions/policy.{
  type Policy, AnyoneHolding, Ask, Never, OwnAct, Policy, Proceed,
  SomeoneElseHolding, When,
}
import decisions/vocabulary.{
  Manifest, OwnAct as HerOwnAct, Person, Recommendation, Trigger,
}
import decisions/wire
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import support/world.{type World}

/// The desk reads its policy from the database in the caller's
/// transaction. Publishing a version is a write.
fn desk() -> Desk(String, Memory) {
  decisions.desk(
    decisions.point("registry.back_override", wire.text()),
    drives: fn(_) {
      Gated(
        name: "back_representation",
        guard: fn(_, _) { Ok([]) },
        execute: fn(tx, released) {
          Ok(world.push(tx, "backed", decisions.output(released)))
        },
      )
    },
    under: fn(tx) {
      use text <- result.try(
        memory.get(tx, "policy:registry.back_override")
        |> result.replace_error("no policy is published"),
      )
      json.parse(text, policy.decoder())
      |> result.replace_error("the stored policy does not decode")
    },
    over: memory.port(),
  )
}

fn publish(w: World, version: Policy) -> Nil {
  memory.put(
    w.db,
    "policy:registry.back_override",
    json.to_string(policy.to_json(version)),
  )
}

/// The one code path for an override. Nothing in it knows the policy.
fn override(
  w: World,
  representation: String,
) -> Result(Occurrence(String), decisions.Refusal) {
  world.in_tx(w, fn(tx) {
    decisions.recommend(
      desk(),
      tx,
      decisions.proposal(
        trigger: Trigger(kind: "operator", id: "bia"),
        about: world.clinica,
        context: Manifest(refs: [], renderer: "override-1"),
        recommending: Recommendation(
          reads: [],
          output: representation,
          by: Person("bia"),
          explanation: HerOwnAct,
          signals: [],
        ),
      ),
    )
  })
}

pub fn an_own_act_is_recorded_and_regated_by_the_policy_alone_test() {
  let w = world.new()

  // Nothing is published yet: the desk refuses, with the reason.
  assert override(w, "nobody")
    == Error(decisions.NoPolicy("no policy is published"))

  // Version 1: a person's own act proceeds at once, and is recorded.
  publish(
    w,
    Policy(
      version: 1,
      rules: [When(OwnAct, Proceed(Never, None))],
      otherwise: Ask(AnyoneHolding("operators")),
    ),
  )
  let assert Ok(first) = override(w, "ana-represents-clinica-x")
  let assert occurrence.Released(..) = first.status
  assert first.policy_version == Some(1)
  assert first.recommendation.by == Person("bia")
  assert occurrence.verdict(first) == None
  assert world.all(w.db, "backed") == ["ana-represents-clinica-x"]

  // Version 2 asks a second person. Only the policy changed.
  publish(
    w,
    Policy(
      version: 2,
      rules: [],
      otherwise: Ask(SomeoneElseHolding("operators")),
    ),
  )
  let assert Ok(second) = override(w, "bia-represents-clinica-y")
  let assert occurrence.Awaiting(SomeoneElseHolding("operators")) =
    second.status
  assert second.policy_version == Some(2)
  assert world.all(w.db, "backed") == ["ana-represents-clinica-x"]
}
