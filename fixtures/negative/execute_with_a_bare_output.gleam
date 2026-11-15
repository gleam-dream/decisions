// Must not compile: a gated tool's executor called with an output that was
// never released.
import decisions_usage/clinic.{Refund}

pub fn pay_without_a_release(tx) {
  clinic.refund_fee().execute(tx, Refund(fee: "fee-1", cents: 8000))
}
