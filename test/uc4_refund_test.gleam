//// Use case 4: a fee refund under R$100 proceeds.

import decisions
import decisions/memory
import decisions/occurrence
import decisions/policy.{Ask, Never, Policy, Proceed, SomeoneElseHolding, When}
import decisions/testing
import decisions/vocabulary.{Approve, Person, Trigger}
import support/refund.{Refund}
import support/world

/// Proceed under R$100; otherwise ask a holder of `finance` who is not the
/// requester.
fn policy() {
  Policy(
    version: 2,
    rules: [When(policy.below(refund.amount(), 100.0), Proceed(Never))],
    otherwise: Ask(SomeoneElseHolding("finance")),
  )
}

pub fn a_small_refund_proceeds_and_a_large_one_needs_someone_else_test() {
  let w = world.new()
  let desk = refund.desk(policy())
  let by_bia = fn(tx, fee, cents) {
    refund.request(
      desk,
      tx,
      Trigger(kind: "operator", id: "bia"),
      Person("bia"),
      Refund(fee:, cents:),
    )
  }

  // R$80: it proceeds and the tool runs once.
  let assert Ok(small) = world.in_tx(w, by_bia(_, "fee-small", 8000))
  let assert occurrence.Released(..) = small.status
  assert refund.refunds(w) == ["fee-small:8000"]

  // R$900: it awaits someone other than Bia.
  let assert Ok(large) = world.in_tx(w, by_bia(_, "fee-large", 90_000))
  let assert occurrence.Awaiting(SomeoneElseHolding("finance")) = large.status
  assert memory.queue(w.db, "finance") == [large.id]
  assert world.in_tx(w, world.open_and_decide(
      desk,
      _,
      large.id,
      world.bia,
      Approve,
    ))
    == Error(decisions.NotEligible)
  assert refund.refunds(w) == ["fee-small:8000"]

  let assert Ok(approved) =
    world.in_tx(w, world.open_and_decide(desk, _, large.id, world.caio, Approve))
  let assert occurrence.Released(..) = approved.status
  assert refund.refunds(w) == ["fee-small:8000", "fee-large:90000"]
  world.invariants_hold(w, [
    testing.audit(desk, effects: world.effects("refunds")),
  ])
}
