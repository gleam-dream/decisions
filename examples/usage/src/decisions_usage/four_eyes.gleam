//// Four eyes, and escalation over time. A large refund needs two
//// different approvers, neither of them the person who asked. Unanswered
//// for four hours, managers may give the second approval too. After a day
//// it expires. All of it is policy data; the desk's wake-ups apply it.

// snips-start: four-eyes
import decisions
import decisions/memory.{type Memory, type Tx}
import decisions/occurrence.{type Occurrence}
import decisions/policy.{
  AnyoneHolding, Ask, Either, Several, SomeoneElseHolding, When,
}
import decisions/vocabulary.{
  type Validator, Agent, Approve, Manifest, Recommendation, RunAnswer, Trigger,
  Validator,
}
import decisions_usage/clinic.{type Refund, Refund}
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}

/// Rui manages the clinic's billing; he holds no finance set.
pub const rui = Validator(subject: "rui", holds: ["managers"])

pub fn policy() -> policy.Policy {
  let large = policy.at_least(clinic.amount(), 10_000.0)
  clinic.well_formed(policy.new(
    version: 1,
    rules: [
      When(
        policy.All([large, policy.waited(240)]),
        Ask(Several(
          2,
          Either([SomeoneElseHolding("finance"), AnyoneHolding("managers")]),
        )),
      ),
      When(large, Ask(Several(2, SomeoneElseHolding("finance")))),
    ],
    otherwise: SomeoneElseHolding("finance"),
  ))
}

pub fn desk() -> decisions.Desk(Refund, Tx) {
  decisions.desk(
    clinic.refund_point() |> decisions.valid_for(duration.hours(24)),
    drives: fn(_) { clinic.refund_fee() },
    under: fn(_) { Ok(policy()) },
    over: memory.port(),
  )
}

/// Felipe asks for a large refund for Clínica X.
pub fn ask(store: Memory) -> Result(Occurrence(Refund), decisions.Refusal) {
  memory.transaction(store, decisions.recommend_once(
    desk(),
    _,
    key: "refund-cx-1",
    proposal: decisions.proposal(
      trigger: Trigger(kind: "request", id: "refund-cx-1"),
      about: clinic.clinica_x,
      context: Manifest(refs: [], renderer: "refund-1"),
      recommending: Recommendation(
        output: Refund(fee: "annual-fee-2026", cents: 1_200_000),
        by: Agent(kind: "billing", version: "3"),
        explanation: RunAnswer(run: "run-77"),
        signals: [],
        reads: [],
      ),
    )
      |> decisions.asked_by("felipe"),
  ))
}

pub fn approve(
  store: Memory,
  id: String,
  by validator: Validator,
) -> Result(Occurrence(Refund), decisions.Refusal) {
  memory.transaction(store, fn(tx) {
    use card <- result.try(
      decisions.open(desk(), tx, occurrence: id, by: validator, latest: fn(ref) {
        ref.revision
      }),
    )
    decisions.decide(desk(), tx, card, Approve)
  })
}

/// The job queue's handler: deliver every wake-up that is due. One that
/// arrived early names the time to come back, and is snoozed until then.
pub fn deliver_due(store: Memory) -> List(Option(Timestamp)) {
  let #(_point, wake) = decisions.waker(desk())
  memory.take_due(store)
  |> list.filter_map(fn(due) {
    let delivered = memory.transaction(store, wake(_, due.occurrence))
    case delivered {
      Ok(Some(until)) -> memory.snooze(store, due, until)
      _ -> Nil
    }
    delivered
  })
}

// snips-end: four-eyes

/// The whole topic, as what each step returned.
pub fn run() -> List(String) {
  let store = memory.new()
  let at = fn(hours: Int) {
    memory.set_clock(
      store,
      timestamp.add(timestamp.unix_epoch, duration.hours(hours)),
    )
  }
  let describe = fn(outcome: Result(Occurrence(Refund), decisions.Refusal)) {
    case outcome {
      Ok(known) -> occurrence.status_name(known.status)
      Error(refusal) -> decisions.describe(refusal)
    }
  }
  let assert Ok(waiting) = ask(store)
  let felipe = describe(approve(store, waiting.id, by: clinic.felipe))
  let bia = describe(approve(store, waiting.id, by: clinic.bia))
  let rui_early = describe(approve(store, waiting.id, by: rui))
  at(4)
  let delivered = list.length(deliver_due(store))
  let rui_late = describe(approve(store, waiting.id, by: rui))
  [felipe, bia, rui_early, "delivered " <> int.to_string(delivered), rui_late]
}
