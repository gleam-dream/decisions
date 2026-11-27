//// Test support: `tax.invoice`, the tax context's executor, and the
//// municipality.

import decisions.{type Desk, type Gated, type Point, Gated}
import decisions/fact
import decisions/memory.{type Memory}
import decisions/occurrence.{type Occurrence}
import decisions/policy.{AnyoneHolding, Never, OwnAct, Proceed, When}
import decisions/vocabulary.{
  type Explanation, type Manifest, Agent, ApproveRejectOrCorrect, ParentRun,
  Recommendation, Trigger,
}
import decisions/wire.{type Codec}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import json/blueprint/codec
import support/policies
import support/world.{type World}

pub type Invoice {
  Invoice(taker: String, cents: Int, service_code: String)
}

pub fn codec() -> Codec(Invoice) {
  wire.codec({
    use taker <- codec.field("taker", codec.string(), get: fn(i: Invoice) {
      i.taker
    })
    use cents <- codec.field("cents", codec.int(), get: fn(i: Invoice) {
      i.cents
    })
    use service_code <- codec.field(
      "service_code",
      codec.string(),
      get: fn(i: Invoice) { i.service_code },
    )
    codec.success(Invoice(taker:, cents:, service_code:))
  })
}

pub fn point() -> Point(Invoice) {
  decisions.point("tax.invoice", codec())
  |> decisions.allowing(ApproveRejectOrCorrect)
  |> decisions.fact(fact.number("amount"), fn(invoice: Invoice) {
    int.to_float(invoice.cents) /. 100.0
  })
}

/// The tax context's executor. It applies the command `RequestInvoice`
/// once: the invoice is `submitted` and the effect `SubmitNfse` is
/// requested, all in the releasing transaction.
pub fn issue_nfse() -> Gated(Invoice, Memory) {
  Gated(
    name: "issue_nfse",
    guard: fn(_, _) { Ok([]) },
    execute: fn(tx, released) {
      let invoice: Invoice = decisions.output(released)
      let key = decisions.key(released)
      case memory.get(tx, "tax_id_held:" <> invoice.taker) {
        Ok(_) ->
          Error(decisions.Refuse("the taker's tax id is held by another party"))
        Error(Nil) -> {
          memory.put(tx, "invoice:" <> key, "submitted")
          Ok(world.push(tx, "effects", key <> "|" <> invoice.service_code))
        }
      }
    },
  )
}

pub fn desk() -> Desk(Invoice, Memory) {
  decisions.desk(
    point(),
    drives: fn(_) { issue_nfse() },
    under: fn(_) {
      Ok(policies.checked(
        version: 1,
        rules: [When(OwnAct, Proceed(Never, None))],
        otherwise: AnyoneHolding("operators"),
      ))
    },
    over: memory.port(),
  )
}

/// The accounting agent recommends an invoice for the run that asked.
pub fn recommend(
  world: World,
  asked_by run: String,
  explained_by explanation: Explanation,
  from context: Manifest,
) -> Occurrence(Invoice) {
  let assert Ok(recommended) =
    world.in_tx(world, fn(tx) {
      decisions.recommend(
        desk(),
        tx,
        decisions.proposal(
          trigger: Trigger(kind: "run", id: run),
          about: world.clinica,
          context:,
          recommending: Recommendation(
            reads: [],
            output: Invoice(
              taker: "clinica-x",
              cents: 80_000,
              service_code: "4.03",
            ),
            by: Agent(kind: "accounting", version: "3"),
            explanation:,
            signals: [],
          ),
        )
          |> decisions.hanging_from(ParentRun(run)),
      )
    })
  recommended
}

pub fn state(world: World, key: String) -> Result(String, Nil) {
  memory.get(world.db, "invoice:" <> key)
}

/// The shell performs the effects the update requested, after the commit.
/// The municipality issues the invoice and its reply is lost, so the
/// outcome returns to the tax context as `uncertain`.
pub fn perform_effects(world: World) -> Nil {
  list.each(world.all(world.db, "effects"), fn(effect) {
    let assert [key, service_code] = string.split(effect, "|")
    world.bump(world.outside, "municipality.issue_calls")
    memory.put(world.outside, "municipality:" <> key, service_code)
    memory.put(world.db, "invoice:" <> key, "uncertain")
  })
  memory.put(world.db, "effects", "[]")
}

/// An uncertain outcome is settled by reading the outside system back by
/// key, never by repeating the call.
pub fn settle_uncertain(world: World, key: String) -> Nil {
  world.bump(world.outside, "municipality.read_calls")
  case memory.get(world.outside, "municipality:" <> key) {
    Ok(_) -> memory.put(world.db, "invoice:" <> key, "issued")
    Error(Nil) -> memory.put(world.db, "invoice:" <> key, "not_issued")
  }
}

pub fn issue_calls(world: World) -> Int {
  world.count(world.outside, "municipality.issue_calls")
}
