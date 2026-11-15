//// The wiring example runs: a refund decided through the supervised
//// store is followed by the supervised runtime.

import decisions
import decisions/vocabulary.{
  Approve, Manifest, Recommendation, Ref, RuleFired, Rules, Trigger, Validator,
}
import decisions_otp/runtime
import decisions_otp/store
import gleam/erlang/process
import support/lab
import wiring_example

pub fn the_wiring_example_follows_a_refund_test() {
  lab.quiet()
  let name = store.new_name("wiring_store")
  let control = runtime.new_control("wiring_runtime")
  let reply = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(started) = wiring_example.start(name, control)
    process.send(reply, started.pid)
    process.sleep_forever()
  })
  let assert Ok(tree) = process.receive(reply, 5000)
  let assert Ok(s) = store.named(name)
  let desk = wiring_example.refund_desk()
  let assert Ok(_) =
    store.transaction(s, decisions.recommend_once(
      desk,
      _,
      key: "refund-1",
      proposal: decisions.proposal(
        trigger: Trigger("message", "m-1"),
        about: lab.ana,
        context: Manifest(refs: [Ref("message", "m-1", "1")], renderer: "r-1"),
        recommending: Recommendation(
          output: "80.00",
          by: Rules("refund-rules", "1"),
          explanation: RuleFired("fee"),
          signals: [],
          reads: [],
        ),
      ),
    ))
  let assert Ok(_) =
    store.transaction(s, lab.open_and_decide(
      desk,
      _,
      "refund-1",
      Validator("bia", ["finance"]),
      Approve,
    ))
  assert lab.wait_until(
    fn() { store.count(store.handle(s), "outbox") == 1 },
    within: 5000,
  )
  assert store.count(store.handle(s), "refunds") == 1
  lab.stop_runtime(tree)
}
