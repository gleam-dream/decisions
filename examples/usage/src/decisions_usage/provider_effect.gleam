//// An effect outside the database. The gated tool never calls the
//// payment provider: it writes an instruction beside the release, in the
//// release's transaction. A worker performs it under the release's key,
//// and `report` records what became of it.

// snips-start: provider-effect
import decisions.{type Gated, Gated}
import decisions/memory.{type Memory}
import decisions/occurrence
import decisions/vocabulary.{
  type Effect, Agent, Approve, Manifest, NotPerformed, Performed, Recommendation,
  Ref, RunAnswer, Trigger, Uncertain,
}
import decisions_usage/clinic.{type Refund}
import decisions_usage/first_point
import gleam/int
import gleam/option
import gleam/result

/// The tool writes the instruction; the release's key is the idempotency
/// key the provider will be sent.
pub fn instruct() -> Gated(Refund, Memory) {
  Gated(
    name: "refund_at_provider",
    guard: fn(_, _) { Ok([]) },
    execute: fn(tx, released) {
      let refund: Refund = decisions.output(released)
      memory.put(
        tx,
        "instruction:" <> decisions.key(released),
        decisions.occurrence_of(released) <> "|" <> int.to_string(refund.cents),
      )
      Ok(Nil)
    },
  )
}

pub fn desk() -> decisions.Desk(Refund, Memory) {
  decisions.desk(
    clinic.refund_point(),
    drives: fn(_) { instruct() },
    under: fn(_) { Ok(first_point.always_ask()) },
    over: memory.port(),
  )
}

/// What the provider said, as the worker saw it.
pub type Answer {
  Paid(receipt: String)
  Declined(reason: String)
  NoAnswer
}

/// The worker, after calling the provider under the release's key: it
/// reports what became of the release. An unknown outcome is recorded as
/// uncertain; a later lookup by the same key settles it with another
/// report.
pub fn record(
  store: Memory,
  id: String,
  key: String,
  answer: Answer,
) -> Result(Effect, decisions.Refusal) {
  let effect = case answer {
    Paid(receipt:) -> Performed(Ref("provider.receipt", key, receipt))
    Declined(reason:) -> NotPerformed(reason)
    NoAnswer -> Uncertain("the provider did not answer within 10 s")
  }
  memory.transaction(store, decisions.report(desk(), _, occurrence: id, effect:))
  |> result.replace(effect)
}

// snips-end: provider-effect

/// The whole topic: released, then uncertain, then settled by a lookup.
pub fn run() -> List(String) {
  let store = memory.new()
  let assert Ok(waiting) =
    memory.transaction(store, decisions.recommend(desk(), _, proposal()))
  let assert Ok(released) =
    memory.transaction(store, fn(tx) {
      use card <- result.try(
        decisions.open(
          desk(),
          tx,
          occurrence: waiting.id,
          by: clinic.bia,
          latest: fn(r) { r.revision },
        ),
      )
      decisions.decide(desk(), tx, card, Approve)
    })
  let assert occurrence.Released(key:, ..) = released.status
  let assert Ok(_) = memory.get(store, "instruction:" <> key)
  let assert Ok(_) = record(store, waiting.id, key, NoAnswer)
  let assert Ok(_) = record(store, waiting.id, key, Paid("rcpt-881"))
  let assert Ok(known) =
    memory.transaction(store, decisions.read(desk(), _, occurrence: waiting.id))
  let effect = case occurrence.effect(known) {
    option.Some(Performed(receipt:)) -> "performed " <> receipt.revision
    _ -> "unsettled"
  }
  [occurrence.status_name(known.status), effect]
}

fn proposal() {
  decisions.proposal(
    trigger: Trigger(kind: "message", id: "m-ana-2"),
    about: clinic.ana,
    context: Manifest(refs: [], renderer: "refund-1"),
    recommending: Recommendation(
      output: clinic.Refund(fee: "late-fee-2026-11", cents: 5000),
      by: Agent(kind: "billing", version: "3"),
      explanation: RunAnswer(run: "run-42"),
      signals: [],
      reads: [],
    ),
  )
}
