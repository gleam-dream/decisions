//// A verb on the in-memory store runs only in `memory.transaction`, so an
//// error from its body puts every row back.

import decisions.{type Desk, Gated}
import decisions/memory.{type Tx}
import decisions/policy.{AnyoneHolding, Never, Proceed, When}
import decisions/store
import decisions/vocabulary.{
  Manifest, Recommendation, Ref, RuleFired, Rules, Subject, Trigger,
}
import decisions/wire
import gleam/option.{None}
import support/policies
import support/world

/// A point that proceeds on its own and releases to a tool that records
/// its effect. Its store refuses the settlement notice, the last write of
/// a release.
fn desk() -> Desk(String, Tx) {
  decisions.desk(
    decisions.point("mt.point", wire.text()),
    drives: fn(_) {
      Gated(name: "t", guard: fn(_, _) { Ok([]) }, execute: fn(tx, released) {
        Ok(world.push(tx, "effects", decisions.output(released)))
      })
    },
    under: fn(_) {
      Ok(policies.checked(
        1,
        [When(policy.Always, Proceed(Never, None))],
        AnyoneHolding("finance"),
      ))
    },
    over: store.Port(..memory.port(), settled: fn(_, _, _) {
      Error(store.Unavailable("the notice table is down"))
    }),
  )
}

fn proposal() {
  decisions.proposal(
    trigger: Trigger("t", "1"),
    about: Subject("company", "x"),
    context: Manifest(refs: [Ref("m", "1", "1")], renderer: "r"),
    recommending: Recommendation(
      output: "1",
      by: Rules("r", "1"),
      explanation: RuleFired("r"),
      signals: [],
      reads: [],
    ),
  )
}

/// The release runs the tool, appends the entries and then fails on the
/// notice. Nothing of it may stay: not the record, not the effect.
///
/// The port takes a `memory.Tx`, which only `memory.transaction` makes, so
/// the verb cannot be called on the `Memory` itself, where the same
/// failure kept the record and the effect.
pub fn a_verb_that_fails_writes_nothing_test() {
  let db = world.new().db
  let assert Error(decisions.StoreFailed(_)) =
    memory.transaction(db, decisions.recommend(desk(), _, proposal()))
  assert memory.heads(db) == []
  assert world.all(db, "effects") == []
}
