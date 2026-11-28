//// The policy behaviours `docs/MIGRATION.md` tells an upgrader from 0.1
//// about, pinned so the guide stays true.

import decisions/fact
import decisions/policy.{All, AnyoneHolding, Ask, Never, Proceed, When}
import decisions/vocabulary.{Rules}
import gleam/option.{None}
import support/policies

fn risk() {
  fact.text("risk")
}

fn by() {
  Rules("rule", "1")
}

/// A rule over an answer that exists only after a consult stops the
/// reading when the answer is absent, unless `known` guards it.
pub fn a_known_guard_lets_the_policy_read_on_test() {
  let proceed = When(policy.Always, Proceed(Never, None))
  let unguarded =
    policies.checked(
      version: 1,
      rules: [
        When(policy.is(risk(), "high"), Ask(AnyoneHolding("head"))),
        proceed,
      ],
      otherwise: AnyoneHolding("finance"),
    )
  let guarded =
    policies.checked(
      version: 1,
      rules: [
        When(
          All([policy.known(risk()), policy.is(risk(), "high")]),
          Ask(AnyoneHolding("head")),
        ),
        proceed,
      ],
      otherwise: AnyoneHolding("finance"),
    )
  assert policy.evaluate(unguarded, by(), []) == Ask(AnyoneHolding("finance"))
  assert policy.evaluate(guarded, by(), []) == Proceed(Never, None)
  assert policy.evaluate(guarded, by(), [fact.set(risk(), "high")])
    == Ask(AnyoneHolding("head"))
}

/// `waited` is unknown under `evaluate`, which has no waited time; read
/// through `timeline` it holds once the time has passed.
pub fn a_waited_condition_needs_the_timeline_test() {
  let escalating =
    policies.checked(
      version: 1,
      rules: [
        When(policy.waited(30), Ask(AnyoneHolding("head"))),
        When(policy.Always, Ask(AnyoneHolding("staff"))),
      ],
      otherwise: AnyoneHolding("finance"),
    )
  assert policy.evaluate(escalating, by(), []) == Ask(AnyoneHolding("finance"))
  let #(now, _) = policy.timeline(escalating, by(), [], waited: 0)
  assert now == Ask(AnyoneHolding("staff"))
  let #(later, _) = policy.timeline(escalating, by(), [], waited: 30)
  assert later == Ask(AnyoneHolding("head"))
}
