//// What building the two adapters showed the core must say: who may not
//// decide, the clock's resolution, contention, and how a runtime
//// classifies a refusal.

import decisions.{Gated}
import decisions/memory.{type Memory}
import decisions/policy.{
  AnyoneHolding, Either, Never, Proceed, Several, SomeoneElseHolding,
}
import decisions/store
import decisions/testing
import decisions/vocabulary.{
  Approve, Manifest, Person, Recommendation, Ref, RuleFired, Rules, Subject,
  Trigger, Validator,
}
import decisions/wire
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/time/duration
import gleam/time/timestamp
import support/policies
import support/world

fn tool() {
  Gated(name: "t", guard: fn(_, _) { Ok([]) }, execute: fn(_, _) { Ok(Nil) })
}

fn desk_over(port, p) -> decisions.Desk(String, Memory) {
  decisions.desk(
    decisions.point("feedback.point", wire.text())
      |> decisions.valid_for(duration.hours(1)),
    drives: fn(_) { tool() },
    under: fn(_) { Ok(p) },
    over: port,
  )
}

fn proposal(by) {
  decisions.proposal(
    trigger: Trigger("t", "1"),
    about: Subject("company", "x"),
    context: Manifest([Ref("m", "1", "1")], "r"),
    recommending: Recommendation("100", by, RuleFired("r"), [], []),
  )
}

fn head_of(db: Memory, id: String) -> store.Head {
  let assert Ok(head) = list.key_find(memory.heads(db), id)
  head
}

/// 1. The head names who may not decide, and the queue leaves their cards
/// out.
pub fn the_head_says_who_may_not_decide_test() {
  let felipe = Validator("felipe", ["finance", "managers"])
  let bia = Validator("bia", ["finance"])
  let ask = fn(eligible) {
    let db = world.new().db
    let desk = desk_over(memory.port(), policies.checked(1, [], eligible))
    let assert Ok(w) =
      memory.transaction(db, decisions.recommend(
        desk,
        _,
        proposal(Person("caio")) |> decisions.asked_by("felipe"),
      ))
    #(db, desk, w)
  }
  let #(db, _, w) = ask(SomeoneElseHolding("finance"))
  assert head_of(db, w.id).may_not_decide == ["felipe", "caio"]
  assert memory.queue_for(db, felipe) == []
  assert memory.queue_for(db, bia) == [w.id]

  // Anyone may decide as a manager, so nobody is barred outright.
  let #(db, _, w) =
    ask(Either([SomeoneElseHolding("finance"), AnyoneHolding("managers")]))
  assert head_of(db, w.id).may_not_decide == []
  assert memory.queue_for(db, felipe) == [w.id]

  // Under `Several`, an approver may not decide that output again.
  let #(db, desk, w) = ask(Several(2, SomeoneElseHolding("finance")))
  let assert Ok(_) =
    memory.transaction(db, world.open_and_decide(desk, _, w.id, bia, Approve))
  assert head_of(db, w.id).may_not_decide == ["felipe", "caio", "bia"]
  assert memory.queue_for(db, bia) == []
  let assert Ok(_) =
    testing.check(db, memory.inspection(), [testing.audit_record(desk)])
}

/// 2. A clock with microseconds is reduced to whole milliseconds, so the
/// wake-ups and the head match the record exactly.
pub fn a_finer_clock_is_kept_in_whole_milliseconds_test() {
  let db = world.new().db
  let base = memory.port()
  let whole = fn(at) { wire.from_milliseconds(wire.milliseconds(at)) == at }
  // The port sees what the desk hands it, before any storage rounds it.
  let fine =
    store.Port(
      ..base,
      now: fn(tx) {
        base.now(tx)
        |> result.map(timestamp.add(_, duration.nanoseconds(123_456_000)))
      },
      schedule: fn(tx, point, id, at) {
        let _ = case list.all(at, whole) {
          True -> Nil
          False -> world.push(tx, "fractional", "schedule")
        }
        base.schedule(tx, point, id, at)
      },
      append: fn(tx, id, head, entries) {
        let _ = case
          list.all(entries, fn(stored: store.Stored) { whole(stored.at) })
        {
          True -> Nil
          False -> world.push(tx, "fractional", "append")
        }
        base.append(tx, id, head, entries)
      },
    )
  let desk = desk_over(fine, policies.checked(1, [], AnyoneHolding("finance")))
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(
      desk,
      _,
      proposal(Rules("r", "1")),
    ))
  assert world.all(db, "fractional") == []
  assert list.all(w.entries, fn(entry) { whole(entry.at) })
  assert list.all(memory.wakes(db), fn(wake) { whole(wake.at) })
  let assert Ok(_) =
    testing.check(db, memory.inspection(), [testing.audit_record(desk)])
}

/// A store whose clock cannot be read reports the clock's error, and
/// nothing is written at a time the store did not give.
pub fn a_clock_that_fails_is_the_store_failing_test() {
  let db = world.new().db
  let base = memory.port()
  let failing =
    store.Port(..base, now: fn(_) {
      Error(store.Contended("the clock read was cancelled"))
    })
  let desk =
    desk_over(failing, policies.checked(1, [], AnyoneHolding("finance")))
  let assert Error(refusal) =
    memory.transaction(db, decisions.recommend(
      desk,
      _,
      proposal(Rules("r", "1")),
    ))
  assert refusal
    == decisions.StoreFailed(store.Contended("the clock read was cancelled"))
  assert memory.heads(db) == []
}

/// A lock timeout is a whole number of milliseconds, at least one: zero,
/// which PostgreSQL reads as "wait for ever", and a negative wait cannot
/// be asked for.
pub fn a_lock_timeout_is_at_least_one_millisecond_test() {
  assert store.lock_timeout(milliseconds: 0) == Error(Nil)
  assert store.lock_timeout(milliseconds: -5) == Error(Nil)
  let assert Ok(timeout) = store.lock_timeout(milliseconds: 1)
  assert store.lock_timeout_milliseconds(timeout) == 1
}

/// 3. Contention says nothing was written and a retry is safe.
pub fn contention_is_its_own_store_error_test() {
  let db = world.new().db
  let base = memory.port()
  let contended =
    store.Port(..base, append: fn(_, _, _, _) {
      Error(store.Contended("deadlock detected"))
    })
  let desk =
    desk_over(
      contended,
      policies.checked(
        1,
        [policy.When(policy.Always, Proceed(Never, None))],
        policy.AnyoneHolding("nobody"),
      ),
    )
  let assert Error(refusal) =
    memory.transaction(db, decisions.recommend(
      desk,
      _,
      proposal(Rules("r", "1")),
    ))
  assert refusal == decisions.StoreFailed(store.Contended("deadlock detected"))
  assert decisions.disposition(refusal) == decisions.Transient
  assert memory.heads(db) == []
}

/// 4. Every refusal has a disposition a runtime can act on.
pub fn every_refusal_is_classified_test() {
  // A real `ToolRefused`, with the token only the desk makes.
  let db = world.new().db
  let refusing =
    decisions.desk(
      decisions.point("feedback.point", wire.text()),
      drives: fn(_) {
        Gated(..tool(), execute: fn(_, _) { Error(vocabulary.Refuse("closed")) })
      },
      under: fn(_) { Ok(policies.checked(1, [], AnyoneHolding("finance"))) },
      over: memory.port(),
    )
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(
      refusing,
      _,
      proposal(Rules("r", "1")),
    ))
  let assert Error(tool_refused) =
    memory.transaction(db, world.open_and_decide(
      refusing,
      _,
      w.id,
      Validator("bia", ["finance"]),
      Approve,
    ))
  let expected = [
    #(decisions.StoreFailed(store.Contended("x")), decisions.Transient),
    #(decisions.StoreFailed(store.Unavailable("x")), decisions.Transient),
    #(decisions.StoreFailed(store.Conflict("x")), decisions.Retry),
    #(decisions.NoPolicy("x"), decisions.Retry),
    #(decisions.ConsultFailed("risk", "x"), decisions.Retry),
    #(decisions.ToolUnsure("x"), decisions.Retry),
    #(decisions.Unreadable("x"), decisions.Poisoned),
    #(decisions.Unpublishable([]), decisions.Poisoned),
    #(decisions.InvalidFacts([]), decisions.Poisoned),
    #(decisions.Unencodable("x"), decisions.Poisoned),
    #(decisions.KeyTaken("other"), decisions.Poisoned),
    #(decisions.UnknownOccurrence, decisions.Final),
    #(decisions.NotRecommended([]), decisions.Final),
    #(decisions.NotAwaiting, decisions.Final),
    #(decisions.AlreadyDecided("bia"), decisions.Final),
    #(decisions.NotEligible, decisions.Final),
    #(decisions.VerdictNotAllowed, decisions.Final),
    #(decisions.ReasonRequired, decisions.Final),
    #(decisions.NoteRequired, decisions.Final),
    #(decisions.NeverShown, decisions.Final),
    #(decisions.OutputChanged, decisions.Final),
    #(decisions.NotHeld, decisions.Final),
    #(decisions.NotTheDecider, decisions.Final),
    #(decisions.NotReleased, decisions.Final),
    #(decisions.NotSampled, decisions.Final),
    #(decisions.NotSettled, decisions.Final),
    #(decisions.NotConsulting, decisions.Final),
    #(tool_refused, decisions.Final),
  ]
  list.each(expected, fn(pair) {
    assert decisions.disposition(pair.0) == pair.1
  })
  // Twenty-six refusal variants, one of them in three store errors.
  assert list.length(expected) == 28
  let assert decisions.ToolRefused(..) = tool_refused
}
