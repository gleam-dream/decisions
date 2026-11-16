//// Condition F: what the types and the publish check hold. The
//// must-not-compile fixtures are in `fixtures/negative`.

import decisions
import decisions/fact
import decisions/policy.{
  AnyoneHolding, Ask, AtLeast, Is, Never, Policy, Proceed, Several, When,
}
import decisions/vocabulary.{Approve, Correct, Reason, Text}
import gleam/json
import gleam/option.{None}
import support/payout
import support/refund.{Refund}
import support/world

/// F2. A policy written in Gleam cannot misspell a fact: it uses the key.
/// A policy that arrives as data is refused when it is published.
pub fn a_policy_that_reads_an_undeclared_fact_is_not_publishable_test() {
  let sound =
    Policy(
      version: 2,
      rules: [When(policy.below(payout.amount(), 100.0), Proceed(Never, None))],
      otherwise: Ask(AnyoneHolding("finance")),
    )
  assert decisions.publishable(payout.point(), sound) == Ok(Nil)

  // The same policy as an administrator's stored JSON, with a typo, a text
  // comparison on a number, and no approvals.
  let stored =
    "{\"version\":3,\"rules\":[{\"when\":{\"t\":\"at_least\",\"fact\":\"ammount\",\"limit\":100},\"then\":{\"t\":\"proceed\",\"sample\":null}},{\"when\":{\"t\":\"is\",\"fact\":\"amount\",\"value\":{\"t\":\"text\",\"v\":\"high\"}},\"then\":{\"t\":\"proceed\",\"sample\":null}}],\"otherwise\":{\"t\":\"ask\",\"eligible\":{\"t\":\"several\",\"count\":0,\"of\":{\"t\":\"anyone\",\"set\":\"finance\"}}}}"
  let assert Ok(decoded) = json.parse(stored, policy.decoder())
  assert decoded
    == Policy(
      version: 3,
      rules: [
        When(AtLeast("ammount", 100.0), Proceed(Never, None)),
        When(Is("amount", Text("high")), Proceed(Never, None)),
      ],
      otherwise: Ask(Several(0, AnyoneHolding("finance"))),
    )
  assert decisions.publishable(payout.point(), decoded)
    == Error([
      policy.UndeclaredFact("ammount"),
      policy.WrongKind(
        fact: "amount",
        declared: fact.NumberFact,
        used: fact.TextFact,
      ),
      policy.TooFewApprovals(0),
    ])

  // A policy round-trips through its JSON unchanged, and compares by value.
  assert json.parse(json.to_string(policy.to_json(sound)), policy.decoder())
    == Ok(sound)
}

/// The desk checks the policy it reads too, so an unpublishable one never
/// decides anything.
pub fn a_desk_refuses_to_use_an_unpublishable_policy_test() {
  let w = world.new()
  let typo =
    Policy(
      version: 9,
      rules: [When(AtLeast("ammount", 1.0), Proceed(Never, None))],
      otherwise: Proceed(Never, None),
    )
  assert world.in_tx(w, refund.request(
      refund.desk(typo),
      _,
      vocabulary.Trigger("ticket", "t9"),
      vocabulary.Rules("refund-rules", "1"),
      Refund("fee-9", 100),
    ))
    == Error(decisions.Unpublishable([policy.UndeclaredFact("ammount")]))
  assert refund.refunds(w) == []
}

/// F4. Rules the types do not hold, and the typed refusals that do.
pub fn run_time_refusals_are_typed_test() {
  let w = world.new()
  let ask =
    Policy(version: 1, rules: [], otherwise: Ask(AnyoneHolding("finance")))

  // A point that allows no correction refuses one.
  let refunds = refund.desk(ask)
  let assert Ok(waiting) =
    world.in_tx(w, refund.request(
      refunds,
      _,
      vocabulary.Trigger("ticket", "t1"),
      vocabulary.Rules("refund-rules", "1"),
      Refund("fee-1", 100),
    ))
  assert world.in_tx(w, world.open_and_decide(
      refunds,
      _,
      waiting.id,
      world.bia,
      Correct(Refund("fee-1", 50), Reason("amount", None)),
    ))
    == Error(decisions.VerdictNotAllowed)
  // A rejection needs a reason category.
  assert world.in_tx(w, world.open_and_decide(
      refunds,
      _,
      waiting.id,
      world.bia,
      vocabulary.Reject(Reason(" ", None)),
    ))
    == Error(decisions.ReasonRequired)

  // E7. A validator outside the decision set cannot even open the card.
  assert world.in_tx(w, world.open_and_decide(
      refunds,
      _,
      waiting.id,
      world.caio_in_support,
      Approve,
    ))
    == Error(decisions.NotEligible)

  // An occurrence of another point does not load at this desk.
  let payouts = payout.desk(ask)
  let assert Error(_) =
    world.in_tx(w, decisions.read(payouts, _, occurrence: waiting.id))
  // And with the same codec, it is refused as not this point's.
  let other =
    refund.desk_of(decisions.point("billing.other_refund", refund.codec()), ask)
  assert world.in_tx(w, decisions.read(other, _, occurrence: waiting.id))
    == Error(decisions.UnknownOccurrence)
}
