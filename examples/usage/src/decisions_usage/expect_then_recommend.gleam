//// Work in flight is superseded too. A statement line arrives, and the
//// classifier takes a while to recommend a refund for it; meanwhile a
//// corrected statement arrives for the same company. The line's record is
//// expected in the transaction that received it, so the correction
//// supersedes it before it begins, and the classifier's late
//// recommendation is refused: nothing is shown or released.

// snips-start: expect-then-recommend
import decisions
import decisions/memory.{type Memory, type Tx}
import decisions/policy.{AnyoneHolding}
import decisions/vocabulary.{
  Classifier, Manifest, Receipt, Recommendation, Ref, Trigger,
}
import decisions_usage/clinic.{type Refund, Refund}
import gleam/result

pub fn desk() -> decisions.Desk(Refund, Tx) {
  decisions.desk(
    clinic.refund_point() |> decisions.superseded_by("statement_corrected"),
    drives: fn(_) { clinic.refund_fee() },
    under: fn(_) {
      Ok(clinic.well_formed(policy.new(1, [], AnyoneHolding("finance"))))
    },
    over: memory.port(),
  )
}

/// The transaction that receives a statement line: it expects the
/// recommendation before the classifier's job is queued.
pub fn receive(store: Memory, fee: String) -> Result(Nil, decisions.Refusal) {
  memory.transaction(store, decisions.expect(
    desk(),
    _,
    key: "refund:" <> fee,
    trigger: Trigger(kind: "statement_line", id: fee),
    about: clinic.clinica_x,
  ))
}

/// The transaction that receives a corrected statement.
pub fn correct(store: Memory) -> Result(List(String), decisions.Refusal) {
  memory.transaction(store, decisions.happened(
    desk(),
    _,
    "statement_corrected",
    about: clinic.clinica_x,
  ))
  |> result.map(fn(superseded) { superseded.not_begun })
}

/// The classifier's job commits its recommendation.
pub fn recommend(
  store: Memory,
  fee: String,
) -> Result(String, decisions.Refusal) {
  memory.transaction(store, decisions.recommend_once(
    desk(),
    _,
    key: "refund:" <> fee,
    proposal: decisions.proposal(
      trigger: Trigger(kind: "statement_line", id: fee),
      about: clinic.clinica_x,
      context: Manifest(refs: [], renderer: "refund-1"),
      recommending: Recommendation(
        output: Refund(fee:, cents: 4000),
        by: Classifier(name: "refund-classifier", version: "v5"),
        explanation: Receipt(Ref("classifier", fee, "1")),
        signals: [],
        reads: [],
      ),
    ),
  ))
  |> result.map(fn(recorded) { recorded.id })
}

// snips-end: expect-then-recommend

/// The whole topic: the line expected, the correction superseding it, and
/// the classifier's late answer refused and classified for its queue.
pub fn run() -> #(Result(List(String), decisions.Refusal), decisions.Handling) {
  let store = memory.new()
  let assert Ok(Nil) = receive(store, "fee-7")
  let superseded = correct(store)
  let assert Error(late) = recommend(store, "fee-7")
  #(superseded, decisions.handling(decisions.DeskRefused(late)))
}
