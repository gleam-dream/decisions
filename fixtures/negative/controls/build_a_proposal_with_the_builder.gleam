// Control for build_a_proposal, build_a_card, build_a_desk and
// build_a_released_value: the library's own constructors.
import decisions
import decisions_usage/first_point

pub fn build(trigger, subject, context, recommendation) {
  #(
    first_point.desk(),
    decisions.proposal(trigger:, about: subject, context:, recommending: recommendation)
      |> decisions.asked_by("felipe"),
  )
}
