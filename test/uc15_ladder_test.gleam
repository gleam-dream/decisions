//// Use case 15: the autonomy ladder. One point, four policy versions, and
//// no change of application code between them: `arrive` and `caio` are
//// the whole application. The blind rung (a model nobody sees) needs the
//// second build's blind path and is left out here.

import decisions
import decisions/learning.{Archive}
import decisions/model
import decisions/occurrence.{type Occurrence}
import decisions/policy.{
  type Policy, AnyoneHolding, Ask, Never, OwnAct, PerCent, Policy, Proceed, When,
}
import decisions/vocabulary.{
  Approve, Assessment, Correct, Person, Reason, Recommendation, Ref, Right,
  Trigger, Wrong,
}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleam/time/timestamp
import support/classify
import support/world.{type World}

/// What a careful person writes. The cascade differs from it exactly when
/// `n` is a multiple of seven.
fn truth(n: Int) -> String {
  case n % 7, n % 5 {
    0, _ -> "payroll"
    _, 0 -> "bank_fee"
    _, 4 -> "tax"
    _, _ -> "supplier"
  }
}

fn version(number: Int) -> Policy {
  let own = When(OwnAct, Proceed(Never, None))
  let finance = AnyoneHolding("finance")
  case number {
    // 1. Cold start: there is no model. A person's own act proceeds.
    1 -> Policy(version: 1, rules: [own], otherwise: Ask(finance))
    // 2. Assisted: the person sees the recommendation.
    2 -> Policy(version: 2, rules: [own], otherwise: Ask(finance))
    // 3. Sampled: it proceeds on a high score, and one in ten is reviewed.
    3 ->
      Policy(
        version: 3,
        rules: [
          own,
          When(
            policy.at_least(classify.score(), 0.9),
            Proceed(PerCent(10), None),
          ),
        ],
        otherwise: Ask(finance),
      )
    // 4. Demotion.
    _ -> Policy(version: 4, rules: [own], otherwise: Ask(finance))
  }
}

fn key(n: Int) -> String {
  "tx-" <> int.to_string(n)
}

/// Stage 1 only: Caio classifies by hand.
fn by_hand(w: World, n: Int) -> Occurrence(String) {
  let assert Ok(done) =
    world.in_tx(w, decisions.recommend_once(
      classify.desk(version(1)),
      _,
      key: key(n),
      proposal: decisions.proposal(
        trigger: Trigger(kind: "transaction", id: int.to_string(n)),
        about: world.clinica,
        context: classify.context(n),
        recommending: Recommendation(
          output: truth(n),
          by: Person("caio"),
          explanation: vocabulary.OwnAct,
          signals: [],
          reads: [],
        ),
      ),
    ))
  done
}

/// A transaction arrives and the model recommends. What happens next is the
/// policy's business.
fn arrive(w: World, policy: Policy, n: Int) -> Occurrence(String) {
  let assert Ok(recommendation) =
    model.run(classify.cascade(), classify.context(n), classify.sources())
  let assert Ok(arrived) =
    world.in_tx(w, decisions.recommend_once(
      classify.desk(policy),
      _,
      key: key(n),
      proposal: decisions.proposal(
        trigger: Trigger(kind: "transaction", id: int.to_string(n)),
        about: world.clinica,
        context: classify.context(n),
        recommending: recommendation,
      ),
    ))
  arrived
}

/// Caio's one screen.
fn caio(w: World, policy: Policy, id: String, n: Int) -> Occurrence(String) {
  let assert Ok(decided) =
    world.in_tx(w, fn(tx) {
      let desk = classify.desk(policy)
      let assert Ok(card) = world.open(desk, tx, id, world.caio)
      decisions.decide(
        desk,
        tx,
        card,
        case decisions.shown(card).recommendation.output == truth(n) {
          True -> Approve
          False -> Correct(truth(n), Reason("class", None))
        },
      )
    })
  decided
}

pub fn one_point_climbs_from_no_model_to_sampled_and_back_test() {
  let w = world.new()
  let same = fn(a: String, b: String) { a == b }

  // 1. Cold start. Forty records exist before any model does.
  let cold = list.map(world.numbers(1, 40), by_hand(w, _))
  assert list.length(classify.classes(w)) == 40

  // They replay a candidate model with no network: its first agreement
  // figure, measured against people, before it ever ran live.
  let archive =
    Archive(
      render: fn(_) { Ok("classify") },
      reads: fn(_) { [] },
      content: classify.resolver,
    )
  let far = timestamp.add(world.t0(), duration.hours(1000))
  let assert Ok(examples) =
    list.try_map(cold, learning.example(_, as_of: far, from: archive))
  let replayed = learning.replay(examples, classify.cascade(), same:)
  assert replayed.unanswered == []
  assert #(replayed.tally.agreed, replayed.tally.judged) == #(35, 40)

  // 2. Assisted. Caio sees the recommendation and approves or corrects.
  let assisted =
    list.map(world.numbers(41, 59), fn(n) {
      let arrived = arrive(w, version(2), n)
      caio(w, version(2), arrived.id, n)
    })
  let tally = learning.total(learning.tally(assisted))
  assert #(tally.agreed, tally.judged) == #(16, 19)
  let left_waiting = arrive(w, version(2), 60)

  // 3. Sampled. High scores proceed; one in ten of them is reviewed.
  let automatic = list.map(world.numbers(101, 200), arrive(w, version(3), _))
  let proceeded =
    list.filter(automatic, fn(o) {
      case o.status {
        occurrence.Released(..) -> True
        _ -> False
      }
    })
  assert list.length(proceeded) == 95
  let sampled = list.count(proceeded, fn(o) { o.sampled })
  assert sampled >= 3 && sampled <= 20

  // The occurrence that waited under version 2 is decided as version 2
  // left it, though version 3 is now published.
  let late = caio(w, version(3), left_waiting.id, 60)
  assert late.policy_version == Some(2)
  let assert occurrence.Released(..) = late.status

  // 4. Demotion. What proved true arrives for everything that proceeded.
  let assessed =
    list.map(proceeded, fn(o) {
      let assert Ok(n) = int.parse(string_after(o.id))
      let assert occurrence.Released(final:, ..) = o.status
      let assert Ok(known) =
        world.in_tx(w, decisions.assess(
          classify.desk(version(3)),
          _,
          occurrence: o.id,
          finding: Assessment(
            finding: case final == truth(n) {
              True -> Right
              False -> Wrong(truth: Some(truth(n)))
            },
            evidence: Ref("audit", o.id, "1"),
            source: "audit",
            known_at: far,
          ),
        ))
      known
    })
  let accuracy = learning.total(learning.tally(assessed))
  assert #(accuracy.right, accuracy.assessed) == #(82, 95)

  // Accuracy fell below what version 3 was granted on, so version 4 is
  // published. Nothing proceeds now.
  let after = arrive(w, version(4), 201)
  let assert occurrence.Awaiting(_) = after.status
}

fn string_after(id: String) -> String {
  case id {
    "tx-" <> n -> n
    other -> other
  }
}
