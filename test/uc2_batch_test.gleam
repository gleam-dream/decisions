//// Use case 2: batch classification with sampling and assessment.

import decisions
import decisions/learning.{Tally}
import decisions/memory
import decisions/occurrence
import decisions/testing
import decisions/vocabulary.{
  Approve, Assessment, Classifier, Correct, Reason, Ref, Right, Rules, Wrong,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import support/classify
import support/world

pub fn five_hundred_transactions_proceed_sample_and_are_assessed_test() {
  let w = world.new()
  let classified =
    classify.batch(w, from: 1, to: 500, under: classify.production())

  // 475 proceed and each class is stored once; 25 await a person.
  assert list.length(classify.classes(w)) == 475
  assert list.length(list.unique(classify.classes(w))) == 475
  assert list.length(memory.queue(w.db, "finance")) == 25

  // Sampling is a function of the occurrence: an identical run in another
  // world samples the same set.
  let sampled = memory.review_queue(w.db)
  let other = world.new()
  let _ = classify.batch(other, from: 1, to: 500, under: classify.production())
  assert memory.review_queue(other.db) == sampled
  assert list.length(sampled) >= 10 && list.length(sampled) <= 40

  let desk = classify.desk(classify.production())
  list.each(sampled, fn(id) {
    let assert Ok(found) = list.find(classified, fn(o) { o.id == id })
    let assert occurrence.Released(..) = found.status
    assert found.sampled
  })

  // Felipe reviews three after the fact: two approvals and one correction.
  let assert [first, second, third, ..] = sampled
  let review = fn(id, verdict) {
    let assert Ok(_) =
      world.in_tx(w, fn(tx) {
        let assert Ok(card) = world.open(desk, tx, id, world.felipe)
        decisions.review(desk, tx, card, verdict)
      })
    Nil
  }
  review(first, Approve)
  review(second, Approve)
  review(third, Correct("payroll", Reason("wrong_fact", None)))
  assert list.length(memory.review_queue(w.db)) == list.length(sampled) - 3
  let read_all = fn() {
    list.map(classified, fn(o) { world.read(w, desk, o.id) })
  }
  let reviewed = learning.total(learning.tally(read_all()))
  assert #(reviewed.agreed, reviewed.judged) == #(2, 3)

  // At 21 days, what proved true is appended.
  world.at(w, duration.hours(21 * 24))
  let before = read_all()
  let assess = fn(n: Int, finding) {
    let assert Ok(target) =
      list.find(classified, fn(o) { o.context == classify.context(n) })
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
  assess(7, Wrong(Some("payroll")))
  assess(8, Wrong(Some("payroll")))
  assess(1, Right)

  // Outputs and verdicts are unchanged.
  let after = read_all()
  assert list.map(after, fn(o) { o.status })
    == list.map(before, fn(o) { o.status })
  assert list.map(after, occurrence.reviews)
    == list.map(before, occurrence.reviews)

  // Accuracy per recommender version.
  let tallies = learning.tally(after)
  let assert Ok(Tally(right: 0, assessed: 1, ..)) =
    list.key_find(tallies, Rules("fee-rules", "v1"))
  let assert Ok(Tally(right: 1, assessed: 3, ..)) =
    list.key_find(tallies, Classifier("tx-classifier", "v3"))
  world.invariants_hold(w, [
    testing.audit(desk, effects: world.effects("classes")),
  ])
}
