//// Use case 6: a second model reviews, as a consulted decision point.

import decisions.{type Desk, Gated}
import decisions/fact
import decisions/learning
import decisions/memory.{type Memory}
import decisions/occurrence
import decisions/policy.{
  All, AnyoneHolding, Ask, Consult, Never, Not, Policy, Proceed, When,
}
import decisions/vocabulary.{
  Agent, Approve, Manifest, ModelCall, ParentOccurrence, Receipt, Recommendation,
  Ref, Trigger,
}
import decisions/wire
import gleam/list
import gleam/option.{Some}
import gleam/result
import support/refund.{type Refund, Refund}
import support/world.{type World}

fn opinion() {
  fact.text("review.verdict")
}

/// Version 3: consult the reviewing model; proceed when it approves and the
/// amount is under R$500; otherwise ask a person.
fn policy() {
  Policy(
    version: 3,
    rules: [
      When(Not(policy.known(opinion())), Consult("billing.refund_review")),
      When(
        All([
          policy.is(opinion(), "approve"),
          policy.below(refund.amount(), 500.0),
        ]),
        Proceed(Never),
      ),
    ],
    otherwise: Ask(AnyoneHolding("finance")),
  )
}

/// Consulting queues the review, as a job would carry it.
fn outer() -> Desk(Refund, Memory) {
  refund.desk_of(refund.point() |> decisions.signal(opinion()), policy())
  |> decisions.consulting(with: fn(tx, consultation) {
    Ok(world.push(tx, "reviews_to_run", consultation.occurrence))
  })
}

/// The reviewing point is an ordinary decision point. Its output is a
/// recommended verdict, and its tool informs the occurrence that consulted
/// it.
fn review() -> Desk(String, Memory) {
  decisions.desk(
    decisions.point("billing.refund_review", wire.text()),
    drives: fn(_) {
      Gated(
        name: "inform",
        guard: fn(_, _) { Ok([]) },
        execute: fn(tx, released) {
          let assert Some(ParentOccurrence(id: consulted_by)) =
            decisions.parent(released)
          decisions.inform(
            outer(),
            tx,
            occurrence: consulted_by,
            from: "billing.refund_review",
            facts: [fact.set(opinion(), decisions.output(released))],
          )
          |> result.replace(Nil)
          |> result.map_error(fn(refusal) {
            decisions.Refuse(decisions.describe(refusal))
          })
        },
      )
    },
    under: fn(_) {
      Ok(Policy(version: 1, rules: [], otherwise: Proceed(Never)))
    },
    over: memory.port(),
  )
}

/// The reviewing model runs for each queued consultation.
fn run_reviews(w: World, verdict: String) -> List(String) {
  let assert Ok(reviews) =
    world.in_tx(w, fn(tx) {
      let queued = world.all(tx, "reviews_to_run")
      memory.put(tx, "reviews_to_run", "[]")
      list.try_map(queued, fn(consulted_by) {
        decisions.recommend(
          review(),
          tx,
          decisions.proposal(
            trigger: Trigger(kind: "occurrence", id: consulted_by),
            about: world.clinica,
            context: Manifest(
              refs: [Ref("occurrence", consulted_by, "1")],
              renderer: "review-1",
            ),
            recommending: Recommendation(
              reads: [],
              output: verdict,
              by: ModelCall("refund-review", "v1"),
              explanation: Receipt(Ref(
                "receipt",
                "review-" <> consulted_by,
                "1",
              )),
              signals: [],
            ),
          )
            |> decisions.hanging_from(ParentOccurrence(consulted_by)),
        )
        |> result.map(fn(reviewed) { reviewed.id })
      })
    })
  reviews
}

fn agent_recommends(w: World) {
  let assert Ok(recommended) =
    world.in_tx(w, refund.request(
      outer(),
      _,
      Trigger(kind: "run", id: "run-billing-1"),
      Agent(kind: "billing", version: "3"),
      Refund(fee: "fee-300", cents: 30_000),
    ))
  recommended
}

pub fn an_approving_review_lets_the_policy_proceed_test() {
  let w = world.new()
  let recommended = agent_recommends(w)

  // While the review runs, the outer occurrence stays recommended.
  assert recommended.status
    == occurrence.Recommended(consulting: Some("billing.refund_review"))
  assert refund.refunds(w) == []

  let assert [review_id] = run_reviews(w, "approve")
  let proceeded = world.read(w, outer(), recommended.id)
  let assert occurrence.Released(..) = proceeded.status
  assert refund.refunds(w) == ["fee-300:30000"]

  // The review is its own occurrence, hanging from the outer one.
  let reviewed = world.read(w, review(), review_id)
  assert reviewed.parent == Some(ParentOccurrence(recommended.id))
  let assert occurrence.Released(final: "approve", ..) = reviewed.status

  // A reviewing model's opinion is not a verdict.
  assert learning.total(learning.tally([proceeded])).judged == 0
}

pub fn a_rejecting_review_sends_it_to_a_person_test() {
  let w = world.new()
  let recommended = agent_recommends(w)
  let assert [_] = run_reviews(w, "reject")

  let asked = world.read(w, outer(), recommended.id)
  assert asked.status == occurrence.Awaiting(AnyoneHolding("finance"))
  assert refund.refunds(w) == []

  let assert Ok(approved) =
    world.in_tx(w, world.open_and_decide(
      outer(),
      _,
      recommended.id,
      world.caio,
      Approve,
    ))
  let assert occurrence.Released(..) = approved.status
  assert refund.refunds(w) == ["fee-300:30000"]
  assert learning.total(learning.tally([approved])).judged == 1
}
