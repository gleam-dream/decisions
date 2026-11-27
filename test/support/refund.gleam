//// Test support: `billing.fee_refund` and its gated tool `refund_fee`.

import decisions.{type Desk, type Gated, type Point, Gated}
import decisions/fact.{type Key}
import decisions/memory.{type Tx}
import decisions/occurrence.{type Occurrence}
import decisions/policy.{type Policy}
import decisions/vocabulary.{
  type Recommender, type Trigger, ApproveOrReject, Manifest, Recommendation,
  RunAnswer,
}
import decisions/wire.{type Codec}
import gleam/int
import json/blueprint/codec
import support/world.{type World}

pub type Refund {
  Refund(fee: String, cents: Int)
}

pub fn codec() -> Codec(Refund) {
  wire.codec({
    use fee <- codec.field("fee", codec.string(), get: fn(r: Refund) { r.fee })
    use cents <- codec.field("cents", codec.int(), get: fn(r: Refund) {
      r.cents
    })
    codec.success(Refund(fee:, cents:))
  })
}

pub fn amount() -> Key(Float) {
  fact.number("amount")
}

/// The declaration holds the output type and the facts a policy may read.
/// No threshold lives here.
pub fn point() -> Point(Refund) {
  decisions.point("billing.fee_refund", codec())
  |> decisions.allowing(ApproveOrReject)
  |> decisions.fact(amount(), fn(refund: Refund) {
    int.to_float(refund.cents) /. 100.0
  })
}

pub fn refund_fee() -> Gated(Refund, Tx) {
  Gated(
    name: "refund_fee",
    guard: fn(_, _) { Ok([]) },
    execute: fn(tx, released) {
      let refund: Refund = decisions.output(released)
      Ok(world.push(
        tx,
        "refunds",
        refund.fee <> ":" <> int.to_string(refund.cents),
      ))
    },
  )
}

pub fn desk_of(point: Point(Refund), policy: Policy) -> Desk(Refund, Tx) {
  decisions.desk(
    point,
    drives: fn(_) { refund_fee() },
    under: fn(_) { Ok(policy) },
    over: memory.port(),
  )
}

pub fn desk(policy: Policy) -> Desk(Refund, Tx) {
  desk_of(point(), policy)
}

pub fn request(
  desk: Desk(Refund, Tx),
  tx: Tx,
  trigger: Trigger,
  by: Recommender,
  refund: Refund,
) -> Result(Occurrence(Refund), decisions.Refusal) {
  decisions.recommend(
    desk,
    tx,
    decisions.proposal(
      trigger:,
      about: world.clinica,
      context: Manifest(refs: [], renderer: "refund-1"),
      recommending: Recommendation(
        output: refund,
        by:,
        explanation: RunAnswer("n/a"),
        signals: [],
        reads: [],
      ),
    ),
  )
}

pub fn refunds(world: World) -> List(String) {
  world.all(world.db, "refunds")
}
