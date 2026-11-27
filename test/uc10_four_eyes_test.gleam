//// Use case 10: four eyes. Two different holders of `finance` who did not
//// ask must approve a large payout.

import decisions
import decisions/memory
import decisions/occurrence
import decisions/policy.{Ask, Several, SomeoneElseHolding, When}
import decisions/testing
import decisions/vocabulary.{Approve, Correct, Reason, Reject}
import gleam/list
import gleam/option.{None}
import support/payout.{Payout}
import support/policies
import support/world

/// At or above 10 000.00, two different holders of `finance` who did not
/// ask; below, one. The whole rule is data.
fn policy() {
  policies.checked(
    version: 1,
    rules: [
      When(
        policy.at_least(payout.amount(), 10_000.0),
        Ask(Several(2, SomeoneElseHolding("finance"))),
      ),
    ],
    otherwise: SomeoneElseHolding("finance"),
  )
}

fn large(w: world.World) {
  let desk = payout.desk(policy())
  let assert Ok(waiting) =
    world.in_tx(w, payout.request(
      desk,
      _,
      key: "payout-1",
      by: "felipe",
      payout: Payout("clinica-x", 1_200_000),
    ))
  let decide = fn(who, verdict) {
    world.in_tx(w, world.open_and_decide(desk, _, waiting.id, who, verdict))
  }
  #(waiting, decide)
}

pub fn a_large_payout_needs_two_different_approvers_test() {
  let w = world.new()
  let #(waiting, decide) = large(w)
  let assert occurrence.Awaiting(Several(2, _)) = waiting.status

  // Felipe asked, so he cannot approve.
  assert decide(world.felipe, Approve) == Error(decisions.NotEligible)

  // One approval is not enough.
  let assert Ok(card) =
    world.in_tx(w, world.open(payout.desk(policy()), _, waiting.id, world.bia))
  let ticket = decisions.ticket(card)
  let on_ticket = fn(verdict) {
    world.in_tx(w, fn(tx) {
      let desk = payout.desk(policy())
      let assert Ok(card) = decisions.resume(desk, tx, ticket, by: world.bia)
      decisions.decide(desk, tx, card, verdict)
    })
  }
  let assert Ok(after_bia) = on_ticket(Approve)
  let assert occurrence.Awaiting(_) = after_bia.status
  assert payout.payouts(w) == []
  assert memory.queue(w.db, "finance") == [waiting.id]

  // The head says who approved, so the queue leaves the card out for Bia
  // and keeps it for Dora.
  assert memory.queue_for(w.db, world.bia) == []
  assert memory.queue_for(w.db, world.dora) == [waiting.id]

  // Bia's approval, sent again, stands and counts once.
  let assert Ok(again) = on_ticket(Approve)
  assert occurrence.standing(again).1 == ["bia"]
  let assert occurrence.Awaiting(_) = again.status
  // And she cannot give a second, different verdict toward the count.
  assert on_ticket(Correct(Payout("clinica-x", 1), Reason("x", None)))
    == Error(decisions.NotEligible)

  // Dora's approval releases it, once.
  let assert Ok(released) = decide(world.dora, Approve)
  let assert occurrence.Released(by: occurrence.ByValidator("dora"), ..) =
    released.status
  assert payout.payouts(w) == ["clinica-x:1200000"]
  assert memory.queue(w.db, "finance") == []
  assert list.map(occurrence.verdicts(released), fn(v) { v.0 })
    == ["bia", "dora"]
  assert list.length(memory.notices(w.db)) == 1
  world.invariants_hold(w, [
    testing.audit(payout.desk(policy()), effects: world.effects("payouts")),
  ])
}

pub fn a_rejection_by_either_ends_it_test() {
  let w = world.new()
  let #(_, decide) = large(w)
  let assert Ok(_) = decide(world.bia, Approve)
  let assert Ok(rejected) =
    decide(world.dora, Reject(Reason("duplicate", None)))
  let assert occurrence.Rejected(_) = rejected.status
  assert payout.payouts(w) == []
  assert decide(world.caio, Approve) == Error(decisions.AlreadyDecided("dora"))
}

pub fn a_correction_voids_approvals_of_the_earlier_amount_test() {
  let w = world.new()
  let #(_, decide) = large(w)
  let assert Ok(_) = decide(world.bia, Approve)

  // Dora corrects the amount. Bia approved 12 000.00, not 11 000.00.
  let assert Ok(corrected) =
    decide(
      world.dora,
      Correct(Payout("clinica-x", 1_100_000), Reason("amount", None)),
    )
  let assert occurrence.Awaiting(_) = corrected.status
  assert occurrence.standing(corrected)
    == #(Payout("clinica-x", 1_100_000), ["dora"])
  assert payout.payouts(w) == []

  // Bia approves the corrected amount, and that amount is paid.
  let assert Ok(released) = decide(world.bia, Approve)
  let assert occurrence.Released(..) = released.status
  assert payout.payouts(w) == ["clinica-x:1100000"]
  world.invariants_hold(w, [
    testing.audit(payout.desk(policy()), effects: world.effects("payouts")),
  ])
}

pub fn a_small_payout_needs_one_test() {
  let w = world.new()
  let desk = payout.desk(policy())
  let assert Ok(waiting) =
    world.in_tx(w, payout.request(
      desk,
      _,
      key: "payout-2",
      by: "felipe",
      payout: Payout("clinica-x", 50_000),
    ))
  let assert Ok(released) =
    world.in_tx(w, world.open_and_decide(
      desk,
      _,
      waiting.id,
      world.bia,
      Approve,
    ))
  let assert occurrence.Released(..) = released.status
  assert payout.payouts(w) == ["clinica-x:50000"]
}
