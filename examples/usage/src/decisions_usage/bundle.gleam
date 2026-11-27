//// Several actions from one recommendation. A model reads an expense
//// report and proposes one payment per line. Each line is an occurrence
//// of its own, judged and released on its own, and all of them belong to
//// one bundle. What follows the line point pays the report out once,
//// when every line has settled.

// snips-start: bundle
import decisions
import decisions/memory.{type Memory}
import decisions/policy.{AnyoneHolding, Never, Proceed}
import decisions/vocabulary.{
  Approve, Manifest, ModelCall, Reason, Recommendation, Reject, RuleFired,
  Subject, Trigger,
}
import decisions/wire
import decisions_usage/clinic
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result

fn tool(table: String) -> decisions.Gated(String, Memory) {
  decisions.Gated(
    name: table,
    guard: fn(_, _) { Ok([]) },
    execute: fn(tx, released) {
      memory.put(
        tx,
        table <> ":" <> decisions.occurrence_of(released),
        decisions.output(released),
      )
      Ok(Nil)
    },
  )
}

/// Each line asks finance.
pub fn lines() -> decisions.Desk(String, Memory) {
  decisions.desk(
    decisions.point("expense.line", wire.text()),
    drives: fn(_) { tool("approved") },
    under: fn(_) {
      Ok(clinic.well_formed(policy.new(1, [], AnyoneHolding("finance"))))
    },
    over: memory.port(),
  )
}

/// The payout of a whole report proceeds on its own.
pub fn payouts() -> decisions.Desk(String, Memory) {
  decisions.desk(
    decisions.point("expense.payout", wire.text()),
    drives: fn(_) { tool("paid") },
    under: fn(_) {
      Ok(
        clinic.well_formed(policy.new(
          1,
          [policy.When(policy.Always, Proceed(Never, None))],
          AnyoneHolding("finance"),
        )),
      )
    },
    over: memory.port(),
  )
}

fn proposal(report: String, output: String) -> decisions.Proposal(String) {
  decisions.proposal(
    trigger: Trigger(kind: "expense_report", id: report),
    about: Subject(kind: "employee", id: "ana"),
    context: Manifest(refs: [], renderer: "expense-1"),
    recommending: Recommendation(
      output:,
      by: ModelCall(configuration: "expense-reader", version: "3"),
      explanation: RuleFired("one line, one payment"),
      signals: [],
      reads: [],
    ),
  )
}

/// The model's answer for a report: one occurrence per line, admitted as
/// one bundle in one transaction.
pub fn admit(
  store: Memory,
  report: String,
  amounts: List(String),
) -> Result(List(String), decisions.Refusal) {
  memory.transaction(store, decisions.recommend_bundle(
    lines(),
    _,
    bundle: report,
    items: list.index_map(amounts, fn(amount, n) {
      #("line-" <> int.to_string(n + 1), proposal(report, amount))
    }),
  ))
  |> result.map(list.map(_, fn(line) { line.id }))
}

/// What follows the line point, handed each settled line: once its
/// bundle is complete, recommend the payout under a key derived from the
/// bundle, so a second follower that sees it complete adds nothing.
pub fn settled(tx: Memory, line: String) -> Result(Nil, decisions.Refusal) {
  use known <- result.try(decisions.read(lines(), tx, occurrence: line))
  case known.bundle {
    None -> Ok(Nil)
    Some(bundle) -> {
      let report = vocabulary.bundle_key(bundle)
      use members <- result.try(decisions.members(lines(), tx, bundle: report))
      case decisions.is_complete(members) {
        False -> Ok(Nil)
        True ->
          decisions.recommend_once(
            payouts(),
            tx,
            key: "payout:" <> report,
            proposal: proposal(report, "pay " <> report),
          )
          |> result.replace(Nil)
      }
    }
  }
}

// snips-end: bundle

/// The whole topic: three lines, the second rejected; the report is paid
/// once, only after the last line settles.
pub fn run() -> #(Bool, Bool, List(String)) {
  let store = memory.new()
  let bia = vocabulary.Validator(subject: "bia", holds: ["finance"])
  let assert Ok(ids) = admit(store, "report-7", ["30.00", "1200.00", "80.00"])
  let decide = fn(id, verdict) {
    let assert Ok(_) =
      memory.transaction(store, fn(tx) {
        use card <- result.try(
          decisions.open(lines(), tx, occurrence: id, by: bia, latest: fn(ref) {
            ref.revision
          }),
        )
        decisions.decide(lines(), tx, card, verdict)
      })
    // A runtime hands the settlement to the follower in a transaction of
    // its own, after the verdict committed.
    let assert Ok(Nil) = memory.transaction(store, settled(_, id))
    Nil
  }
  let assert [first, second, third] = ids
  decide(first, Approve)
  decide(second, Reject(Reason("over_limit", None)))
  let paid_before =
    memory.get(store, "paid:payout:report-7") == Ok("pay report-7")
  decide(third, Approve)
  let paid_after =
    memory.get(store, "paid:payout:report-7") == Ok("pay report-7")
  let approved =
    list.filter_map(ids, fn(id) { memory.get(store, "approved:" <> id) })
  #(paid_before, paid_after, approved)
}
