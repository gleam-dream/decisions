// Must not compile: a guard whose parameter is the output. A guard's
// parameters are the transaction and the subject. This proves only that
// the guard is not handed the output: a guard built inside `drives` can
// still close over it, which the documentation tells callers not to do.
import decisions.{Gated}
import decisions_usage/clinic.{type Refund}

pub fn guarded() {
  Gated(..clinic.refund_fee(), guard: fn(_tx, refund: Refund) {
    case refund.cents < 10_000 {
      True -> Ok([])
      False -> Error(decisions.Refuse("too large"))
    }
  })
}
