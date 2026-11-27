//// An eligibility with alternatives: a large refund is accepted on two
//// approvals from finance, or on one from the head of finance. Each
//// alternative is judged on the approvals given so far.

// snips-start: either-several
import decisions
import decisions/memory.{type Memory, type Tx}
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Either, Several}
import decisions/vocabulary.{
  type Validator, Agent, Approve, Manifest, Recommendation, RunAnswer, Trigger,
  Validator,
}
import decisions_usage/clinic.{type Refund, Refund}
import gleam/result

pub const head_of_finance = Validator(subject: "lia", holds: ["head_of_finance"])

pub fn desk() -> decisions.Desk(Refund, Tx) {
  decisions.desk(
    clinic.refund_point(),
    drives: fn(_) { clinic.refund_fee() },
    under: fn(_) {
      Ok(
        clinic.well_formed(policy.new(
          version: 1,
          rules: [],
          otherwise: Either([
            Several(2, AnyoneHolding("finance")),
            AnyoneHolding("head_of_finance"),
          ]),
        )),
      )
    },
    over: memory.port(),
  )
}

pub fn approve(store: Memory, id: String, by validator: Validator) -> String {
  memory.transaction(store, fn(tx) {
    use card <- result.try(
      decisions.open(desk(), tx, occurrence: id, by: validator, latest: fn(ref) {
        ref.revision
      }),
    )
    decisions.decide(desk(), tx, card, Approve)
  })
  |> result.map(fn(known) { occurrence.status_name(known.status) })
  |> result.unwrap("refused")
}

// snips-end: either-several

pub fn ask(store: Memory, fee: String) -> String {
  let assert Ok(waiting) =
    memory.transaction(store, decisions.recommend(
      desk(),
      _,
      decisions.proposal(
        trigger: Trigger(kind: "request", id: fee),
        about: clinic.clinica_x,
        context: Manifest(refs: [], renderer: "refund-1"),
        recommending: Recommendation(
          output: Refund(fee:, cents: 1_200_000),
          by: Agent(kind: "billing", version: "3"),
          explanation: RunAnswer(run: "run-90"),
          signals: [],
          reads: [],
        ),
      ),
    ))
  waiting.id
}

/// One finance approval waits; a second releases. Elsewhere, the head of
/// finance alone releases.
pub fn run() -> List(String) {
  let store = memory.new()
  let first = ask(store, "fee-a")
  let second = ask(store, "fee-b")
  [
    approve(store, first, by: clinic.felipe),
    approve(store, first, by: clinic.bia),
    approve(store, second, by: head_of_finance),
  ]
}
