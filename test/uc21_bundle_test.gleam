//// Use case 21: one recommendation, several actions. A model reads an
//// expense report and proposes one payment per line. Each line is an
//// ordinary occurrence, judged, released and measured on its own, and all
//// of them belong to one bundle, `report-7`, of a known size. Whoever
//// follows the line point starts the payout once, when every member of
//// the bundle has settled.

import decisions.{type Desk, Gated}
import decisions/memory.{type Memory}
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Ask, Never, Policy, Proceed}
import decisions/store
import decisions/testing
import decisions/vocabulary.{
  type Bundle, Approve, Bundle, Manifest, Reason, Recommendation, Reject,
  RuleFired, Rules, Trigger,
}
import decisions/wire
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import support/world.{type World}

fn line_desk() -> Desk(String, Memory) {
  decisions.desk(
    decisions.point("expense.line", wire.text()),
    drives: fn(_) { tool("lines_paid") },
    under: fn(_) {
      Ok(Policy(version: 1, rules: [], otherwise: Ask(AnyoneHolding("finance"))))
    },
    over: memory.port(),
  )
}

/// A second point in the same bundle: the receipt is filed without a
/// person.
fn receipt_desk() -> Desk(String, Memory) {
  decisions.desk(
    decisions.point("expense.receipt", wire.text()),
    drives: fn(_) { tool("receipts_filed") },
    under: fn(_) {
      Ok(Policy(version: 1, rules: [], otherwise: Proceed(Never, None)))
    },
    over: memory.port(),
  )
}

fn payout_desk() -> Desk(String, Memory) {
  decisions.desk(
    decisions.point("expense.payout", wire.text()),
    drives: fn(_) { tool("payouts") },
    under: fn(_) {
      Ok(Policy(version: 1, rules: [], otherwise: Proceed(Never, None)))
    },
    over: memory.port(),
  )
}

fn tool(table: String) -> decisions.Gated(String, Memory) {
  Gated(name: table, guard: fn(_, _) { Ok([]) }, execute: fn(tx, released) {
    Ok(world.push(tx, table, decisions.output(released)))
  })
}

fn proposal(output: String) -> decisions.Proposal(String) {
  decisions.proposal(
    trigger: Trigger(kind: "report", id: "report-7"),
    about: world.ana,
    context: Manifest(refs: [], renderer: "expense-1"),
    recommending: Recommendation(
      output:,
      by: Rules("expense-model", "1"),
      explanation: RuleFired("line"),
      signals: [],
      reads: [],
    ),
  )
}

/// The lines of report-7, admitted as one bundle in one transaction.
fn admit_lines(w: World) -> List(String) {
  let assert Ok(lines) =
    world.in_tx(
      w,
      decisions.recommend_bundle(line_desk(), _, bundle: "report-7", items: [
        #("report-7/l1", proposal("l1: 30.00")),
        #("report-7/l2", proposal("l2: 1200.00")),
        #("report-7/l3", proposal("l3: 80.00")),
      ]),
    )
  list.map(lines, fn(line) { line.id })
}

/// What the line point's follower does with each settlement notice: when
/// the bundle is complete, recommend the payout under a key derived from
/// the bundle, so a second follower that sees it complete adds nothing.
fn follow(tx: Memory, bundle: String) -> Result(Nil, decisions.Refusal) {
  use members <- result.try(decisions.members(line_desk(), tx, bundle:))
  case decisions.is_complete(members) {
    False -> Ok(Nil)
    True ->
      decisions.recommend_once(
        payout_desk(),
        tx,
        key: "payout:" <> bundle,
        proposal: proposal("pay " <> bundle),
      )
      |> result.replace(Nil)
  }
}

fn statuses(w: World, bundle: String) -> List(#(String, store.Status)) {
  let assert Ok(members) =
    world.in_tx(w, decisions.members(line_desk(), _, bundle:))
  list.map(members, fn(member) { #(member.occurrence, member.status) })
}

pub fn every_line_is_an_occurrence_of_its_own_bundle_test() {
  let w = world.new()
  let ids = admit_lines(w)
  assert ids == ["report-7/l1", "report-7/l2", "report-7/l3"]
  list.each(ids, fn(id) {
    let known = world.read(w, line_desk(), id)
    assert known.bundle == Some(Bundle(key: "report-7", size: 3))
    let assert occurrence.Awaiting(_) = known.status
  })
  assert statuses(w, "report-7")
    == [
      #("report-7/l1", store.Awaiting),
      #("report-7/l2", store.Awaiting),
      #("report-7/l3", store.Awaiting),
    ]
  // Each waits in the finance queue as an ordinary card.
  assert list.sort(memory.queue(w.db, "finance"), string.compare) == ids
  world.invariants_hold(w, [
    testing.audit(line_desk(), effects: world.effects("lines_paid")),
  ])
}

pub fn each_line_is_judged_alone_and_the_payout_starts_once_test() {
  let w = world.new()
  let _ = admit_lines(w)
  let decide = fn(id, verdict) {
    let assert Ok(_) =
      world.in_tx(w, fn(tx) {
        use _ <- result.try(world.open_and_decide(
          line_desk(),
          tx,
          id,
          world.bia,
          verdict,
        ))
        follow(tx, "report-7")
      })
    Nil
  }
  decide("report-7/l1", Approve)
  let assert Ok(members) =
    world.in_tx(w, decisions.members(line_desk(), _, bundle: "report-7"))
  assert !decisions.is_complete(members)
  decide("report-7/l2", Reject(Reason("over_limit", None)))
  assert world.all(w.db, "payouts") == []
  decide("report-7/l3", Approve)
  // The rejected line was never paid; the other two were, one by one.
  assert world.all(w.db, "lines_paid") == ["l1: 30.00", "l3: 80.00"]
  assert world.all(w.db, "payouts") == ["pay report-7"]
  // A second follower that sees the bundle complete adds nothing.
  let assert Ok(Nil) = world.in_tx(w, follow(_, "report-7"))
  assert world.all(w.db, "payouts") == ["pay report-7"]
  assert statuses(w, "report-7")
    == [
      #("report-7/l1", store.Released),
      #("report-7/l2", store.Rejected),
      #("report-7/l3", store.Released),
    ]
  world.invariants_hold(w, [
    testing.audit(line_desk(), effects: world.effects("lines_paid")),
    testing.audit(payout_desk(), effects: world.effects("payouts")),
  ])
}

pub fn a_bundle_may_span_points_test() {
  let w = world.new()
  let bundle = Bundle(key: "report-8", size: 2)
  let assert Ok(_) =
    world.in_tx(w, fn(tx) {
      use _ <- result.try(decisions.recommend_once(
        line_desk(),
        tx,
        key: "report-8/l1",
        proposal: proposal("l1: 10.00") |> decisions.in_bundle(bundle),
      ))
      decisions.recommend_once(
        receipt_desk(),
        tx,
        key: "report-8/receipt",
        proposal: proposal("receipt") |> decisions.in_bundle(bundle),
      )
    })
  // The receipt settled at admission; the line still waits.
  let assert Ok(members) =
    world.in_tx(w, decisions.members(receipt_desk(), _, bundle: "report-8"))
  assert list.map(members, fn(m) { #(m.occurrence, m.point, m.status) })
    == [
      #("report-8/l1", "expense.line", store.Awaiting),
      #("report-8/receipt", "expense.receipt", store.Released),
    ]
  assert !decisions.is_complete(members)
}

pub fn a_trigger_delivered_again_admits_nothing_new_test() {
  let w = world.new()
  let first = admit_lines(w)
  let again = admit_lines(w)
  assert again == first
  assert list.length(statuses(w, "report-7")) == 3
}

pub fn a_bundle_admitted_in_pieces_is_not_complete_until_all_arrive_test() {
  let w = world.new()
  let bundle = Bundle(key: "report-9", size: 3)
  let admit = fn(key) {
    let assert Ok(_) =
      world.in_tx(w, decisions.recommend_once(
        receipt_desk(),
        _,
        key:,
        proposal: proposal(key) |> decisions.in_bundle(bundle),
      ))
    Nil
  }
  admit("report-9/a")
  admit("report-9/b")
  // Both members settled, but the bundle holds three.
  let assert Ok(members) =
    world.in_tx(w, decisions.members(receipt_desk(), _, bundle: "report-9"))
  assert list.length(members) == 2
  assert !decisions.is_complete(members)
  admit("report-9/c")
  let assert Ok(members) =
    world.in_tx(w, decisions.members(receipt_desk(), _, bundle: "report-9"))
  assert decisions.is_complete(members)
}

pub fn a_bundle_that_contradicts_itself_is_refused_test() {
  let w = world.new()
  let recommend = fn(key, bundle: Bundle) {
    world.in_tx(w, decisions.recommend_once(
      receipt_desk(),
      _,
      key:,
      proposal: proposal(key) |> decisions.in_bundle(bundle),
    ))
    |> result.map(fn(known) { known.id })
  }
  assert recommend("r10/a", Bundle(key: "r10", size: 0))
    == Error(decisions.BadBundle("r10", decisions.EmptyBundle))
  assert recommend("r10/a", Bundle(key: "", size: 1))
    == Error(decisions.BadBundle("", decisions.NoBundleKey))
  assert recommend("r10/a", Bundle(key: "r10", size: 2)) == Ok("r10/a")
  assert recommend("r10/b", Bundle(key: "r10", size: 3))
    == Error(decisions.BadBundle("r10", decisions.SizeDiffers(recorded: 2)))
  assert recommend("r10/b", Bundle(key: "r10", size: 2)) == Ok("r10/b")
  assert recommend("r10/c", Bundle(key: "r10", size: 2))
    == Error(decisions.BadBundle("r10", decisions.BundleFull))
  // A member delivered again is found, not refused as a third.
  assert recommend("r10/a", Bundle(key: "r10", size: 2)) == Ok("r10/a")
  assert decisions.disposition(decisions.BadBundle("r10", decisions.BundleFull))
    == decisions.Poisoned
}

pub fn an_unknown_bundle_has_no_members_test() {
  let w = world.new()
  let assert Ok(members) =
    world.in_tx(w, decisions.members(line_desk(), _, bundle: "nothing"))
  assert members == []
  assert !decisions.is_complete(members)
}

pub fn the_bundle_survives_a_restart_test() {
  let w = world.new()
  let _ = admit_lines(w)
  let w = world.restart(w)
  let known = world.read(w, line_desk(), "report-7/l2")
  assert known.bundle == Some(Bundle(key: "report-7", size: 3))
  assert list.length(statuses(w, "report-7")) == 3
}

pub fn an_occurrence_outside_a_bundle_has_none_test() {
  let w = world.new()
  let assert Ok(known) =
    world.in_tx(w, decisions.recommend(line_desk(), _, proposal("alone")))
  assert known.bundle == None
}

/// Two members that name different sizes break I9. Only an adapter whose
/// `members` misses a member lets the desk admit them.
pub fn the_invariant_checker_catches_a_bundle_that_disagrees_test() {
  let w = world.new()
  let blind = store.Port(..memory.port(), members: fn(_, _) { Ok([]) })
  let desk =
    decisions.desk(
      decisions.point("expense.receipt", wire.text()),
      drives: fn(_) { tool("receipts_filed") },
      under: fn(_) {
        Ok(Policy(version: 1, rules: [], otherwise: Proceed(Never, None)))
      },
      over: blind,
    )
  let admit = fn(key, size) {
    let assert Ok(_) =
      world.in_tx(w, decisions.recommend_once(
        desk,
        _,
        key:,
        proposal: proposal(key)
          |> decisions.in_bundle(Bundle(key: "r11", size:)),
      ))
    Nil
  }
  admit("r11/a", 2)
  admit("r11/b", 3)
  let assert Error(violations) =
    testing.check(w.db, memory.inspection(), [
      testing.audit(receipt_desk(), effects: world.effects("receipts_filed")),
    ])
  assert list.map(violations, fn(v) { v.invariant }) == ["I9"]
}

/// An item key given twice would count two items for one occurrence, and
/// the bundle could never complete: it is refused before anything is
/// written.
pub fn an_item_key_given_twice_is_refused_test() {
  let w = world.new()
  let admitted =
    world.in_tx(
      w,
      decisions.recommend_bundle(line_desk(), _, bundle: "r12", items: [
        #("r12/a", proposal("a")),
        #("r12/a", proposal("a again")),
      ]),
    )
  assert admitted
    == Error(decisions.BadBundle("r12", decisions.RepeatedItem("r12/a")))
  assert statuses(w, "r12") == []
}
