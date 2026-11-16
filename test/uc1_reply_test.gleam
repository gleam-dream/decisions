//// Use case 1: a WhatsApp reply. Held, withdrawn, superseded.

import decisions
import decisions/memory
import decisions/occurrence
import decisions/testing
import decisions/vocabulary.{Correct, Manifest, Reason, Ref, Superseded}
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleam/time/timestamp
import support/reply
import support/world

const corrected = "O DAS vence no dia 20 deste mês."

fn context() {
  Manifest(refs: [Ref("message", "m1", "1")], renderer: "reply-1")
}

fn audits() {
  [testing.audit(reply.desk(), effects: world.effects("outbox"))]
}

pub fn a_corrected_reply_is_sent_once_after_the_hold_test() {
  let w = world.new()
  let drafted = reply.draft(w, "m1", "run-1", context())
  let assert occurrence.Awaiting(_) = drafted.status
  assert memory.queue(w.db, "operators") == [drafted.id]

  let assert Ok(held) =
    world.in_tx(w, world.open_and_decide(
      reply.desk(),
      _,
      drafted.id,
      world.felipe,
      Correct(corrected, Reason("tone", None)),
    ))
  let until = timestamp.add(world.t0(), duration.seconds(5))
  let assert occurrence.Held(final:, until: held_until, ..) = held.status
  assert final == corrected
  assert held_until == until

  // Before the hold ends nothing is sent, and no wake-up is due.
  assert reply.outbox(w) == []
  assert world.deliver_due(w, [decisions.waker(reply.desk())]) == 0

  world.at(w, duration.seconds(5))
  assert world.deliver_due(w, [decisions.waker(reply.desk())]) == 1
  assert reply.outbox(w) == [corrected]

  // The same wake-up delivered again sends nothing.
  let assert Ok(decisions.NothingDue) =
    world.in_tx(w, decisions.wake(reply.desk(), _, occurrence: drafted.id))
  let again = world.read(w, reply.desk(), drafted.id)
  let assert occurrence.Released(final: sent, ..) = again.status
  assert sent == corrected
  assert reply.outbox(w) == [corrected]

  // The record keeps the draft beside the correction.
  assert again.recommendation.output == reply.draft_text
  let assert Some(#("felipe", Correct(output: kept, ..))) =
    occurrence.verdict(again)
  assert kept == corrected
  assert list.length(memory.notices(w.db)) == 1
  world.invariants_hold(w, audits())
}

pub fn only_the_decider_withdraws_and_nothing_is_sent_test() {
  let w = world.new()
  let drafted = reply.draft(w, "m1", "run-1", context())
  let assert Ok(_) =
    world.in_tx(w, world.open_and_decide(
      reply.desk(),
      _,
      drafted.id,
      world.felipe,
      Correct(corrected, Reason("tone", None)),
    ))

  world.at(w, duration.seconds(2))
  assert world.in_tx(w, decisions.withdraw(
      reply.desk(),
      _,
      occurrence: drafted.id,
      by: "caio",
    ))
    == Error(decisions.NotTheDecider)
  let assert Ok(withdrawn) =
    world.in_tx(w, decisions.withdraw(
      reply.desk(),
      _,
      occurrence: drafted.id,
      by: "felipe",
    ))
  assert withdrawn.status == occurrence.Withdrawn(by: "felipe")

  // Withdrawing cancelled the wake-up: nothing is left to deliver.
  assert memory.wakes(w.db) == []
  world.at(w, duration.seconds(5))
  assert world.deliver_due(w, [decisions.waker(reply.desk())]) == 0
  assert reply.outbox(w) == []
  world.invariants_hold(w, audits())
}

pub fn a_newer_message_supersedes_a_waiting_draft_test() {
  let w = world.new()
  let drafted = reply.draft(w, "m1", "run-1", context())
  let assert Ok(card) =
    world.in_tx(w, world.open(reply.desk(), _, drafted.id, world.felipe))

  // m2 arrives: the conversation context tells reply's desk in the storing
  // transaction.
  let assert Ok(decisions.Supersession(
    expired: [expired],
    not_begun: [],
    unreadable: [],
  )) =
    world.in_tx(w, decisions.happened(
      reply.desk(),
      _,
      "customer.message",
      about: world.ana,
    ))
  assert expired.status == occurrence.Expired(Superseded("customer.message"))
  assert memory.queue(w.db, "operators") == []

  assert world.in_tx(w, decisions.decide(
      reply.desk(),
      _,
      card,
      Correct(corrected, Reason("tone", None)),
    ))
    == Error(decisions.NotAwaiting)
  assert reply.outbox(w) == []
  world.invariants_hold(w, audits())
}
