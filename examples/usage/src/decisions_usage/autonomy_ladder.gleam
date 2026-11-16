//// A policy that grows from "always ask" to "proceed when confident". The
//// application code does not change between versions: each rung is a
//// policy value, published by a write and checked before it is stored.

// snips-start: autonomy-ladder
import decisions
import decisions/fact
import decisions/memory.{type Memory}
import decisions/occurrence.{type Occurrence}
import decisions/policy.{
  type Policy, AnyoneHolding, Ask, Never, OwnAct, PerCent, Policy, Proceed, When,
}
import decisions/vocabulary.{
  type Fact, Classifier, Manifest, Receipt, Recommendation, Ref, Trigger,
}
import decisions_usage/clinic.{type Refund, Refund}
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration

/// The classifier's confidence, reported beside its output.
pub fn confidence() -> fact.Key(Float) {
  fact.number("confidence")
}

/// The classifier's confidence as a signal.
pub fn confidence_signal(value: Float) -> #(String, Fact) {
  fact.set(confidence(), value)
}

/// The point declares the signal, so a policy may read it.
pub fn point() -> decisions.Point(Refund) {
  clinic.refund_point() |> decisions.signal(confidence())
}

/// Rung 1: a person's own act proceeds; anything else asks finance.
pub fn assisted() -> Policy {
  Policy(
    version: 1,
    rules: [When(OwnAct, Proceed(Never, None))],
    otherwise: Ask(AnyoneHolding("finance")),
  )
}

/// Rung 2: small refunds the classifier is sure of proceed, and one in ten
/// of those is sampled for a review after the fact.
pub fn confident() -> Policy {
  Policy(
    version: 2,
    rules: [
      When(OwnAct, Proceed(Never, None)),
      When(
        policy.All([
          policy.at_least(confidence(), 0.95),
          policy.below(clinic.amount(), 100.0),
        ]),
        Proceed(PerCent(10), None),
      ),
    ],
    otherwise: Ask(AnyoneHolding("finance")),
  )
}

/// Rung 3: the same refunds proceed with a thirty-minute undo window
/// instead of a sample: each is held, and released when the window ends
/// unless finance withdraws it first.
pub fn undoable() -> Policy {
  Policy(
    version: 3,
    rules: [
      When(OwnAct, Proceed(Never, None)),
      When(
        policy.All([
          policy.at_least(confidence(), 0.95),
          policy.below(clinic.amount(), 100.0),
        ]),
        Proceed(Never, Some(duration.minutes(30))),
      ),
    ],
    otherwise: Ask(AnyoneHolding("finance")),
  )
}

/// Publishing a version is a write, refused when the policy reads a fact
/// the point never declares.
pub fn publish(
  store: Memory,
  version: Policy,
) -> Result(Nil, List(policy.Fault)) {
  use Nil <- result.map(decisions.publishable(point(), version))
  memory.put(
    store,
    "policy:billing.fee_refund",
    json.to_string(policy.to_json(version)),
  )
}

/// The desk reads whichever version is published, in the caller's
/// transaction.
pub fn desk() -> decisions.Desk(Refund, Memory) {
  decisions.desk(
    point(),
    drives: fn(_) { clinic.refund_fee() },
    under: fn(tx) {
      use text <- result.try(
        memory.get(tx, "policy:billing.fee_refund")
        |> result.replace_error("no policy is published"),
      )
      json.parse(text, policy.decoder())
      |> result.replace_error("the stored policy does not decode")
    },
    over: memory.port(),
  )
}

/// The one code path that files a refund. It knows nothing of the policy.
pub fn arrive(
  store: Memory,
  fee: String,
  cents: Int,
  sure: Float,
) -> Result(Occurrence(Refund), decisions.Refusal) {
  memory.transaction(store, decisions.recommend_once(
    desk(),
    _,
    key: fee,
    proposal: decisions.proposal(
      trigger: Trigger(kind: "statement_line", id: fee),
      about: clinic.clinica_x,
      context: Manifest(
        refs: [Ref("statement_line", fee, "1")],
        renderer: "refund-1",
      ),
      recommending: Recommendation(
        output: Refund(fee:, cents:),
        by: Classifier(name: "refund-classifier", version: "v5"),
        explanation: Receipt(Ref("classifier", fee, "1")),
        signals: [fact.set(confidence(), sure)],
        reads: [],
      ),
    ),
  ))
}

// snips-end: autonomy-ladder

/// The whole topic, as the statuses each arrival ends in.
pub fn run() -> List(String) {
  let store = memory.new()
  let status = fn(arrived: Result(Occurrence(Refund), decisions.Refusal)) {
    let assert Ok(known) = arrived
    occurrence.status_name(known.status)
  }
  let assert Ok(Nil) = publish(store, assisted())
  let first = status(arrive(store, "fee-1", 8000, 0.99))
  let assert Ok(Nil) = publish(store, confident())
  let second = status(arrive(store, "fee-2", 8000, 0.99))
  let third = status(arrive(store, "fee-3", 8000, 0.6))
  let fourth = status(arrive(store, "fee-4", 90_000, 0.99))
  let assert Ok(Nil) = publish(store, undoable())
  let fifth = status(arrive(store, "fee-5", 8000, 0.99))
  // A version that reads a misspelt fact is never stored.
  let typo =
    Policy(..confident(), version: 4, rules: [
      When(policy.AtLeast("confidense", 0.9), Proceed(Never, None)),
    ])
  let refused = case publish(store, typo) {
    Error([policy.UndeclaredFact("confidense")]) -> "refused"
    _ -> "published"
  }
  [first, second, third, fourth, fifth, refused]
}
