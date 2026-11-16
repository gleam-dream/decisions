//// Use case 11: escalation over time, and expiry.

import decisions
import decisions/memory
import decisions/occurrence
import decisions/policy.{
  AnyoneHolding, Ask, Either, Never, Policy, Proceed, When,
}
import decisions/testing
import decisions/vocabulary.{Approve, DeadlinePassed, Person, Trigger}
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleam/time/timestamp
import support/refund.{Refund}
import support/world

/// Unanswered for four hours, a refund also appears for `managers`. The
/// threshold is a rule about the time waited; nothing else is new.
fn policy() {
  Policy(
    version: 4,
    rules: [
      When(
        policy.waited(240),
        Ask(Either([AnyoneHolding("finance"), AnyoneHolding("managers")])),
      ),
    ],
    otherwise: Ask(AnyoneHolding("finance")),
  )
}

fn desk(policy) {
  refund.desk_of(
    refund.point() |> decisions.valid_for(duration.hours(24)),
    policy,
  )
}

fn ask(w: world.World, desk, fee: String) {
  let assert Ok(waiting) =
    world.in_tx(w, refund.request(
      desk,
      _,
      Trigger(kind: "ticket", id: fee),
      Person("ana"),
      Refund(fee:, cents: 90_000),
    ))
  waiting
}

pub fn an_unanswered_refund_reaches_managers_after_four_hours_test() {
  let w = world.new()
  let desk = desk(policy())
  let waiting = ask(w, desk, "fee-1")
  let wakers = [decisions.waker(desk)]

  // The record already holds what the policy will say later, and the store
  // holds a wake-up for it and one for the deadline.
  assert list.map(waiting.later, fn(step) { step.after }) == [240]
  assert list.map(memory.wakes(w.db), fn(wake) { wake.at })
    == [
      timestamp.add(world.t0(), duration.hours(4)),
      timestamp.add(world.t0(), duration.hours(24)),
    ]

  // 3 h 59 min: only finance sees it, and Dora may not open the card.
  world.at(w, duration.minutes(239))
  assert world.deliver_due(w, wakers) == 0
  assert memory.queue(w.db, "finance") == [waiting.id]
  assert memory.queue(w.db, "managers") == []
  let open_as_manager = fn() {
    world.in_tx(w, world.open_and_decide(
      desk,
      _,
      waiting.id,
      world.dora_as_manager,
      Approve,
    ))
  }
  assert open_as_manager() == Error(decisions.NotEligible)

  // 4 h: the wake-up makes the policy answer again.
  world.at(w, duration.hours(4))
  assert world.deliver_due(w, wakers) == 1
  assert memory.queue(w.db, "finance") == [waiting.id]
  assert memory.queue(w.db, "managers") == [waiting.id]

  // The record shows when eligibility changed and to what.
  let escalated = world.read(w, desk, waiting.id)
  let assert [
    #(first_at, Ask(AnyoneHolding("finance"))),
    #(then_at, Ask(Either(_))),
  ] = occurrence.policy_answers(escalated)
  assert first_at == world.t0()
  assert then_at == timestamp.add(world.t0(), duration.hours(4))
  assert escalated.policy_version == Some(4)

  // Dora decides it.
  let assert Ok(released) = open_as_manager()
  let assert occurrence.Released(..) = released.status
  assert refund.refunds(w) == ["fee-1:90000"]
  world.invariants_hold(w, [
    testing.audit(desk, effects: world.effects("refunds")),
  ])
}

pub fn after_twenty_four_hours_it_expires_test() {
  let w = world.new()
  let desk = desk(policy())
  let waiting = ask(w, desk, "fee-2")
  let wakers = [decisions.waker(desk)]

  world.at(w, duration.hours(24))
  // Two wake-ups were due: the escalation and the deadline. Either order
  // ends in the same place.
  assert world.deliver_due(w, wakers) == 2
  let expired = world.read(w, desk, waiting.id)
  assert expired.status == occurrence.Expired(DeadlinePassed)
  assert memory.queue(w.db, "finance") == []
  assert memory.queue(w.db, "managers") == []
  assert world.in_tx(w, world.open_and_decide(
      desk,
      _,
      waiting.id,
      world.bia,
      Approve,
    ))
    == Error(decisions.NotAwaiting)
  assert refund.refunds(w) == []
  world.invariants_hold(w, [
    testing.audit(desk, effects: world.effects("refunds")),
  ])
}

/// The same mechanism gives "proceed if nobody objects within the hour".
pub fn silence_can_be_consent_when_the_policy_says_so_test() {
  let w = world.new()
  let desk =
    desk(Policy(
      version: 5,
      rules: [When(policy.waited(60), Proceed(Never, None))],
      otherwise: Ask(AnyoneHolding("finance")),
    ))
  let waiting = ask(w, desk, "fee-3")
  world.at(w, duration.minutes(60))
  assert world.deliver_due(w, [decisions.waker(desk)]) == 1
  let released = world.read(w, desk, waiting.id)
  let assert occurrence.Released(by: occurrence.ByPolicy(5), ..) =
    released.status
  assert refund.refunds(w) == ["fee-3:90000"]
  world.invariants_hold(w, [
    testing.audit(desk, effects: world.effects("refunds")),
  ])
}
