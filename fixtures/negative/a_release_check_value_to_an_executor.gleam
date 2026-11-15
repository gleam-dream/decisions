// Must not compile: the value a release check sees, handed to an executor.
// Only a `Released` reaches the gated tool.
import decisions.{type ToRelease}
import decisions_usage/clinic.{type Refund}

pub fn bypass(tx, release: ToRelease(Refund)) {
  clinic.refund_fee().execute(tx, release)
}
