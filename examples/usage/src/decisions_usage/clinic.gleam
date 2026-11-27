//// The cast every topic shares: Ana, a patient of Clínica X; Felipe and
//// Bia, who hold `finance`; Caio, who holds `support`; and the fee refund
//// a person may have to approve.

// snips-start: refund-point
import decisions.{type Gated, type Point, Gated}
import decisions/fact
import decisions/memory.{type Memory}
import decisions/policy.{type Policy}
import decisions/vocabulary.{ApproveRejectOrCorrect, Subject, Validator}
import decisions/wire
import gleam/int
import json/blueprint/codec

/// The output of the point: which fee to refund, and how much.
pub type Refund {
  Refund(fee: String, cents: Int)
}

/// The one fact a refund policy may read.
pub fn amount() -> fact.Key(Float) {
  fact.number("amount")
}

/// The declaration: a name, the output's codec (which also carries its
/// JSON Schema), and the facts a policy may read. No threshold lives here.
pub fn refund_point() -> Point(Refund) {
  decisions.point(
    "billing.fee_refund",
    wire.codec({
      use fee <- codec.field("fee", codec.string(), get: fn(r: Refund) { r.fee })
      use cents <- codec.field("cents", codec.int(), get: fn(r: Refund) {
        r.cents
      })
      codec.success(Refund(fee:, cents:))
    }),
  )
  |> decisions.allowing(ApproveRejectOrCorrect)
  |> decisions.fact(amount(), fn(refund: Refund) {
    int.to_float(refund.cents) /. 100.0
  })
}

/// The gated tool. Its executor accepts nothing but a released refund, so
/// no other code path can refund a fee.
pub fn refund_fee() -> Gated(Refund, Memory) {
  Gated(
    name: "refund_fee",
    guard: fn(_tx, _subject) { Ok([]) },
    execute: fn(tx, released) {
      let refund: Refund = decisions.output(released)
      memory.put(tx, "refunded:" <> refund.fee, int.to_string(refund.cents))
      Ok(Nil)
    },
  )
}

// snips-end: refund-point

pub const ana = Subject(kind: "person", id: "ana")

pub const clinica_x = Subject(kind: "company", id: "clinica-x")

pub const felipe = Validator(subject: "felipe", holds: ["finance"])

pub const bia = Validator(subject: "bia", holds: ["finance"])

pub const caio = Validator(subject: "caio", holds: ["support"])

pub const dora = Validator(subject: "dora", holds: ["finance", "managers"])

/// What the refund tool wrote for a fee, if anything.
pub fn refunded(store: Memory, fee: String) -> Result(Int, Nil) {
  case memory.get(store, "refunded:" <> fee) {
    Ok(cents) -> int.parse(cents)
    Error(Nil) -> Error(Nil)
  }
}

/// A policy the examples write as a literal. `policy.new` refuses a policy
/// that cannot be used whatever the point; these literals are well formed.
pub fn well_formed(made: Result(Policy, List(policy.Malformed))) -> Policy {
  let assert Ok(policy) = made
  policy
}
