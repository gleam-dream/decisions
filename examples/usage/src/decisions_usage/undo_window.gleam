//// An undo window on what the policy lets proceed by itself: small refunds
//// the classifier is sure of proceed, are held for thirty minutes, and
//// anyone in finance may withdraw them meanwhile. The window is part of
//// the policy's outcome, so what a person approved is released at once.

// snips-start: undo-window
import decisions
import decisions/memory.{type Memory}
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Never, Proceed, When}
import decisions/vocabulary.{
  Classifier, Manifest, Receipt, Recommendation, Ref, Trigger,
}
import decisions_usage/autonomy_ladder
import decisions_usage/clinic.{type Refund, Refund}
import gleam/option.{Some}
import gleam/time/duration

pub fn desk() -> decisions.Desk(Refund, Memory) {
  decisions.desk(
    autonomy_ladder.point() |> decisions.withdrawn_by("finance"),
    drives: fn(_) { clinic.refund_fee() },
    under: fn(_) {
      Ok(
        clinic.well_formed(policy.new(
          version: 1,
          rules: [
            When(
              policy.at_least(autonomy_ladder.confidence(), 0.95),
              // Proceed, with a thirty-minute undo window.
              Proceed(Never, Some(duration.minutes(30))),
            ),
          ],
          otherwise: AnyoneHolding("finance"),
        )),
      )
    },
    over: memory.port(),
  )
}

/// Bia takes back a refund the policy let proceed, within its window.
pub fn take_back(
  store: Memory,
  id: String,
) -> Result(occurrence.Occurrence(Refund), decisions.Refusal) {
  memory.transaction(store, decisions.withdraw_as(
    desk(),
    _,
    occurrence: id,
    by: clinic.bia,
  ))
}

// snips-end: undo-window

/// The whole topic: held by the policy, then withdrawn by Bia.
pub fn run() -> List(String) {
  let store = memory.new()
  let assert Ok(held) =
    memory.transaction(store, decisions.recommend(
      desk(),
      _,
      decisions.proposal(
        trigger: Trigger(kind: "statement_line", id: "fee-9"),
        about: clinic.clinica_x,
        context: Manifest(refs: [], renderer: "refund-1"),
        recommending: Recommendation(
          output: Refund(fee: "fee-9", cents: 4000),
          by: Classifier(name: "refund-classifier", version: "v5"),
          explanation: Receipt(Ref("classifier", "fee-9", "1")),
          signals: [decisions_fact()],
          reads: [],
        ),
      ),
    ))
  let assert Ok(back) = take_back(store, held.id)
  [occurrence.status_name(held.status), occurrence.status_name(back.status)]
}

fn decisions_fact() {
  autonomy_ladder.confidence_signal(0.99)
}
