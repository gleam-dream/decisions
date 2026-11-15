//// Test support: `finance.classify`, its cascade and its gated tool.

import decisions.{type Desk, type Gated, type Point, Gated}
import decisions/fact.{type Key}
import decisions/memory.{type Memory}
import decisions/model.{type Model, type Sources, type Stage, Sources}
import decisions/occurrence.{type Occurrence}
import decisions/policy.{
  type Policy, AnyoneHolding, Ask, PerCent, Policy, Proceed, When,
}
import decisions/vocabulary.{
  type Manifest, type Recommendation, type Ref, ApproveRejectOrCorrect,
  Classifier, Manifest, ModelCall, Receipt, Recommendation, Ref, RuleFired,
  Rules, Trigger,
}
import decisions/wire
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import support/world.{type World}

pub fn score() -> Key(Float) {
  fact.number("score")
}

pub fn point() -> Point(String) {
  decisions.point("finance.classify", wire.text())
  |> decisions.allowing(ApproveRejectOrCorrect)
  |> decisions.signal(score())
}

/// Storing a class is this point's gated tool: no other code path writes one.
pub fn store_class() -> Gated(String, Memory) {
  Gated(
    name: "store_class",
    guard: fn(_, _) { Ok([]) },
    execute: fn(tx, released) {
      Ok(world.push(
        tx,
        "classes",
        decisions.occurrence_of(released) <> "=" <> decisions.output(released),
      ))
    },
  )
}

/// Proceed at a score of 0.9 or above and sample 5 %; below, ask.
pub fn production() -> Policy {
  Policy(
    version: 1,
    rules: [When(policy.at_least(score(), 0.9), Proceed(PerCent(5)))],
    otherwise: Ask(AnyoneHolding("finance")),
  )
}

pub fn always_ask() -> Policy {
  Policy(version: 0, rules: [], otherwise: Ask(AnyoneHolding("finance")))
}

pub fn desk(policy: Policy) -> Desk(String, Memory) {
  decisions.desk(
    point(),
    drives: fn(_) { store_class() },
    under: fn(_) { Ok(policy) },
    over: memory.port(),
  )
}

pub fn context(n: Int) -> Manifest {
  Manifest(
    refs: [Ref("transaction", int.to_string(n), "1")],
    renderer: "classify-1",
  )
}

/// The books: the immutable content of a transaction reference. A
/// transaction's content here is its number.
pub fn books(ref: Ref) -> Result(String, String) {
  case ref.kind {
    "transaction" -> Ok(ref.id)
    _ -> Error("not a transaction: " <> ref.id)
  }
}

/// The books as a resolver, for the export and the card.
pub fn resolver(ref: Ref) -> Result(String, model.Failure) {
  books(ref) |> result.map_error(model.ReadFailed(ref.kind, ref.id, _))
}

pub fn sources() -> Sources {
  Sources(
    resolve: fn(ref: Ref) {
      books(ref) |> result.map_error(model.ReadFailed(ref.kind, ref.id, _))
    },
    read: fn(name, argument) {
      Error(model.ReadFailed(name, argument, "the cascade makes no read"))
    },
  )
}

fn number(context: Manifest, sources: Sources) -> Result(Int, model.Failure) {
  case context.refs {
    [ref, ..] ->
      sources.resolve(ref)
      |> result.try(fn(content) {
        int.parse(content)
        |> result.replace_error(model.Undecodable("not a number: " <> content))
      })
    [] -> Error(model.Declined("the context names no transaction"))
  }
}

fn stage(answer: fn(Int) -> Option(Recommendation(String))) -> Stage(String) {
  fn(context, sources) { number(context, sources) |> result.map(answer) }
}

/// Rules, then a classifier, then one model call.
pub fn cascade() -> Model(String) {
  model.cascade([
    stage(fn(n) {
      case n % 5 {
        0 ->
          Some(
            Recommendation(
              "bank_fee",
              Rules("fee-rules", "v1"),
              RuleFired("pix-tarifa"),
              [fact.set(score(), 1.0)],
              [],
            ),
          )
        _ -> None
      }
    }),
    stage(fn(n) {
      case n % 5 {
        1 | 2 | 3 ->
          Some(
            Recommendation(
              "supplier",
              Classifier("tx-classifier", "v3"),
              Receipt(Ref("receipt", "classifier-" <> int.to_string(n), "1")),
              [fact.set(score(), 0.97)],
              [],
            ),
          )
        _ -> None
      }
    }),
    stage(fn(n) {
      let score_value = case n % 20 {
        19 -> 0.7
        _ -> 0.93
      }
      Some(
        Recommendation(
          "tax",
          ModelCall("classify-llm", "v2"),
          Receipt(Ref("receipt", "llm-" <> int.to_string(n), "1")),
          [fact.set(score(), score_value)],
          [],
        ),
      )
    }),
  ])
}

/// Classify transactions `from` to `to` in one transaction, as a batch job
/// would.
pub fn batch(
  world: World,
  from from: Int,
  to to: Int,
  under policy: Policy,
) -> List(Occurrence(String)) {
  let assert Ok(classified) =
    world.in_tx(world, fn(tx) {
      list.try_map(world.numbers(from, to), fn(n) {
        let assert Ok(recommendation) =
          model.run(cascade(), context(n), sources())
        decisions.recommend(
          desk(policy),
          tx,
          decisions.proposal(
            trigger: Trigger(kind: "transaction", id: int.to_string(n)),
            about: world.clinica,
            context: context(n),
            recommending: recommendation,
          ),
        )
      })
    })
  classified
}

pub fn classes(world: World) -> List(String) {
  world.all(world.db, "classes")
}
