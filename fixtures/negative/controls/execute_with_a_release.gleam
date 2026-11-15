// Control for execute_with_a_bare_output and a_release_check_value_to_an_executor:
// a released refund reaches the tool.
import decisions.{type Released}
import decisions_usage/clinic.{type Refund}

pub fn pay(tx, released: Released(Refund)) {
  clinic.refund_fee().execute(tx, released)
}
