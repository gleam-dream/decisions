//// What writing the design layer showed: repeating a recorded refusal, an
//// assessment before settlement, and one rule for what is judged.

import decisions.{type Desk, Gated}
import decisions/learning.{Archive}
import decisions/memory.{type Memory}
import decisions/model
import decisions/occurrence.{type Occurrence}
import decisions/policy.{AnyoneHolding, Never, OwnAct, Proceed, When}
import decisions/vocabulary.{
  type Manifest, type Ref, Approve, ApproveRejectOrCorrect, Assessment, Correct,
  Manifest, Person, Reason, Recommendation, Ref, Reject, Right, RuleFired, Rules,
  Subject, Trigger, Validator,
}
import decisions/wire
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/time/duration
import gleam/time/timestamp
import support/policies
import support/world

const bia = Validator("bia", ["finance"])

fn desk(execute) -> Desk(String, Memory) {
  decisions.desk(
    decisions.point("design.point", wire.text())
      |> decisions.allowing(ApproveRejectOrCorrect)
      |> decisions.valid_for(duration.hours(1)),
    drives: fn(_) { Gated(name: "t", guard: fn(_, _) { Ok([]) }, execute:) },
    under: fn(_) {
      Ok(policies.checked(
        1,
        [When(OwnAct, Proceed(Never, None))],
        AnyoneHolding("finance"),
      ))
    },
    over: memory.port(),
  )
}

fn ok_tool(_, _) {
  Ok(Nil)
}

/// The candidate and the recorded recommender: both propose the context's
/// one reference id.
fn echoing() -> model.Model(String) {
  model.new(fn(context: Manifest, _) {
    case context.refs {
      [ref] ->
        Ok(Recommendation(ref.id, Rules("echo", "1"), RuleFired("r"), [], []))
      _ -> Error(model.Declined("no ref"))
    }
  })
}

fn propose(db: Memory, desk, output: String, by) -> Occurrence(String) {
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(
      desk,
      _,
      decisions.proposal(
        trigger: Trigger("t", output),
        about: Subject("company", "x"),
        context: Manifest([Ref("line", output, "1")], "r"),
        recommending: Recommendation(output, by, RuleFired("r"), [], []),
      ),
    ))
  w
}

fn decide(db: Memory, desk, id: String, verdict) {
  memory.transaction(db, world.open_and_decide(desk, _, id, bia, verdict))
}

/// 1. A recorded refusal, sent again with the same token, appends nothing;
/// a failed attempt, sent again, is recorded again.
pub fn record_refusal_is_safe_to_repeat_test() {
  let db = world.new().db
  let refusing = desk(fn(_, _) { Error(decisions.Refuse("closed")) })
  let w = propose(db, refusing, "a", Rules("echo", "1"))
  let assert Error(decisions.ToolRefused(rollback:, ..)) =
    decide(db, refusing, w.id, Approve)
  let assert Ok(once) =
    memory.transaction(db, decisions.record_refusal(refusing, _, rollback))
  let assert Ok(twice) =
    memory.transaction(db, decisions.record_refusal(refusing, _, rollback))
  assert list.length(occurrence.refusals(twice)) == 1
  assert twice.entries == once.entries

  let attempt = fn() {
    memory.transaction(db, decisions.record_failure(
      refusing,
      _,
      key: "design-k",
      trigger: Trigger("t", "k"),
      about: Subject("company", "x"),
      failure: model.Raised("crashed"),
    ))
  }
  let assert Ok([_]) = attempt()
  let assert Ok([_, _]) = attempt()
}

/// 2. Only a settled occurrence is assessed; rejected and expired ones are.
pub fn assess_needs_a_settled_occurrence_test() {
  let db = world.new().db
  let d = desk(ok_tool)
  let finding = fn() {
    Assessment(Right, Ref("audit", "a", "1"), "audit", memory.now(db))
  }
  let assess = fn(id) {
    memory.transaction(db, decisions.assess(
      d,
      _,
      occurrence: id,
      finding: finding(),
    ))
    |> result.replace(Nil)
  }
  let waiting = propose(db, d, "a", Rules("echo", "1"))
  assert assess(waiting.id) == Error(decisions.NotSettled)
  assert decisions.disposition(decisions.NotSettled) == decisions.Final
  let rejected = propose(db, d, "b", Rules("echo", "1"))
  let assert Ok(_) = decide(db, d, rejected.id, Reject(Reason("no", None)))
  assert assess(rejected.id) == Ok(Nil)
  memory.set_clock(db, timestamp.add(memory.now(db), duration.hours(2)))
  let assert Ok(decisions.Woken(_)) =
    memory.transaction(db, decisions.wake(d, _, occurrence: waiting.id))
  assert assess(waiting.id) == Ok(Nil)
}

/// 3. The recorded tally and the replay judge the same occurrences, so
/// their agreement figures have one denominator.
pub fn tally_and_replay_judge_alike_test() {
  let db = world.new().db
  let d = desk(ok_tool)
  let sampled =
    decisions.desk(
      decisions.point("design.point", wire.text())
        |> decisions.allowing(ApproveRejectOrCorrect),
      drives: fn(_) {
        Gated(name: "t", guard: fn(_, _) { Ok([]) }, execute: ok_tool)
      },
      under: fn(_) {
        Ok(policies.checked(
          1,
          [policy.When(policy.Always, Proceed(policy.PerCent(100), None))],
          policy.AnyoneHolding("nobody"),
        ))
      },
      over: memory.port(),
    )
  let echo_by = Rules("echo", "1")
  let approved = propose(db, d, "a", echo_by)
  let assert Ok(approved) = decide(db, d, approved.id, Approve)
  let corrected = propose(db, d, "b", echo_by)
  let assert Ok(corrected) =
    decide(db, d, corrected.id, Correct("z", Reason("x", None)))
  let rejected = propose(db, d, "c", echo_by)
  let assert Ok(rejected) =
    decide(db, d, rejected.id, Reject(Reason("no", None)))
  let own = propose(db, d, "d", Person("caio"))
  let reviewed = propose(db, sampled, "e", echo_by)
  let assert Ok(reviewed) =
    memory.transaction(db, fn(tx) {
      use card <- result.try(
        decisions.open(sampled, tx, reviewed.id, by: bia, latest: fn(r: Ref) {
          r.revision
        }),
      )
      decisions.review(sampled, tx, card, Reject(Reason("wrong", None)))
    })
  let recorded = [approved, corrected, rejected, own, reviewed]

  let tally = learning.total(learning.tally(recorded))
  let archive =
    Archive(
      render: fn(_) { Ok("r") },
      reads: fn(_) { [] },
      content: fn(ref: Ref) { Ok(ref.id) },
    )
  let far = timestamp.add(world.t0(), duration.hours(10))
  let assert Ok(examples) =
    list.try_map(recorded, learning.example(_, as_of: far, from: archive))
  let replay = learning.replay(examples, echoing(), same: fn(a, b) { a == b })
  // Judged: the approval, the correction and the own act. The rejection
  // and the rejecting review let nothing through.
  assert #(tally.agreed, tally.judged, tally.rejected) == #(2, 3, 2)
  assert #(replay.tally.agreed, replay.tally.judged, replay.tally.rejected)
    == #(tally.agreed, tally.judged, tally.rejected)
}
