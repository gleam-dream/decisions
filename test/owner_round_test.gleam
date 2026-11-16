//// The owner's round: the undo window in the policy, a held occurrence
//// superseded, work in flight expected, and four tracker frictions.

import decisions.{type Desk, Gated}
import decisions/learning
import decisions/memory.{type Memory}
import decisions/model
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Ask, Never, Policy, Proceed}
import decisions/store
import decisions/testing
import decisions/vocabulary.{
  Agent, Approve, Manifest, Recommendation, Ref, RuleFired, Subject, Superseded,
  Trigger, Validator,
}
import decisions/wire
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration
import gleam/time/timestamp
import support/world

const ana = Validator("ana", ["finance"])

const subject = Subject("company", "clinica-x")

fn tool() {
  Gated(name: "pay", guard: fn(_, _) { Ok([]) }, execute: fn(tx, released) {
    world.push(tx, "paid", decisions.output(released))
    Ok(Nil)
  })
}

fn point() {
  decisions.point("owner.payout", wire.text())
  |> decisions.superseded_by("newer_request")
}

fn desk(point, p) -> Desk(String, Memory) {
  decisions.desk(
    point,
    drives: fn(_) { tool() },
    under: fn(_) { Ok(p) },
    over: memory.port(),
  )
}

fn proposal(output: String) {
  decisions.proposal(
    trigger: Trigger("request", output),
    about: subject,
    context: Manifest([], "r"),
    recommending: Recommendation(
      output,
      Agent("treasury", "2"),
      RuleFired("r"),
      [],
      [],
    ),
  )
}

fn audit(db: Memory, d) {
  let assert Ok(_) =
    testing.check(db, memory.inspection(), [
      testing.audit(d, effects: fn(tx) {
        Ok(list.length(world.all(tx, "paid")))
      }),
    ])
  Nil
}

fn supersede(db: Memory, d) {
  memory.transaction(db, decisions.happened(
    d,
    _,
    "newer_request",
    about: subject,
  ))
}

fn undo_window() {
  Policy(1, [], Proceed(Never, Some(duration.minutes(30))))
}

// -- 1. The undo window in the policy -------------------------------------------

pub fn a_proceed_hold_is_stored_with_the_policy_and_checked_test() {
  let p = undo_window()
  assert json.parse(json.to_string(policy.to_json(p)), policy.decoder())
    == Ok(p)
  // A stored policy without it has no hold.
  let stored =
    "{\"version\":1,\"rules\":[],\"otherwise\":{\"t\":\"proceed\",\"sample\":null}}"
  assert json.parse(stored, policy.decoder())
    == Ok(Policy(1, [], Proceed(Never, None)))
  assert policy.check(
      Policy(1, [], Proceed(Never, Some(duration.seconds(0)))),
      declared: [],
    )
    == Error([policy.NonPositiveHold(0)])
}

pub fn a_policy_hold_holds_only_what_the_policy_lets_proceed_test() {
  let db = world.new().db
  let d =
    desk(
      point(),
      Policy(
        1,
        [policy.When(policy.OwnAct, Ask(AnyoneHolding("finance")))],
        Proceed(Never, Some(duration.minutes(30))),
      ),
    )
  let assert Ok(by_policy) =
    memory.transaction(db, decisions.recommend(d, _, proposal("80")))
  let assert occurrence.Held(until:, ..) = by_policy.status
  assert until == timestamp.add(world.t0(), duration.minutes(30))
  // A person's own act asks finance; finance's approval is released at once.
  let own =
    decisions.proposal(
      trigger: Trigger("request", "own"),
      about: subject,
      context: Manifest([], "r"),
      recommending: Recommendation(
        "90",
        vocabulary.Person("caio"),
        vocabulary.OwnAct,
        [],
        [],
      ),
    )
  let assert Ok(asked) = memory.transaction(db, decisions.recommend(d, _, own))
  let assert Ok(released) =
    memory.transaction(db, world.open_and_decide(d, _, asked.id, ana, Approve))
  let assert occurrence.Released(..) = released.status
}

// -- 2. A held occurrence superseded ---------------------------------------------------

pub fn a_held_policy_proceed_is_superseded_and_releases_nothing_test() {
  let db = world.new().db
  let d = desk(point() |> decisions.withdrawn_by("finance"), undo_window())
  let assert Ok(held) =
    memory.transaction(db, decisions.recommend(d, _, proposal("80")))
  let assert occurrence.Held(..) = held.status
  let assert Ok(decisions.Supersession(expired: [superseded], ..)) =
    supersede(db, d)
  assert superseded.status == occurrence.Expired(Superseded("newer_request"))
  assert memory.wakes(db) == []
  memory.set_clock(db, timestamp.add(world.t0(), duration.hours(1)))
  assert memory.transaction(db, decisions.wake(d, _, occurrence: held.id))
    == Ok(decisions.NothingDue)
  assert world.all(db, "paid") == []
  // Withdrawing it now is refused: it is no longer held.
  assert memory.transaction(db, decisions.withdraw_as(
      d,
      _,
      occurrence: held.id,
      by: ana,
    ))
    |> result.replace(Nil)
    == Error(decisions.NotHeld)
  // Learning does not judge an acceptance superseded before its release.
  assert learning.total(learning.tally([superseded])).judged == 0
  audit(db, d)
}

pub fn a_held_human_approval_is_superseded_and_released_never_test() {
  let db = world.new().db
  let d =
    desk(
      point() |> decisions.with_hold(duration.minutes(10)),
      Policy(1, [], Ask(AnyoneHolding("finance"))),
    )
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(d, _, proposal("80")))
  let assert Ok(held) =
    memory.transaction(db, world.open_and_decide(d, _, w.id, ana, Approve))
  let assert occurrence.Held(..) = held.status
  let assert Ok(decisions.Supersession(expired: [superseded], ..)) =
    supersede(db, d)
  let assert occurrence.Expired(Superseded(_)) = superseded.status
  assert memory.transaction(db, decisions.withdraw(
      d,
      _,
      occurrence: w.id,
      by: "ana",
    ))
    |> result.replace(Nil)
    == Error(decisions.NotHeld)
  assert world.all(db, "paid") == []
  audit(db, d)
}

pub fn a_released_occurrence_is_not_superseded_test() {
  let db = world.new().db
  let d = desk(point(), Policy(1, [], Proceed(Never, None)))
  let assert Ok(released) =
    memory.transaction(db, decisions.recommend(d, _, proposal("80")))
  let assert occurrence.Released(..) = released.status
  assert supersede(db, d)
    == Ok(decisions.Supersession(expired: [], not_begun: [], unreadable: []))
  audit(db, d)
}

// -- 4. Work in flight is expected ---------------------------------------------------

fn admit(db: Memory, d, key: String) {
  memory.transaction(db, decisions.expect(
    d,
    _,
    key:,
    trigger: Trigger("request", key),
    about: subject,
  ))
}

fn commit(db: Memory, d, key: String) {
  memory.transaction(db, decisions.recommend_once(
    d,
    _,
    key:,
    proposal: proposal(key),
  ))
}

pub fn an_expected_key_superseded_while_the_model_runs_is_refused_test() {
  let db = world.new().db
  let d = desk(point(), Policy(1, [], Proceed(Never, None)))
  let assert Ok(Nil) = admit(db, d, "owner:req-1")
  // While the model runs for req-1, req-2 arrives.
  let assert Ok(decisions.Supersession(
    expired: [],
    not_begun: ["owner:req-1"],
    unreadable: [],
  )) = supersede(db, d)
  // The model for req-1 finishes: refused, nothing written or released.
  let before = memory.entries(db, "owner:req-1")
  assert commit(db, d, "owner:req-1") |> result.replace(Nil)
    == Error(decisions.SupersededBefore("newer_request"))
  assert memory.entries(db, "owner:req-1") == before
  assert world.all(db, "paid") == []
  assert decisions.disposition(decisions.SupersededBefore("x"))
    == decisions.Final
  let assert Ok(head) = list.key_find(memory.heads(db), "owner:req-1")
  assert head.status == store.Expired
  audit(db, d)
}

pub fn a_failed_attempt_in_between_changes_nothing_test() {
  let db = world.new().db
  let d = desk(point(), Policy(1, [], Proceed(Never, None)))
  let assert Ok(Nil) = admit(db, d, "owner:req-3")
  let assert Ok([_]) =
    memory.transaction(db, decisions.record_failure(
      d,
      _,
      key: "owner:req-3",
      trigger: Trigger("request", "req-3"),
      about: subject,
      failure: model.Raised("crash"),
    ))
  let assert Ok(decisions.Supersession(not_begun: ["owner:req-3"], ..)) =
    supersede(db, d)
  assert memory.transaction(db, decisions.record_failure(
      d,
      _,
      key: "owner:req-3",
      trigger: Trigger("request", "req-3"),
      about: subject,
      failure: model.Raised("again"),
    ))
    |> result.replace(Nil)
    == Error(decisions.SupersededBefore("newer_request"))
  assert commit(db, d, "owner:req-3") |> result.replace(Nil)
    == Error(decisions.SupersededBefore("newer_request"))
  audit(db, d)
}

pub fn expect_is_safe_to_repeat_and_then_recommends_test() {
  let db = world.new().db
  let d = desk(point(), Policy(1, [], Ask(AnyoneHolding("finance"))))
  let assert Ok(Nil) = admit(db, d, "owner:req-4")
  let assert Ok(Nil) = admit(db, d, "owner:req-4")
  assert list.length(memory.entries(db, "owner:req-4")) == 1
  let assert Ok(head) = list.key_find(memory.heads(db), "owner:req-4")
  assert head.status == store.Pending
  audit(db, d)
  let assert Ok(w) = commit(db, d, "owner:req-4")
  assert occurrence.was_expected(w)
  assert list.map(w.entries, fn(e) { e.seq }) == [1, 2, 3]
  // On a recommended key it does nothing.
  let assert Ok(Nil) = admit(db, d, "owner:req-4")
  assert list.length(memory.entries(db, "owner:req-4")) == 3
  // Coverage over the records.
  let assert Ok(Nil) = admit(db, d, "owner:req-5")
  let read = fn(key) {
    let assert Ok(record) =
      memory.transaction(db, decisions.read_record(d, _, key:))
    record
  }
  assert learning.coverage([read("owner:req-4"), read("owner:req-5")])
    == learning.Coverage(expected: 2, superseded_before: 0, still_expected: 1)
  audit(db, d)
}

// -- 5, 6, 7. Tracker frictions -------------------------------------------------------

pub fn the_account_of_a_release_carries_its_key_test() {
  let db = world.new().db
  let d = desk(point(), Policy(1, [], Proceed(Never, None)))
  let assert Ok(released) =
    memory.transaction(db, decisions.recommend(d, _, proposal("80")))
  assert occurrence.account(released)
    == occurrence.Done(
      final: "80",
      key: "release:" <> released.id,
      effect: None,
    )
}

pub fn a_candidate_is_judged_under_a_candidate_policy_test() {
  let db = world.new().db
  let d = desk(point(), Policy(1, [], Ask(AnyoneHolding("finance"))))
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(d, _, proposal("80")))
  let assert Ok(done) =
    memory.transaction(db, world.open_and_decide(d, _, w.id, ana, Approve))
  let assert Ok(example) =
    learning.example(
      done,
      as_of: memory.now(db),
      from: learning.Archive(
        render: fn(_) { Ok("r") },
        reads: fn(_) { [] },
        content: fn(_) { Ok("x") },
      ),
    )
  let candidate =
    model.new(fn(_, _) {
      Ok(Recommendation("75", Agent("treasury", "3"), RuleFired("r"), [], []))
    })
  let assert Ok(#(recommended, outcome)) =
    learning.candidate_under(
      example,
      candidate:,
      policy: Policy(2, [], Proceed(Never, None)),
      point: point(),
    )
  assert recommended.output == "75"
  assert outcome == Proceed(Never, None)
}

pub fn a_model_failure_carries_its_evidence_onto_the_attempt_test() {
  let db = world.new().db
  let d = desk(point(), Policy(1, [], Ask(AnyoneHolding("finance"))))
  let exchange = Ref("llm_exchange", "call-1", "abc")
  let failure = model.with_evidence(model.Undecodable("not JSON"), [exchange])
  assert model.retryable(failure)
  assert model.evidence_of(failure) == [exchange]
  let assert Ok([attempt]) =
    memory.transaction(db, decisions.record_failure(
      d,
      _,
      key: "owner:req-9",
      trigger: Trigger("request", "req-9"),
      about: subject,
      failure:,
    ))
  assert attempt.failure == model.Undecodable("not JSON")
  assert attempt.evidence == [exchange]
}
