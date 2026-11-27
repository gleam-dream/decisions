//// Test support: `treasury.payout` and its gated tool `pay`.

import decisions.{type Desk, type Gated, type Point, Gated}
import decisions/fact.{type Key}
import decisions/memory.{type Tx}
import decisions/occurrence.{type Occurrence}
import decisions/policy.{type Policy}
import decisions/vocabulary.{
  Agent, ApproveRejectOrCorrect, Manifest, Recommendation, RunAnswer, Trigger,
}
import decisions/wire.{type Codec}
import gleam/int
import json/blueprint/codec
import support/world.{type World}

pub type Payout {
  Payout(to: String, cents: Int)
}

/// The one fact a payout policy reads, declared once with its type.
pub fn amount() -> Key(Float) {
  fact.number("amount")
}

pub fn codec() -> Codec(Payout) {
  wire.codec({
    use to <- codec.field("to", codec.string(), get: fn(p: Payout) { p.to })
    use cents <- codec.field("cents", codec.int(), get: fn(p: Payout) {
      p.cents
    })
    codec.success(Payout(to:, cents:))
  })
}

pub fn point() -> Point(Payout) {
  decisions.point("treasury.payout", codec())
  |> decisions.allowing(ApproveRejectOrCorrect)
  |> decisions.fact(amount(), fn(payout: Payout) {
    int.to_float(payout.cents) /. 100.0
  })
}

pub fn pay() -> Gated(Payout, Tx) {
  Gated(name: "pay", guard: fn(_, _) { Ok([]) }, execute: fn(tx, released) {
    let payout: Payout = decisions.output(released)
    Ok(world.push(
      tx,
      "payouts",
      payout.to <> ":" <> int.to_string(payout.cents),
    ))
  })
}

pub fn desk_of(point: Point(Payout), policy: Policy) -> Desk(Payout, Tx) {
  decisions.desk(
    point,
    drives: fn(_) { pay() },
    under: fn(_) { Ok(policy) },
    over: memory.port(),
  )
}

pub fn desk(policy: Policy) -> Desk(Payout, Tx) {
  desk_of(point(), policy)
}

/// A payout a person asked for and the treasury agent recommends. `key`
/// names the request, so a request delivered twice is one occurrence.
pub fn request(
  desk: Desk(Payout, tx),
  tx: tx,
  key key: String,
  by requester: String,
  payout payout: Payout,
) -> Result(Occurrence(Payout), decisions.Refusal) {
  decisions.recommend_once(
    desk,
    tx,
    key:,
    proposal: decisions.proposal(
      trigger: Trigger(kind: "payout_request", id: key),
      about: world.clinica,
      context: Manifest(refs: [], renderer: "payout-1"),
      recommending: Recommendation(
        output: payout,
        by: Agent(kind: "treasury", version: "2"),
        explanation: RunAnswer("n/a"),
        signals: [],
        reads: [],
      ),
    )
      |> decisions.asked_by(requester),
  )
}

pub fn payouts(world: World) -> List(String) {
  world.all(world.db, "payouts")
}
