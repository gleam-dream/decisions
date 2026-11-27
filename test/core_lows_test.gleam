//// Records stay small and readable: a card reopened by its validator
//// records no second showing, only someone `review` would admit opens a
//// released, sampled occurrence, and a model's raise is recorded within
//// a bound.

import decisions
import decisions/memory
import decisions/model
import decisions/occurrence
import decisions/policy.{PerCent, Proceed, SomeoneElseHolding, When}
import decisions/vocabulary.{Manifest, Person, Trigger}
import gleam/option.{None}
import gleam/string
import support/policies
import support/refund.{Refund}
import support/world

fn asking() {
  policies.checked(
    version: 1,
    rules: [],
    otherwise: SomeoneElseHolding("finance"),
  )
}

fn sampling() {
  policies.checked(
    version: 1,
    rules: [When(policy.Always, Proceed(PerCent(100), None))],
    otherwise: SomeoneElseHolding("finance"),
  )
}

fn request(w: world.World, desk, key: String) {
  let assert Ok(made) =
    world.in_tx(w, refund.request(
      desk,
      _,
      Trigger(kind: "operator", id: key),
      Person("bia"),
      Refund(fee: key, cents: 90_000),
    ))
  made
}

/// L1: a validator who opens the same card again, with nothing changed,
/// gets the same showing back, and the record does not grow.
pub fn a_card_opened_again_records_one_showing_test() {
  let w = world.new()
  let desk = refund.desk(asking())
  let waiting = request(w, desk, "fee-reopen")
  let assert Ok(first) =
    world.in_tx(w, world.open(desk, _, waiting.id, world.caio))
  let entries = memory.entries(w.db, waiting.id)
  let assert Ok(again) =
    world.in_tx(w, world.open(desk, _, waiting.id, world.caio))
  assert decisions.ticket(again) == decisions.ticket(first)
  assert memory.entries(w.db, waiting.id) == entries
}

/// L1: a released, sampled occurrence is opened only by someone `review`
/// would admit; the person who asked for it is refused.
pub fn only_a_possible_reviewer_opens_a_sampled_release_test() {
  let w = world.new()
  let desk = refund.desk(sampling())
  let released = request(w, desk, "fee-sampled")
  let assert occurrence.Released(..) = released.status
  let entries = memory.entries(w.db, released.id)
  assert world.in_tx(w, world.open(desk, _, released.id, world.bia))
    == Error(decisions.NotEligible)
  assert memory.entries(w.db, released.id) == entries
  let assert Ok(_) =
    world.in_tx(w, world.open(desk, _, released.id, world.caio))
}

/// L4: a model that raises with a large reason is recorded with a bounded
/// one.
pub fn a_large_raise_is_recorded_within_a_bound_test() {
  let huge = string.repeat("provider body ", 10_000)
  let raising = model.new(fn(_, _) { panic as huge })
  let sources =
    world.capturing(world.new(), "run-l4", fn(_) { Error("none") }, fn(_, _) {
      Error("none")
    })
  let assert Error(model.Raised(reason)) =
    model.run(raising, Manifest(refs: [], renderer: "r"), sources)
  assert string.byte_size(reason) <= 1024
  assert string.starts_with(reason, "provider body")
}
