//// Use case 7: replaying a new model version against the record.

import decisions
import decisions/learning.{Archive, Replay, Tally}
import decisions/memory
import decisions/model.{type Model}
import decisions/vocabulary.{
  Approve, Assessment, Classifier, Correct, Reason, Recommendation, Ref, Right,
  RuleFired, Wrong,
}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration
import support/classify
import support/world

/// The candidate: classifier `v4`, as one model over the same context.
fn candidate() -> Model(String) {
  model.new(fn(context: vocabulary.Manifest, sources: model.Sources) {
    use transaction <- result.try(
      list.first(context.refs) |> result.replace_error(model.Declined("no ref")),
    )
    use content <- result.try(sources.resolve(transaction))
    let assert Ok(n) = int.parse(content)
    let class = case n, n % 5 {
      7, _ | 8, _ -> "payroll"
      2, _ -> "rent"
      _, 0 -> "bank_fee"
      _, 4 -> "tax"
      _, _ -> "supplier"
    }
    Ok(
      Recommendation(
        class,
        Classifier("tx-classifier", "v4"),
        RuleFired("n/a"),
        [],
        [],
      ),
    )
  })
}

pub fn a_candidate_is_scored_on_the_record_before_it_is_published_test() {
  let w = world.new()
  let desk = classify.desk(classify.always_ask())
  let recorded =
    classify.batch(w, from: 1, to: 20, under: classify.always_ask())

  // Twenty recorded verdicts: 7 and 8 were corrected, the rest approved.
  list.each(recorded, fn(o) {
    let verdict = case
      o.context == classify.context(7) || o.context == classify.context(8)
    {
      True -> Correct("payroll", Reason("wrong_fact", None))
      False -> Approve
    }
    let assert Ok(_) =
      world.in_tx(w, world.open_and_decide(desk, _, o.id, world.felipe, verdict))
  })
  // And four assessments, three weeks later.
  world.at(w, duration.hours(21 * 24))
  let assess = fn(n: Int, finding) {
    let assert Ok(target) =
      list.find(recorded, fn(o) { o.context == classify.context(n) })
    let assert Ok(_) =
      world.in_tx(w, decisions.assess(
        desk,
        _,
        occurrence: target.id,
        finding: Assessment(
          finding:,
          evidence: Ref("statement", "close-2026-11", "1"),
          source: "accountant's close",
          known_at: memory.now(w.db),
        ),
      ))
    Nil
  }
  assess(5, Wrong(Some("interest")))
  assess(7, Right)
  assess(1, Right)
  assess(4, Wrong(Some("fine")))

  let classes_before = classify.classes(w)
  let entries_before = list.map(recorded, fn(o) { memory.entries(w.db, o.id) })

  // The export resolves every input; replay then needs nothing else.
  let archive =
    Archive(
      render: fn(context) {
        case context.renderer {
          "classify-1" -> Ok("Classify this bank transaction.")
          other -> Error("no renderer " <> other)
        }
      },
      reads: world.reads(w),
      content: classify.resolver,
    )
  let examples =
    list.map(recorded, fn(o) {
      let assert Ok(example) =
        learning.example(
          world.read(w, desk, o.id),
          as_of: memory.now(w.db),
          from: archive,
        )
      example
    })
  let replay = learning.replay(examples, candidate(), same: fn(a, b) { a == b })

  // v4 agrees with what validators let through on 19 of 20, and is right on
  // 2 of the 4 assessed. Every read was answered from the record.
  assert replay
    == Replay(
      tally: Tally(agreed: 19, judged: 20, rejected: 0, right: 2, assessed: 4),
      unanswered: [],
    )

  // Replay called no executor and changed no record.
  assert classify.classes(w) == classes_before
  assert list.map(recorded, fn(o) { memory.entries(w.db, o.id) })
    == entries_before

  // Spread over workers and merged, the figure is the same.
  assert learning.merge(
      list.map(
        examples,
        learning.replay_one(_, candidate(), same: fn(a, b) { a == b }),
      ),
    )
    == replay
}
