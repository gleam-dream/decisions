//// Members of one bundle admitted by concurrent transactions over the
//// process-safe store never exceed the bundle's size.

import decisions
import decisions/vocabulary.{
  Manifest, Recommendation, RuleFired, Subject, Trigger,
}
import decisions_otp/store
import gleam/erlang/process
import gleam/option.{None}
import gleam/result
import support/lab

fn member(item: String) -> decisions.Proposal(String) {
  decisions.proposal(
    trigger: Trigger(kind: "report", id: item),
    about: Subject("employee", "ana"),
    context: Manifest(refs: [], renderer: "expense-1"),
    recommending: Recommendation(
      output: item,
      by: vocabulary.Rules("reader", "1"),
      explanation: RuleFired("one line"),
      signals: [],
      reads: [],
    ),
  )
}

fn report() -> vocabulary.Bundle {
  let assert Ok(report) = vocabulary.bundle(key: "report-7", size: 2)
  report
}

pub fn concurrent_admissions_never_exceed_the_size_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("bundle.lines", None), lab.asking("finance"))
  let holding = process.new_subject()
  let ended = process.new_subject()
  // The first transaction admits one line and stays open.
  process.spawn(fn() {
    let gate = process.new_subject()
    let outcome =
      store.transaction(s, fn(tx) {
        use _ <- result.try(decisions.recommend_member(
          desk,
          tx,
          of: report(),
          item: "a",
          proposal: member("a"),
        ))
        process.send(holding, gate)
        let _ = process.receive(gate, 5000)
        Ok(Nil)
      })
    process.send(ended, outcome)
  })
  let assert Ok(gate) = process.receive(holding, 5000)
  // The second admits two more lines while the first is open.
  let second = process.new_subject()
  process.spawn(fn() {
    let outcome =
      store.transaction(s, fn(tx) {
        use _ <- result.try(decisions.recommend_member(
          desk,
          tx,
          of: report(),
          item: "b",
          proposal: member("b"),
        ))
        use _ <- result.try(decisions.recommend_member(
          desk,
          tx,
          of: report(),
          item: "c",
          proposal: member("c"),
        ))
        Ok(Nil)
      })
    process.send(second, outcome)
  })
  // The second waits for the bundle's lock, which the first holds.
  assert process.receive(second, 200) == Error(Nil)
  process.send(gate, Nil)
  let assert Ok(Ok(Nil)) = process.receive(ended, 5000)
  // Then it sees the first's line: "b" fills the bundle and "c" is one
  // too many, so its whole transaction is refused.
  let assert Ok(Error(decisions.BadBundle("report-7", decisions.BundleFull))) =
    process.receive(second, 5000)
  let assert Ok(members) =
    store.transaction(s, decisions.members(desk, _, bundle: "report-7"))
  assert list_length(members) == 1
}

fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}
