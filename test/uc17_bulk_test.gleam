//// Use case 17: a bulk verdict. The library has no bulk verb. The caller
//// chooses the transaction, and with it the answer to "what if one fails".

import decisions.{type Desk, Gated}
import decisions/memory.{type Memory}
import decisions/occurrence
import decisions/vocabulary.{
  type Subject, Approve, Manifest, Recommendation, RuleFired, Rules, Trigger,
}
import gleam/int
import gleam/list
import gleam/result
import support/classify
import support/world.{type World}

/// The same tool with a guard: a company whose books are closed takes no
/// new class.
fn desk() -> Desk(String, Memory) {
  decisions.desk(
    classify.point(),
    drives: fn(_) {
      Gated(..classify.store_class(), guard: fn(tx, subject: Subject) {
        case memory.get(tx, "closed:" <> subject.id) {
          Ok(_) ->
            Error(vocabulary.Refuse(
              "the books of " <> subject.id <> " are closed",
            ))
          Error(Nil) -> Ok([])
        }
      })
    },
    under: fn(_) { Ok(classify.always_ask()) },
    over: memory.port(),
  )
}

/// 200 classifications wait. Number 77 is about Clínica Y.
fn waiting(w: World) -> List(String) {
  let assert Ok(ids) =
    world.in_tx(w, fn(tx) {
      list.try_map(world.numbers(1, 200), fn(n) {
        decisions.recommend(
          desk(),
          tx,
          decisions.proposal(
            trigger: Trigger(kind: "transaction", id: int.to_string(n)),
            about: case n {
              77 -> world.clinica_y
              _ -> world.clinica
            },
            context: Manifest(refs: [], renderer: "classify-1"),
            recommending: Recommendation(
              output: "supplier",
              by: Rules("fee-rules", "v1"),
              explanation: RuleFired("n/a"),
              signals: [],
              reads: [],
            ),
          ),
        )
        |> result.map(fn(o) { o.id })
      })
    })
  ids
}

pub fn in_one_transaction_a_bulk_verdict_is_all_or_nothing_test() {
  let w = world.new()
  let ids = waiting(w)
  memory.put(w.db, "closed:clinica-y", "yes")

  let all_at_once =
    world.in_tx(w, fn(tx) {
      list.try_map(ids, fn(id) {
        world.open_and_decide(desk(), tx, id, world.caio, Approve)
      })
    })
  assert result.map_error(all_at_once, decisions.describe)
    == Error("the books of clinica-y are closed")
  // Nothing was decided and nothing was stored. Every record is whole.
  assert classify.classes(w) == []
  assert list.length(memory.queue(w.db, "finance")) == 200
}

pub fn one_transaction_each_decides_199_and_refuses_one_test() {
  let w = world.new()
  let ids = waiting(w)
  memory.put(w.db, "closed:clinica-y", "yes")

  let outcomes =
    list.map(ids, fn(id) {
      world.in_tx(w, world.open_and_decide(desk(), _, id, world.caio, Approve))
    })
  let #(decided, refused) = result.partition(outcomes)
  assert list.length(decided) == 199
  assert list.map(refused, decisions.describe)
    == ["the books of clinica-y are closed"]
  assert list.length(classify.classes(w)) == 199
  // The one that was refused still waits, with no verdict on it.
  let assert [left] = memory.queue(w.db, "finance")
  let still = world.read(w, desk(), left)
  assert still.subject == world.clinica_y
  assert occurrence.verdicts(still) == []
}
