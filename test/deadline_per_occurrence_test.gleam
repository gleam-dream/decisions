//// An occurrence may carry its own deadline (ADR 0054): set on the
//// expectation or the proposal, written on the record, expired by the same
//// wake-up and decided by the store clock as a point's validity.

import decisions.{Gated}
import decisions/learning
import decisions/memory
import decisions/model
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Ask, Policy}
import decisions/store
import decisions/testing
import decisions/vocabulary.{
  Agent, Approve, DeadlinePassed, Manifest, Recommendation, RuleFired, Subject,
  Superseded, Trigger, Validator,
}
import decisions/wire
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import support/world.{type World}

const ana = Subject("party", "ana")

const key = "reply:m1"

const agent = Validator(subject: "felipe", holds: ["support"])

fn point() {
  decisions.point("deadline.reply", wire.text())
  |> decisions.superseded_by("newer_message")
}

fn desk_for(point) {
  decisions.desk(
    point,
    drives: fn(_) {
      Gated(name: "send", guard: fn(_, _) { Ok([]) }, execute: fn(_, _) {
        Ok(Nil)
      })
    },
    under: fn(_) { Ok(Policy(1, [], Ask(AnyoneHolding("support")))) },
    over: memory.port(),
  )
}

fn desk() {
  desk_for(point())
}

fn proposal() {
  decisions.proposal(
    trigger: Trigger("message", "m1"),
    about: ana,
    context: Manifest([], "r"),
    recommending: Recommendation(
      "Olá Ana",
      Agent("reply", "1"),
      RuleFired("r"),
      [],
      [],
    ),
  )
}

/// Monday 09:00:00 is `world.t0`; the window closes 24 hours later.
fn closes() -> Timestamp {
  timestamp.add(world.t0(), duration.hours(24))
}

fn at_seconds(w: World, seconds: Int) -> Nil {
  world.at(w, duration.seconds(seconds))
}

const day = 86_400

fn expect_until(w: World, until: Timestamp) {
  world.in_tx(w, decisions.expect_until(
    desk(),
    _,
    key:,
    trigger: Trigger("message", "m1"),
    about: ana,
    valid_until: until,
  ))
}

fn recommend(w: World, p) {
  world.in_tx(w, decisions.recommend_once(desk(), _, key:, proposal: p))
}

fn record_failure(w: World) {
  world.in_tx(w, decisions.record_failure(
    desk(),
    _,
    key:,
    trigger: Trigger("message", "m1"),
    about: ana,
    failure: model.Raised("provider timed out"),
  ))
}

fn wakers() {
  [decisions.waker(desk())]
}

fn head(w: World) -> store.Head {
  let assert Ok(head) = list.key_find(memory.heads(w.db), key)
  head
}

fn wake_times(w: World) -> List(Timestamp) {
  memory.wakes(w.db)
  |> list.filter(fn(wake) { wake.occurrence == key })
  |> list.map(fn(wake) { wake.at })
}

fn notices(w: World) -> Int {
  list.count(memory.notices(w.db), fn(notice) { notice.occurrence == key })
}

fn invariants(w: World) -> Nil {
  world.invariants_hold(w, [testing.audit_record(desk())])
}

fn read(w: World) {
  world.in_tx(w, decisions.read_record(desk(), _, key:))
}

// -- The worked case ----------------------------------------------------------

pub fn an_expected_occurrence_expires_at_its_own_deadline_test() {
  let w = world.new()
  let assert Ok(Nil) = expect_until(w, closes())
  // The record not begun is due at the deadline and has its wake-up.
  assert head(w).status == store.Pending
  assert head(w).due == Some(closes())
  assert wake_times(w) == [closes()]
  // The model answers 90 seconds later; the deadline does not move.
  at_seconds(w, 90)
  let assert Ok(known) = recommend(w, proposal())
  assert known.valid_until == Some(closes())
  assert head(w).due == Some(closes())
  assert wake_times(w) == [closes()]
  invariants(w)
  // At the deadline, before any wake-up, a card cannot be opened.
  at_seconds(w, day)
  assert world.in_tx(
      w,
      decisions.open(desk(), _, occurrence: key, by: agent, latest: fn(ref) {
        ref.revision
      }),
    )
    == Error(decisions.NotAwaiting)
  // The wake-up expires it as deadline passed.
  assert world.deliver_due(w, wakers()) == 1
  let assert Ok(decisions.Begun(expired)) = read(w)
  assert expired.status == occurrence.Expired(DeadlinePassed)
  assert notices(w) == 1
  assert wake_times(w) == []
  invariants(w)
}

pub fn a_verdict_one_second_after_the_deadline_is_refused_test() {
  let w = world.new()
  let assert Ok(Nil) = expect_until(w, closes())
  at_seconds(w, 90)
  let assert Ok(_) = recommend(w, proposal())
  let assert Ok(card) =
    world.in_tx(
      w,
      decisions.open(desk(), _, occurrence: key, by: agent, latest: fn(ref) {
        ref.revision
      }),
    )
  at_seconds(w, day + 1)
  assert world.in_tx(w, decisions.decide(desk(), _, card, Approve))
    == Error(decisions.NotAwaiting)
}

// -- A record that never begins ---------------------------------------------------

pub fn an_expected_record_whose_model_keeps_failing_expires_test() {
  let w = world.new()
  let assert Ok(Nil) = expect_until(w, closes())
  at_seconds(w, 60)
  let assert Ok([_]) = record_failure(w)
  at_seconds(w, 3600)
  let assert Ok([_, _]) = record_failure(w)
  assert head(w).due == Some(closes())
  // Early: the wake-up names the deadline.
  assert world.in_tx(w, decisions.wake(desk(), _, occurrence: key))
    == Ok(decisions.NotDue(closes()))
  at_seconds(w, day)
  assert world.deliver_due(w, wakers()) == 1
  let assert Ok(decisions.NotBegun(pending)) = read(w)
  assert pending.ended == Some(DeadlinePassed)
  assert head(w).status == store.Expired
  assert head(w).due == None
  assert notices(w) == 1
  invariants(w)
  // Nothing more is recorded under the key.
  let before = memory.entries(w.db, key)
  assert record_failure(w) == Error(decisions.DeadlinePassedBefore(closes()))
  assert expect_until(w, closes())
    == Error(decisions.DeadlinePassedBefore(closes()))
  assert memory.entries(w.db, key) == before
  // A wake-up delivered again does nothing.
  assert world.in_tx(w, decisions.wake(desk(), _, occurrence: key))
    == Ok(decisions.NothingDue)
}

pub fn the_clock_decides_without_the_wake_up_test() {
  let w = world.new()
  let assert Ok(Nil) = expect_until(w, closes())
  at_seconds(w, day)
  let before = memory.entries(w.db, key)
  assert record_failure(w) == Error(decisions.DeadlinePassedBefore(closes()))
  assert memory.entries(w.db, key) == before
}

// -- A late recommendation ----------------------------------------------------------

pub fn a_recommendation_after_the_expiry_is_recorded_expired_test() {
  let w = world.new()
  let assert Ok(Nil) = expect_until(w, closes())
  at_seconds(w, day)
  assert world.deliver_due(w, wakers()) == 1
  at_seconds(w, day + 5)
  let assert Ok(late) = recommend(w, proposal())
  assert late.status == occurrence.Expired(DeadlinePassed)
  assert late.policy_version == None
  assert notices(w) == 1
  assert wake_times(w) == []
  // Delivered again, the same trigger finds the same occurrence.
  let assert Ok(again) = recommend(w, proposal())
  assert again.entries == late.entries
  invariants(w)
}

pub fn a_recommendation_after_the_deadline_before_the_wake_up_is_the_same_test() {
  let w = world.new()
  let assert Ok(Nil) = expect_until(w, closes())
  at_seconds(w, day + 5)
  let assert Ok(late) = recommend(w, proposal())
  assert late.status == occurrence.Expired(DeadlinePassed)
  assert late.policy_version == None
  assert notices(w) == 1
  assert wake_times(w) == []
  invariants(w)
  // The wake-up the queue still delivers finds nothing due.
  assert world.in_tx(w, decisions.wake(desk(), _, occurrence: key))
    == Ok(decisions.NothingDue)
}

pub fn a_proposal_whose_deadline_has_passed_is_recorded_expired_test() {
  let w = world.new()
  at_seconds(w, 10)
  let assert Ok(late) =
    recommend(w, decisions.valid_until(proposal(), at: world.t0()))
  assert late.valid_until == Some(world.t0())
  assert late.status == occurrence.Expired(DeadlinePassed)
  assert notices(w) == 1
  invariants(w)
}

// -- The effective deadline ----------------------------------------------------------

pub fn the_point_validity_bounds_the_deadline_test() {
  let w = world.new()
  let short = desk_for(point() |> decisions.valid_for(duration.hours(1)))
  let assert Ok(Nil) =
    world.in_tx(w, decisions.expect_until(
      short,
      _,
      key:,
      trigger: Trigger("message", "m1"),
      about: ana,
      valid_until: closes(),
    ))
  at_seconds(w, 90)
  let assert Ok(known) =
    world.in_tx(w, decisions.recommend_once(
      short,
      _,
      key:,
      proposal: proposal(),
    ))
  let hour_later = timestamp.add(world.t0(), duration.seconds(90 + 3600))
  assert known.valid_until == Some(hour_later)
  assert head(w).due == Some(hour_later)
  assert wake_times(w) == [hour_later]
}

pub fn a_proposal_never_moves_the_deadline_later_test() {
  let w = world.new()
  let assert Ok(Nil) = expect_until(w, closes())
  let later = timestamp.add(closes(), duration.hours(1))
  let assert Ok(known) =
    recommend(w, decisions.valid_until(proposal(), at: later))
  assert known.valid_until == Some(closes())
}

pub fn a_proposal_may_set_an_earlier_deadline_test() {
  let w = world.new()
  let assert Ok(Nil) = expect_until(w, closes())
  let earlier = timestamp.add(world.t0(), duration.hours(2))
  let assert Ok(known) =
    recommend(w, decisions.valid_until(proposal(), at: earlier))
  assert known.valid_until == Some(earlier)
  assert wake_times(w) == [earlier]
}

pub fn repeating_the_expectation_keeps_the_first_deadline_test() {
  let w = world.new()
  let assert Ok(Nil) = expect_until(w, closes())
  let later = timestamp.add(closes(), duration.hours(1))
  let assert Ok(Nil) = expect_until(w, later)
  assert list.length(memory.entries(w.db, key)) == 1
  assert head(w).due == Some(closes())
}

// -- Superseding --------------------------------------------------------------------

fn newer_message(w: World) {
  world.in_tx(w, decisions.happened(desk(), _, "newer_message", about: ana))
}

pub fn superseding_an_expected_record_cancels_its_wake_up_test() {
  let w = world.new()
  let assert Ok(Nil) = expect_until(w, closes())
  let assert Ok(decisions.Supersession(not_begun: [_], ..)) = newer_message(w)
  let assert Ok(decisions.NotBegun(pending)) = read(w)
  assert pending.ended == Some(Superseded("newer_message"))
  assert wake_times(w) == []
  invariants(w)
}

pub fn superseding_a_lapsed_record_records_the_deadline_test() {
  let w = world.new()
  let assert Ok(Nil) = expect_until(w, closes())
  at_seconds(w, day)
  let assert Ok(decisions.Supersession(not_begun: [_], ..)) = newer_message(w)
  let assert Ok(decisions.NotBegun(pending)) = read(w)
  assert pending.ended == Some(DeadlinePassed)
  assert wake_times(w) == []
  assert notices(w) == 1
  invariants(w)
}

// -- As before without a deadline ----------------------------------------------------

pub fn an_expectation_without_a_deadline_is_stored_as_before_test() {
  let w = world.new()
  let assert Ok(Nil) =
    world.in_tx(w, decisions.expect(
      desk(),
      _,
      key:,
      trigger: Trigger("message", "m1"),
      about: ana,
    ))
  let assert [stored] = memory.entries(w.db, key)
  assert !string.contains(stored.event, "valid_until")
  assert head(w).due == None
  assert wake_times(w) == []
  at_seconds(w, 10 * day)
  let assert Ok(known) = recommend(w, proposal())
  assert known.valid_until == None
  assert known.status != occurrence.Expired(DeadlinePassed)
}

pub fn a_deadline_survives_a_restart_test() {
  let w = world.new()
  let assert Ok(Nil) = expect_until(w, closes())
  let w = world.restart(w)
  memory.set_clock(w.db, closes())
  assert world.deliver_due(w, wakers()) == 1
  let assert Ok(decisions.NotBegun(pending)) = read(w)
  assert pending.ended == Some(DeadlinePassed)
}

pub fn a_lapsed_record_refusal_is_final_test() {
  assert decisions.disposition(decisions.DeadlinePassedBefore(closes()))
    == decisions.Final
}

pub fn a_lapsed_record_refuses_reads_and_plain_expectations_test() {
  let w = world.new()
  let assert Ok(Nil) = expect_until(w, closes())
  at_seconds(w, day)
  assert world.in_tx(w, decisions.read(desk(), _, occurrence: key))
    == Error(decisions.DeadlinePassedBefore(closes()))
  assert world.in_tx(w, decisions.expect(
      desk(),
      _,
      key:,
      trigger: Trigger("message", "m1"),
      about: ana,
    ))
    == Error(decisions.DeadlinePassedBefore(closes()))
  // The record itself is still readable as not begun.
  let assert Ok(decisions.NotBegun(pending)) = read(w)
  assert pending.ended == None
  assert pending.valid_until == Some(closes())
}

pub fn an_expectation_whose_deadline_has_passed_is_written_expired_test() {
  let w = world.new()
  at_seconds(w, day + 10)
  let assert Ok(Nil) = expect_until(w, closes())
  let assert Ok(decisions.NotBegun(pending)) = read(w)
  assert pending.ended == Some(DeadlinePassed)
  assert pending.expected
  assert head(w).status == store.Expired
  assert notices(w) == 1
  assert wake_times(w) == []
  invariants(w)
}

pub fn a_plain_expectation_takes_a_deadline_given_later_test() {
  let w = world.new()
  let assert Ok(Nil) =
    world.in_tx(w, decisions.expect(
      desk(),
      _,
      key:,
      trigger: Trigger("message", "m1"),
      about: ana,
    ))
  let assert Ok(Nil) = expect_until(w, closes())
  let earlier = timestamp.add(world.t0(), duration.hours(1))
  let assert Ok(Nil) = expect_until(w, earlier)
  assert list.length(memory.entries(w.db, key)) == 3
  assert head(w).due == Some(earlier)
  assert wake_times(w) == [earlier]
  invariants(w)
}

pub fn a_deadline_is_kept_in_whole_milliseconds_test() {
  let w = world.new()
  let precise = timestamp.add(closes(), duration.nanoseconds(999_999))
  let assert Ok(Nil) = expect_until(w, precise)
  assert head(w).due == Some(closes())
  assert wake_times(w) == [closes()]
  let assert Ok(decisions.NotBegun(pending)) = read(w)
  assert pending.valid_until == Some(closes())
}

pub fn a_dropped_wake_up_of_a_record_not_begun_is_reported_test() {
  let w = world.new()
  let assert Ok(Nil) = expect_until(w, closes())
  let _ = memory.take_due(w.db)
  memory.set_clock(w.db, closes())
  let assert [_] = memory.take_due(w.db)
  memory.set_clock(w.db, world.t0())
  let assert Error([testing.Violation(invariant: "I5", ..)]) =
    testing.check(w.db, memory.inspection(), [testing.audit_record(desk())])
}

pub fn the_lapsed_record_is_counted_in_coverage_test() {
  let w = world.new()
  let assert Ok(Nil) = expect_until(w, closes())
  at_seconds(w, day)
  assert world.deliver_due(w, wakers()) == 1
  let assert Ok(record) = read(w)
  assert learning.coverage([record])
    == learning.Coverage(
      expected: 1,
      superseded_before: 0,
      lapsed_before: 1,
      still_expected: 0,
    )
}
