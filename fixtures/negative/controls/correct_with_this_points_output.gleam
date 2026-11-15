// Control for correct_with_another_points_output.
import decisions
import decisions/vocabulary.{Correct, Reason}
import decisions_usage/clinic.{Refund}
import decisions_usage/first_point
import gleam/option.{None}

pub fn correct(tx, card) {
  decisions.decide(
    first_point.desk(),
    tx,
    card,
    Correct(output: Refund("fee-1", 6000), reason: Reason("amount", None)),
  )
}
