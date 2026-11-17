import decisions
import decisions/learning.{Replay, Tally}
import decisions/view.{Item}
import decisions/vocabulary.{Ref}
import decisions_usage/autonomy_ladder
import decisions_usage/card_document
import decisions_usage/deadline_per_occurrence
import decisions_usage/expect_then_recommend
import decisions_usage/first_point
import decisions_usage/four_eyes
import decisions_usage/provider_effect
import decisions_usage/replay
import decisions_usage/same_context.{Dossier}
import decisions_usage/ticket
import decisions_usage/two_or_one_senior
import decisions_usage/undo_window
import gleam/option.{Some}
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn a_first_point_is_released_once_test() {
  assert first_point.run() == #("awaiting", "released", Ok(8000))
}

pub fn the_ladder_climbs_by_publishing_policies_test() {
  assert autonomy_ladder.run()
    == ["awaiting", "released", "awaiting", "awaiting", "held", "refused"]
}

pub fn a_ticket_carries_a_card_across_requests_test() {
  let #(felipe, seen, shown) = ticket.run()
  assert felipe == Error(decisions.NeverShown)
  assert seen == [#("bia", shown)]
}

pub fn four_eyes_escalates_to_managers_test() {
  assert four_eyes.run()
    == [
      "this validator may not decide this occurrence", "awaiting",
      "this validator may not decide this occurrence", "delivered 1", "released",
    ]
}

pub fn an_effect_outside_the_database_is_reported_test() {
  assert provider_effect.run() == ["released", "performed rcpt-881"]
}

pub fn a_person_sees_what_the_model_saw_test() {
  let #(dossier, pulled) = same_context.run()
  assert dossier
    == Dossier(
      message: "Fui cobrada em atraso, mas paguei em dia.",
      balance: "overdue 80.00",
    )
  let assert [
    Item(
      ref: Ref(kind: "balance", ..),
      content: Ok("overdue 80.00"),
      now: Some(_),
    ),
  ] = pulled
}

pub fn a_new_model_is_scored_on_recorded_decisions_test() {
  let #(first, second) = replay.run()
  assert first
    == Replay(
      tally: Tally(agreed: 2, judged: 3, rejected: 0, right: 0, assessed: 0),
      unanswered: [],
    )
  assert second
    == Replay(
      tally: Tally(agreed: 3, judged: 3, rejected: 0, right: 0, assessed: 0),
      unanswered: [],
    )
}

pub fn either_alternatives_are_judged_on_the_approvals_test() {
  assert two_or_one_senior.run() == ["awaiting", "released", "released"]
}

pub fn a_late_recommendation_for_a_superseded_line_is_dropped_test() {
  assert expect_then_recommend.run() == #(Ok(["refund:fee-7"]), decisions.Drop)
}

pub fn a_draft_expires_when_its_own_window_closes_test() {
  assert deadline_per_occurrence.run() == #(True, "expired")
}

pub fn finance_may_take_back_what_the_policy_let_proceed_test() {
  assert undo_window.run() == ["held", "withdrawn"]
}

pub fn a_card_is_served_and_read_back_typed_test() {
  assert card_document.run()
}
