//// Conditions B1 and B3, as far as one process can show them: a trigger
//// delivered again, and a verdict sent again. The killed-process forms are
//// in `decisions_otp` and `decisions_postgres`.

import decisions
import decisions/memory
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Ask, Policy}
import decisions/vocabulary.{Approve}
import support/payout.{Payout}
import support/world

fn policy() {
  Policy(version: 1, rules: [], otherwise: Ask(AnyoneHolding("finance")))
}

pub fn a_trigger_delivered_three_times_is_one_occurrence_test() {
  let w = world.new()
  let desk = payout.desk(policy())
  let deliver = fn() {
    world.in_tx(w, payout.request(
      desk,
      _,
      key: "payout-7",
      by: "felipe",
      payout: Payout("clinica-x", 50_000),
    ))
  }
  let assert Ok(first) = deliver()
  let assert Ok(second) = deliver()
  let assert Ok(third) = deliver()
  assert first.id == "payout-7"
  assert second.entries == first.entries
  assert third.entries == first.entries
  assert memory.queue(w.db, "finance") == ["payout-7"]
}

pub fn a_verdict_sent_again_stands_and_another_is_told_who_decided_test() {
  let w = world.new()
  let desk = payout.desk(policy())
  let assert Ok(waiting) =
    world.in_tx(w, payout.request(
      desk,
      _,
      key: "payout-8",
      by: "felipe",
      payout: Payout("clinica-x", 50_000),
    ))
  let decide = fn(who) {
    world.in_tx(w, world.open_and_decide(desk, _, waiting.id, who, Approve))
  }
  // Bia's page holds the card's ticket across requests.
  let assert Ok(card) =
    world.in_tx(w, world.open(desk, _, waiting.id, world.bia))
  let ticket = decisions.ticket(card)
  let send = fn() {
    world.in_tx(w, fn(tx) {
      let assert Ok(card) = decisions.resume(desk, tx, ticket, by: world.bia)
      decisions.decide(desk, tx, card, Approve)
    })
  }
  let assert Ok(released) = send()
  let assert occurrence.Released(..) = released.status
  let entries = memory.entries(w.db, waiting.id)

  // The reply was lost. Bia sends the same verdict on the same card: it
  // stood, and nothing was appended.
  let assert Ok(again) = send()
  let assert occurrence.Released(..) = again.status
  assert payout.payouts(w) == ["clinica-x:50000"]
  assert memory.entries(w.db, waiting.id) == entries

  // Dora is told who decided.
  assert decide(world.dora) == Error(decisions.AlreadyDecided("bia"))
  assert payout.payouts(w) == ["clinica-x:50000"]
}
