//// A gated tool that waits too long for a lock of its own, or whose
//// nested verb is contended, wrote nothing: the verdict fails as
//// contention, safe to send again at once and not counted, and not as a
//// tool that could not tell.

import decisions.{type Desk, Gated}
import decisions/memory.{type Tx}
import decisions/policy.{AnyoneHolding}
import decisions/store
import decisions/vocabulary.{
  Approve, Manifest, Recommendation, RuleFired, Rules, Trigger,
}
import decisions/wire
import support/policies
import support/world

fn desk(guard: fn() -> Result(Nil, vocabulary.Stop)) -> Desk(String, Tx) {
  decisions.desk(
    decisions.point("party.payout", wire.text()),
    drives: fn(_) {
      Gated(
        name: "pay_party",
        guard: fn(_, _) {
          case guard() {
            Ok(Nil) -> Ok([])
            Error(stop) -> Error(stop)
          }
        },
        execute: fn(tx, released) {
          Ok(world.push(tx, "paid", decisions.output(released)))
        },
      )
    },
    under: fn(_) {
      Ok(policies.checked(
        version: 1,
        rules: [],
        otherwise: AnyoneHolding("finance"),
      ))
    },
    over: memory.port(),
  )
}

fn waiting(w: world.World, desk: Desk(String, Tx)) -> String {
  let assert Ok(known) =
    world.in_tx(w, decisions.recommend(
      desk,
      _,
      decisions.proposal(
        trigger: Trigger(kind: "request", id: "r1"),
        about: world.ana,
        context: Manifest(refs: [], renderer: "payout-1"),
        recommending: Recommendation(
          output: "pay 10",
          by: Rules("payout-rule", "1"),
          explanation: RuleFired("payout"),
          signals: [],
          reads: [],
        ),
      ),
    ))
  known.id
}

pub fn a_tool_whose_own_lock_is_contended_fails_as_contention_test() {
  let w = world.new()
  let contended =
    desk(fn() { Error(vocabulary.Contended("lock wait longer than 4000 ms")) })
  let id = waiting(w, contended)
  let assert Error(refusal) =
    world.in_tx(w, world.open_and_decide(contended, _, id, world.bia, Approve))
  assert refusal
    == decisions.StoreFailed(store.Contended("lock wait longer than 4000 ms"))
  assert decisions.disposition(refusal) == decisions.Transient
  assert world.all(w.db, "paid") == []
  // Nothing was recorded: the same verdict goes through once the lock is
  // free.
  let free = desk(fn() { Ok(Nil) })
  let assert Ok(_) =
    world.in_tx(w, world.open_and_decide(free, _, id, world.bia, Approve))
  assert world.all(w.db, "paid") == ["pay 10"]
}

/// A tool that runs a verb of another desk passes its refusal on with
/// `stop_for`, which keeps contention apart from a tool that could not
/// tell and from a refusal for good.
pub fn a_nested_verbs_refusal_keeps_its_meaning_test() {
  assert decisions.stop_for(decisions.StoreFailed(store.Contended("deadlock")))
    == vocabulary.Contended("deadlock")
  assert decisions.stop_for(decisions.StoreFailed(store.Unavailable("lost")))
    == vocabulary.Unsure("store unavailable: lost")
  assert decisions.stop_for(decisions.ToolUnsure("timeout"))
    == vocabulary.Unsure("the tool could not tell: timeout")
  let assert vocabulary.Refuse(_) = decisions.stop_for(decisions.NotAwaiting)
  let assert vocabulary.Refuse(_) =
    decisions.stop_for(decisions.Unreadable("bad entry"))
}
