//// A first point, from declaration to release: Ana asks for a fee refund,
//// the policy asks finance, Bia approves, and the refund is released once
//// to the gated tool in her verdict's transaction.

// snips-start: first-point
import decisions
import decisions/memory.{type Memory}
import decisions/occurrence.{type Occurrence}
import decisions/policy.{AnyoneHolding, Ask, Policy}
import decisions/vocabulary.{
  Agent, Approve, Manifest, Recommendation, Ref, RunAnswer, Trigger,
}
import decisions_usage/clinic.{type Refund, Refund}
import gleam/result

/// Version 1 of the policy: always ask a holder of `finance`.
pub fn always_ask() -> policy.Policy {
  Policy(version: 1, rules: [], otherwise: Ask(AnyoneHolding("finance")))
}

/// The desk binds the point to its gated tool, its policy and a store. It
/// is a plain value; build it wherever it is needed.
pub fn desk() -> decisions.Desk(Refund, Memory) {
  decisions.desk(
    clinic.refund_point(),
    drives: fn(_refund) { clinic.refund_fee() },
    under: fn(_tx) { Ok(always_ask()) },
    over: memory.port(),
  )
}

/// The billing agent recommends refunding Ana's late fee. The trigger's id
/// is the key, so a message delivered twice is one occurrence.
pub fn recommend(
  store: Memory,
) -> Result(Occurrence(Refund), decisions.Refusal) {
  let proposal =
    decisions.proposal(
      trigger: Trigger(kind: "message", id: "m-ana-1"),
      about: clinic.ana,
      context: Manifest(
        refs: [Ref("message", "m-ana-1", "1")],
        renderer: "refund-1",
      ),
      recommending: Recommendation(
        output: Refund(fee: "late-fee-2026-10", cents: 8000),
        by: Agent(kind: "billing", version: "3"),
        explanation: RunAnswer(run: "run-41"),
        signals: [],
        reads: [],
      ),
    )
  memory.transaction(store, decisions.recommend_once(
    desk(),
    _,
    key: "m-ana-1",
    proposal:,
  ))
}

/// Bia opens the card and approves, in one transaction. The refund runs
/// here; if the tool refused, the whole transaction would roll back.
pub fn approve(
  store: Memory,
  id: String,
) -> Result(Occurrence(Refund), decisions.Refusal) {
  memory.transaction(store, fn(tx) {
    use card <- result.try(
      decisions.open(
        desk(),
        tx,
        occurrence: id,
        by: clinic.bia,
        latest: fn(ref) { ref.revision },
      ),
    )
    decisions.decide(desk(), tx, card, Approve)
  })
}

// snips-end: first-point

/// The whole topic: the refund waits for finance, then is released once.
pub fn run() -> #(String, String, Result(Int, Nil)) {
  let store = memory.new()
  let assert Ok(waiting) = recommend(store)
  let assert Ok(released) = approve(store, waiting.id)
  #(
    occurrence.status_name(waiting.status),
    occurrence.status_name(released.status),
    clinic.refunded(store, "late-fee-2026-10"),
  )
}
