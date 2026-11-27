//// Occurrence ids are unique by construction: a supervised restart, which
//// starts an empty store, never issues an id an earlier owner issued.

import decisions
import decisions/vocabulary.{Rules}
import decisions_otp/store
import gleam/erlang/process
import gleam/option.{None}
import gleam/order
import gleam/otp/static_supervisor as supervisor
import gleam/string
import support/lab

pub fn ids_are_not_reused_after_a_supervised_restart_test() {
  lab.quiet()
  let name = store.new_name("occurrence_ids")
  let reply = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(started) =
      supervisor.new(supervisor.RestForOne)
      |> supervisor.add(store.supervised(lab.config(), named: name))
      |> supervisor.start
    process.send(reply, started.pid)
    process.sleep_forever()
  })
  let assert Ok(tree) = process.receive(reply, 5000)
  let desk = lab.desk(lab.point("ids.restart", None), lab.asking("finance"))
  let assert Ok(s) = store.named(name)
  let assert Ok(before) = store.transaction(s, recommend(desk, _))
  lab.kill(store.owner(s))
  assert lab.wait_until(
    fn() {
      case store.named(name) {
        Ok(again) -> store.owner(again) != store.owner(s)
        Error(_) -> False
      }
    },
    within: 2000,
  )
  let assert Ok(again) = store.named(name)
  let assert Ok(after) = store.transaction(again, recommend(desk, _))
  assert before.id != after.id
  // A UUID version 7: ids made later sort later.
  assert string.compare(before.id, after.id) == order.Lt
  lab.stop_runtime(tree)
}

fn recommend(desk, tx) {
  decisions.recommend(
    desk,
    tx,
    decisions.proposal(
      trigger: vocabulary.Trigger("lab", "ids"),
      about: lab.ana,
      context: vocabulary.Manifest(refs: [], renderer: "lab-1"),
      recommending: vocabulary.Recommendation(
        output: "pay",
        by: Rules("rules", "1"),
        explanation: vocabulary.RuleFired("lab"),
        signals: [],
        reads: [],
      ),
    ),
  )
}
