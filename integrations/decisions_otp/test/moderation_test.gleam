//// Use case 12, moderation at volume: 10 000 posts are classified by
//// eight processes. The policy proceeds at a score of 0.9 or above,
//// sampling 2 %, and asks `support` otherwise. Later, 50 appeals arrive
//// as assessments, 30 of them "wrong".

import decisions
import decisions/learning
import decisions/testing
import decisions/vocabulary.{
  Approve, Assessment, Classifier, Ref, Right, Validator, Wrong,
}
import decisions_otp/replay
import decisions_otp/store
import gleam/int
import gleam/list
import gleam/option.{None}
import support/lab

pub fn moderation_at_volume_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("moderation.classify", None), lab.scoring(2))
  let posts = lab.numbers(1, 10_000)
  let shares = list.sized_chunk(posts, 1250)
  let classified =
    replay.map(shares, 8, fn(share) {
      list.each(share, fn(n) {
        // One post in ten scores below the threshold.
        let score = case n % 10 {
          0 -> 0.5
          _ -> 0.95
        }
        let assert Ok(_) =
          store.transaction(s, lab.recommend(
            desk,
            _,
            "post-" <> int.to_string(n),
            about: lab.clinica,
            output: "ok",
            by: Classifier("moderation", "v1"),
            score:,
          ))
      })
    })
  assert list.all(classified, fn(done) { done == Ok(Nil) })
  // 9 000 proceeded and ran the tool; 1 000 wait for support.
  assert lab.effects(s, desk) == 9000
  let waiting = store.queue(store.handle(s), "support")
  assert list.length(waiting) == 1000
  // The sample is within 1 % to 3 % of what proceeded.
  let sampled = list.length(store.review_queue(store.handle(s)))
  assert sampled >= 90 && sampled <= 270
  // Support approves every waiting one.
  let dora = Validator("dora", ["support"])
  list.each(waiting, fn(id) {
    let assert Ok(_) =
      store.transaction(s, lab.open_and_decide(desk, _, id, dora, Approve))
  })
  let before = tally(s, desk)
  // 50 appeals arrive, 30 of them "wrong".
  list.each(lab.numbers(1, 50), fn(n) {
    let id = "post-" <> int.to_string(n * 10)
    let finding = case n <= 30 {
      True -> Wrong(None)
      False -> Right
    }
    let assert Ok(_) =
      store.transaction(s, decisions.assess(
        desk,
        _,
        occurrence: id,
        finding: Assessment(
          finding:,
          evidence: Ref("appeal", id, "1"),
          source: "appeals",
          known_at: store.now(s),
        ),
      ))
  })
  let after = tally(s, desk)
  // Agreement does not change with the appeals; accuracy does.
  assert after.agreed == before.agreed && after.judged == before.judged
  assert before.assessed == 0
  assert after.assessed == 50 && after.right == 20
  let assert Ok(summary) =
    testing.check(store.handle(s), store.inspection(), [
      testing.audit(desk, effects: fn(tx) {
        Ok(store.count(tx, "moderation.classify"))
      }),
    ])
  assert summary.occurrences == 10_000
  assert summary.released == 10_000
}

fn tally(
  s: store.Store,
  desk: decisions.Desk(String, store.Tx),
) -> learning.Tally {
  store.heads(store.handle(s))
  |> list.filter_map(fn(pair) {
    decisions.read(desk, store.handle(s), occurrence: pair.0)
  })
  |> learning.tally
  |> learning.total
}
