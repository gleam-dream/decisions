//// The second independent review of the core (R1 to R12): each probe
//// scenario turned around, so it fails without its correction, and the
//// reviewer's sound scenarios kept as tests.

import decisions.{type Desk, Gated}
import decisions/learning
import decisions/memory.{type Memory}
import decisions/occurrence
import decisions/policy.{
  All, AnyoneHolding, Ask, Consult, Either, Never, Not, Proceed, Several,
  SomeoneElseHolding, When,
}
import decisions/store
import decisions/view
import decisions/vocabulary.{
  type Ref, Approve, ApproveRejectOrCorrect, Manifest, Recommendation, Ref,
  RuleFired, Rules, Subject, Trigger, Validator,
}
import decisions/wire
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/time/duration
import gleam/time/timestamp
import support/policies
import support/world

const ana = Validator("ana", ["finance"])

const bia = Validator("bia", ["finance"])

fn tool() {
  Gated(name: "t", guard: fn(_, _) { Ok([]) }, execute: fn(tx, released) {
    world.push(tx, "effects", decisions.output(released))
    Ok(Nil)
  })
}

fn desk_on(point, p) -> Desk(String, Memory) {
  decisions.desk(
    point,
    drives: fn(_) { tool() },
    under: fn(_) { Ok(p) },
    over: memory.port(),
  )
}

fn base_point() {
  decisions.point("fr.point", wire.text())
  |> decisions.allowing(ApproveRejectOrCorrect)
}

fn proposal(output: String) {
  decisions.proposal(
    trigger: Trigger("t", output),
    about: Subject("company", "x"),
    context: Manifest(refs: [Ref("m", "1", "1")], renderer: "r"),
    recommending: Recommendation(
      output:,
      by: Rules("r", "1"),
      explanation: RuleFired("r"),
      signals: [],
      reads: [],
    ),
  )
}

fn fresh() -> Memory {
  world.new().db
}

fn same(ref: Ref) -> String {
  ref.revision
}

fn at(db: Memory, minutes: Int) -> Nil {
  memory.set_clock(db, timestamp.add(world.t0(), duration.minutes(minutes)))
}

fn recommend(db: Memory, desk, output: String) {
  memory.transaction(db, decisions.recommend(desk, _, proposal(output)))
}

fn approve(db: Memory, desk, id, v) {
  memory.transaction(db, fn(tx) {
    use card <- result.try(decisions.open(desk, tx, id, by: v, latest: same))
    decisions.decide(desk, tx, card, Approve)
  })
}

fn effects(db: Memory) -> List(String) {
  world.all(db, "effects")
}

/// R1. A `Several` inside a `Several`, and an empty `Either`, cannot be
/// built.
pub fn r1_nested_several_and_empty_either_cannot_be_built_test() {
  assert policy.new(1, [], Several(1, Several(3, AnyoneHolding("finance"))))
    == Error([policy.NestedSeveral])
  assert policy.new(
      1,
      [],
      Several(2, Either([Several(3, AnyoneHolding("f")), AnyoneHolding("h")])),
    )
    == Error([policy.NestedSeveral])
  assert policy.new(1, [], Either([])) == Error([policy.EmptyEither])
  assert policy.new(
      1,
      [When(policy.Always, Ask(Either([])))],
      AnyoneHolding("f"),
    )
    == Error([policy.EmptyEither])
}

/// R2. A late wake-up reaches the outcome an on-time one would have.
pub fn r2_a_late_wake_up_skips_no_step_that_accepts_test() {
  let ladder =
    policies.checked(
      1,
      [
        When(
          All([policy.waited(30), Not(policy.waited(60))]),
          Proceed(Never, None),
        ),
      ],
      AnyoneHolding("finance"),
    )
  let desk = desk_on(base_point(), ladder)
  let db = fresh()
  let assert Ok(w) = recommend(db, desk, "a")
  at(db, 61)
  let assert Ok(decisions.Woken(late)) =
    memory.transaction(db, decisions.wake(desk, _, w.id))
  let assert occurrence.Released(..) = late.status
  assert effects(db) == ["a"]
}

/// R3. The release check sees a `ToRelease`; the `Released` exists only
/// inside the attempt. (The compile-time half is the negative fixture
/// `a_release_check_value_to_an_executor`.)
pub fn r3_the_check_sees_what_is_about_to_be_released_test() {
  let db = fresh()
  let desk =
    desk_on(
      base_point(),
      policies.checked(
        1,
        [policy.When(policy.Always, Proceed(Never, None))],
        policy.AnyoneHolding("nobody"),
      ),
    )
    |> decisions.checking(with: fn(tx, release: decisions.ToRelease(String)) {
      world.push(tx, "checked", release.output <> "@" <> release.key)
      Error(decisions.Refuse("balance does not cover"))
    })
  let assert Ok(w) = recommend(db, desk, "500")
  assert w.status == occurrence.Refused("balance does not cover")
  assert effects(db) == []
}

/// R4. Lost work and endless redelivery are classified so a runtime can
/// act: counted retries, operator work set aside, contention alone
/// redelivered uncounted.
pub fn r4_disposition_neither_loses_work_nor_loops_test() {
  let db = fresh()
  let p =
    policies.checked(
      1,
      [When(policy.waited(30), Consult("other.point"))],
      AnyoneHolding("finance"),
    )
  let desk = desk_on(base_point(), p)
  let assert Ok(w) = recommend(db, desk, "a")
  at(db, 31)
  let assert Error(refusal) =
    memory.transaction(db, decisions.wake(desk, _, w.id))
  let assert decisions.ConsultFailed(..) = refusal
  // Counted, so a runtime sets it aside once its attempts are used.
  assert decisions.handling(decisions.DeskRefused(refusal)) == decisions.Backoff
  // Work that needs an operator is set aside, never dropped.
  list.each(
    [
      decisions.Unpublishable([]),
      decisions.InvalidFacts([]),
      decisions.Unencodable("x"),
      decisions.Unreadable("x"),
    ],
    fn(refusal) {
      assert decisions.handling(decisions.DeskRefused(refusal))
        == decisions.SetAside
    },
  )
  assert decisions.handling(decisions.DeskRefused(decisions.NoPolicy("x")))
    == decisions.Backoff
  assert decisions.handling(
      decisions.DeskRefused(decisions.StoreFailed(store_conflict())),
    )
    == decisions.Backoff
}

fn store_conflict() {
  store.Conflict("again")
}

/// R5. `open` applies the rule `decide` applies.
pub fn r5_open_refuses_whom_decide_would_refuse_test() {
  let db = fresh()
  let p =
    policies.checked(
      1,
      [],
      Either([SomeoneElseHolding("finance"), AnyoneHolding("head")]),
    )
  let desk = desk_on(base_point(), p)
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(
      desk,
      _,
      proposal("100") |> decisions.asked_by("ana"),
    ))
  assert memory.transaction(db, decisions.open(
      desk,
      _,
      w.id,
      by: ana,
      latest: same,
    ))
    |> result.replace(Nil)
    == Error(decisions.NotEligible)
  assert list.length(memory.entries(db, w.id)) == 2
}

/// R6. A step that asks for what the standing approvals already meet
/// accepts.
pub fn r6_a_step_re_evaluates_the_standing_approvals_test() {
  let db = fresh()
  let p =
    policies.checked(
      1,
      [When(policy.waited(60), Ask(AnyoneHolding("finance")))],
      Several(2, AnyoneHolding("finance")),
    )
  let desk = desk_on(base_point(), p)
  let assert Ok(w) = recommend(db, desk, "100")
  at(db, 10)
  let assert Ok(after_ana) = approve(db, desk, w.id, ana)
  let assert occurrence.Awaiting(..) = after_ana.status
  at(db, 61)
  let assert Ok(decisions.Woken(woken)) =
    memory.transaction(db, decisions.wake(desk, _, w.id))
  let assert occurrence.Released(by: occurrence.ByValidator("ana"), ..) =
    woken.status
  assert effects(db) == ["100"]
}

/// R7. An occurrence that expired after a partial approval was not decided.
pub fn r7_an_expired_partial_quorum_is_not_already_decided_test() {
  let db = fresh()
  let desk =
    desk_on(
      base_point() |> decisions.valid_for(duration.minutes(30)),
      policies.checked(1, [], Several(2, AnyoneHolding("finance"))),
    )
  let assert Ok(w) = recommend(db, desk, "100")
  let assert Ok(_) = approve(db, desk, w.id, ana)
  at(db, 31)
  let assert Ok(decisions.Woken(expired)) =
    memory.transaction(db, decisions.wake(desk, _, w.id))
  assert memory.transaction(db, decisions.open(
      desk,
      _,
      w.id,
      by: bia,
      latest: same,
    ))
    |> result.replace(Nil)
    == Error(decisions.NotAwaiting)
  assert occurrence.decided_by(expired) == option.None
}

/// R8. The card reports every way the occurrence can still be accepted.
pub fn r8_the_card_reports_approvals_per_alternative_test() {
  let db = fresh()
  let p =
    policies.checked(
      1,
      [],
      Either([Several(2, AnyoneHolding("finance")), AnyoneHolding("head")]),
    )
  let desk = desk_on(base_point(), p)
  let assert Ok(w) = recommend(db, desk, "100")
  let assert Ok(_) = approve(db, desk, w.id, ana)
  let assert Ok(card) =
    memory.transaction(db, decisions.open(desk, _, w.id, by: bia, latest: same))
  let shown = view.of(card, content: fn(_) { Ok("") })
  assert shown.approvals
    == view.Approvals(by: ["ana"], alternatives: [
      view.Alternative(sets: ["finance"], have: 1, need: 2),
      view.Alternative(sets: ["head"], have: 0, need: 1),
    ])
}

/// R9. Nothing let through to acceptance is judged.
pub fn r9_the_tally_judges_only_what_people_let_through_test() {
  let db = fresh()
  let quorum =
    desk_on(
      base_point() |> decisions.valid_for(duration.minutes(30)),
      policies.checked(1, [], Several(2, AnyoneHolding("finance"))),
    )
  let assert Ok(w) = recommend(db, quorum, "100")
  let assert Ok(_) = approve(db, quorum, w.id, ana)
  at(db, 31)
  let assert Ok(decisions.Woken(expired)) =
    memory.transaction(db, decisions.wake(quorum, _, w.id))
  let held =
    desk_on(
      base_point() |> decisions.with_hold(duration.hours(1)),
      policies.checked(1, [], AnyoneHolding("finance")),
    )
  let assert Ok(h) = recommend(db, held, "200")
  let assert Ok(_) = approve(db, held, h.id, ana)
  let assert Ok(withdrawn) =
    memory.transaction(db, decisions.withdraw(
      held,
      _,
      occurrence: h.id,
      by: "ana",
    ))
  let tally = learning.total(learning.tally([expired, withdrawn]))
  assert #(tally.judged, tally.agreed, tally.rejected) == #(0, 0, 0)
}

/// R10. A guard that could not tell refuses nothing for good: the wake-up
/// fails, nothing is recorded, and a later wake-up releases.
pub fn r10_an_unsure_guard_at_a_wake_up_is_tried_again_test() {
  let db = fresh()
  let desk =
    decisions.desk(
      base_point() |> decisions.with_hold(duration.minutes(5)),
      drives: fn(_) {
        Gated(..tool(), guard: fn(tx, _) {
          case memory.get(tx, "db_down") {
            Ok(_) -> Error(decisions.Unsure("connection reset"))
            Error(_) -> Ok([])
          }
        })
      },
      under: fn(_) { Ok(policies.checked(1, [], AnyoneHolding("finance"))) },
      over: memory.port(),
    )
  let assert Ok(w) = recommend(db, desk, "100")
  let assert Ok(_) = approve(db, desk, w.id, ana)
  memory.put(db, "db_down", "1")
  at(db, 6)
  let before = memory.entries(db, w.id)
  let assert Error(refusal) =
    memory.transaction(db, decisions.wake(desk, _, w.id))
  assert refusal == decisions.ToolUnsure("connection reset")
  assert decisions.handling(decisions.DeskRefused(refusal)) == decisions.Backoff
  assert memory.entries(db, w.id) == before
  // The database is back: the same tool, its guard answering again.
  let assert Ok(decisions.Woken(done)) =
    memory.transaction(db, decisions.wake(up_desk(), _, w.id))
  let assert occurrence.Released(..) = done.status
}

fn up_desk() -> Desk(String, Memory) {
  decisions.desk(
    base_point() |> decisions.with_hold(duration.minutes(5)),
    drives: fn(_) { tool() },
    under: fn(_) { Ok(policies.checked(1, [], AnyoneHolding("finance"))) },
    over: memory.port(),
  )
}

/// R12. Approvals of different alternatives do not add up, and a person
/// holding both sets counts once (the reviewer's s1).
pub fn r12_cross_alternative_approvals_do_not_add_up_test() {
  let p =
    policies.checked(
      1,
      [],
      Either([Several(2, AnyoneHolding("a")), Several(2, AnyoneHolding("b"))]),
    )
  let desk = desk_on(base_point(), p)
  let db = fresh()
  let assert Ok(w) = recommend(db, desk, "1")
  let assert Ok(_) = approve(db, desk, w.id, Validator("x", ["a"]))
  let assert Ok(after) = approve(db, desk, w.id, Validator("y", ["b"]))
  let assert occurrence.Awaiting(..) = after.status
  let db = fresh()
  let assert Ok(w) = recommend(db, desk, "1")
  let assert Ok(one) = approve(db, desk, w.id, Validator("z", ["a", "b"]))
  let assert occurrence.Awaiting(..) = one.status
  let assert Error(_) = approve(db, desk, w.id, Validator("z", ["a", "b"]))
}

/// R12. A requester's approval is not credited to the alternative that
/// excludes them (the reviewer's s2).
pub fn r12_the_requester_is_credited_only_where_admitted_test() {
  let p =
    policies.checked(
      1,
      [],
      Either([
        Several(2, SomeoneElseHolding("f")),
        Several(2, AnyoneHolding("h")),
      ]),
    )
  let desk = desk_on(base_point(), p)
  let db = fresh()
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(
      desk,
      _,
      proposal("1") |> decisions.asked_by("req"),
    ))
  let assert Ok(_) = approve(db, desk, w.id, Validator("req", ["f", "h"]))
  let assert Ok(after) = approve(db, desk, w.id, Validator("o", ["f"]))
  let assert occurrence.Awaiting(..) = after.status
}

/// R12. The guard, the release check and the executor run in that order.
pub fn r12_guard_check_then_executor_test() {
  let db = fresh()
  let desk =
    decisions.desk(
      base_point(),
      drives: fn(_) {
        Gated(
          name: "t",
          guard: fn(tx, _) {
            world.push(tx, "order", "guard")
            Ok([])
          },
          execute: fn(tx, _) {
            world.push(tx, "order", "execute")
            Ok(Nil)
          },
        )
      },
      under: fn(_) {
        Ok(policies.checked(
          1,
          [policy.When(policy.Always, Proceed(Never, None))],
          policy.AnyoneHolding("nobody"),
        ))
      },
      over: memory.port(),
    )
    |> decisions.checking(with: fn(tx, _) {
      world.push(tx, "order", "check")
      Ok([])
    })
  let assert Ok(_) = recommend(db, desk, "1")
  assert world.all(db, "order") == ["guard", "check", "execute"]
}

/// A desk on a held point whose tool's executor, or whose release check,
/// cannot tell while `db_down` is "1".
fn flaky_desk(in_tool: Bool) -> Desk(String, Memory) {
  let down = fn(tx) { memory.get(tx, "db_down") == Ok("1") }
  let desk =
    decisions.desk(
      base_point() |> decisions.with_hold(duration.minutes(5)),
      drives: fn(_) {
        Gated(..tool(), execute: fn(tx, released) {
          case in_tool && down(tx) {
            True -> Error(decisions.Unsure("connection reset"))
            False -> tool().execute(tx, released)
          }
        })
      },
      under: fn(_) { Ok(policies.checked(1, [], AnyoneHolding("finance"))) },
      over: memory.port(),
    )
  case in_tool {
    True -> desk
    False ->
      decisions.checking(desk, with: fn(tx, _) {
        case down(tx) {
          True -> Error(decisions.Unsure("balance unknown"))
          False -> Ok([])
        }
      })
  }
}

fn unsure_at_wake_up(in_tool: Bool, reason: String) -> Nil {
  let db = fresh()
  let desk = flaky_desk(in_tool)
  let assert Ok(w) = recommend(db, desk, "100")
  let assert Ok(_) = approve(db, desk, w.id, ana)
  memory.put(db, "db_down", "1")
  at(db, 6)
  let before = memory.entries(db, w.id)
  let assert Error(refusal) =
    memory.transaction(db, decisions.wake(desk, _, w.id))
  assert refusal == decisions.ToolUnsure(reason)
  assert decisions.handling(decisions.DeskRefused(refusal)) == decisions.Backoff
  assert memory.entries(db, w.id) == before
  assert effects(db) == []
  // Sure again: the next wake-up releases, once.
  memory.put(db, "db_down", "0")
  let assert Ok(decisions.Woken(done)) =
    memory.transaction(db, decisions.wake(desk, _, w.id))
  let assert occurrence.Released(..) = done.status
  assert memory.transaction(db, decisions.wake(desk, _, w.id))
    == Ok(decisions.NothingDue)
  assert effects(db) == ["100"]
}

/// R10. A tool whose executor could not tell at a hold's wake-up refuses
/// nothing for good: the wake-up fails, nothing is recorded, and a later
/// wake-up releases once.
pub fn r10_an_unsure_tool_at_a_wake_up_is_tried_again_test() {
  unsure_at_wake_up(True, "connection reset")
}

/// R10. Likewise for a release check that could not tell.
pub fn r10_an_unsure_release_check_at_a_wake_up_is_tried_again_test() {
  unsure_at_wake_up(False, "balance unknown")
}
