// Must not compile: a released value built outside the library.
import decisions
import decisions/occurrence
import decisions_usage/clinic.{Refund}
import gleam/option.{None}

pub fn forge() {
  decisions.Released(
    occurrence: "occ-1",
    key: "release:occ-1",
    subject: clinic.ana,
    parent: None,
    by: occurrence.ByPolicy(1),
    output: Refund(fee: "fee-1", cents: 8000),
  )
}
