//// Use case 21: one recommendation, several actions. A model reads an
//// expense report and proposes one payment per line. Each line is an
//// ordinary occurrence, judged, released and measured on its own, and all
//// of them belong to one bundle, `report-7`, of a known size. Whoever
//// follows the line point starts the payout once, when every member of
//// the bundle has settled.

import decisions.{type Desk, Gated}
import decisions/memory.{type Tx}
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Never, Proceed}
import decisions/store
import decisions/testing
import decisions/vocabulary.{
  type Bundle, Approve, Manifest, Reason, Recommendation, Reject, RuleFired,
  Rules, Trigger,
}
import decisions/wire
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import support/policies
import support/world.{type World}

fn line_desk() -> Desk(String, Tx) {
  decisions.desk(
    decisions.point("expense.line", wire.text()),
    drives: fn(_) { tool("lines_paid") },
    under: fn(_) {
      Ok(policies.checked(
        version: 1,
        rules: [],
        otherwise: AnyoneHolding("finance"),
      ))
    },
    over: memory.port(),
  )
}

/// A second point in the same bundle: the receipt is filed without a
/// person.
fn receipt_desk() -> Desk(String, Tx) {
  decisions.desk(
    decisions.point("expense.receipt", wire.text()),
    drives: fn(_) { tool("receipts_filed") },
    under: fn(_) {
      Ok(policies.checked(
        version: 1,
        rules: [policy.When(policy.Always, Proceed(Never, None))],
        otherwise: policy.AnyoneHolding("nobody"),
      ))
    },
    over: memory.port(),
  )
}

fn payout_desk() -> Desk(String, Tx) {
  decisions.desk(
    decisions.point("expense.payout", wire.text()),
    drives: fn(_) { tool("payouts") },
    under: fn(_) {
      Ok(policies.checked(
        version: 1,
        rules: [policy.When(policy.Always, Proceed(Never, None))],
        otherwise: policy.AnyoneHolding("nobody"),
      ))
    },
    over: memory.port(),
  )
}

fn bundle(key: String, size: Int) -> Bundle {
  let assert Ok(made) = vocabulary.bundle(key:, size:)
  made
}

fn tool(table: String) -> decisions.Gated(String, Tx) {
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
        #("l1", proposal("l1: 30.00")),
        #("l2", proposal("l2: 1200.00")),
        #("l3", proposal("l3: 80.00")),
      ]),
    )
  list.map(lines, fn(line) { line.id })
}

/// What the line point's follower does with each settlement notice: when
/// the bundle is complete, recommend the payout under a key derived from
/// the bundle, so a second follower that sees it complete adds nothing.
fn follow(tx: Tx, bundle: String) -> Result(Nil, decisions.Refusal) {
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
    assert known.bundle == Some(bundle("report-7", 3))
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
  let report = bundle("report-8", 2)
  let assert Ok(_) =
    world.in_tx(w, fn(tx) {
      use _ <- result.try(decisions.recommend_member(
        line_desk(),
        tx,
        of: report,
        item: "l1",
        proposal: proposal("l1: 10.00"),
      ))
      decisions.recommend_member(
        receipt_desk(),
        tx,
        of: report,
        item: "receipt",
        proposal: proposal("receipt"),
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
  let report = bundle("report-9", 3)
  let admit = fn(item) {
    let assert Ok(_) =
      world.in_tx(w, decisions.recommend_member(
        receipt_desk(),
        _,
        of: report,
        item:,
        proposal: proposal(item),
      ))
    Nil
  }
  admit("a")
  admit("b")
  // Both members settled, but the bundle holds three.
  let assert Ok(members) =
    world.in_tx(w, decisions.members(receipt_desk(), _, bundle: "report-9"))
  assert list.length(members) == 2
  assert !decisions.is_complete(members)
  admit("c")
  let assert Ok(members) =
    world.in_tx(w, decisions.members(receipt_desk(), _, bundle: "report-9"))
  assert decisions.is_complete(members)
}

pub fn a_bundle_that_contradicts_itself_is_refused_test() {
  let w = world.new()
  let recommend = fn(item, size) {
    world.in_tx(w, decisions.recommend_member(
      receipt_desk(),
      _,
      of: bundle("r10", size),
      item:,
      proposal: proposal(item),
    ))
    |> result.map(fn(known) { known.id })
  }
  // A bundle without a key or with no room cannot be built.
  assert vocabulary.bundle(key: "r10", size: 0) == Error(vocabulary.EmptyBundle)
  assert vocabulary.bundle(key: "", size: 1) == Error(vocabulary.NoBundleKey)
  assert recommend("a", 2) == Ok("r10/a")
  assert recommend("b", 3)
    == Error(decisions.BadBundle("r10", decisions.SizeDiffers(recorded: 2)))
  assert recommend("b", 2) == Ok("r10/b")
  assert recommend("c", 2)
    == Error(decisions.BadBundle("r10", decisions.BundleFull))
  // A member delivered again is found, not refused as a third.
  assert recommend("a", 2) == Ok("r10/a")
  assert decisions.disposition(decisions.BadBundle("r10", decisions.BundleFull))
    == decisions.Poisoned
}

/// A member's key is scoped by its bundle, so a member delivered again is
/// found whichever verb asks for it.
pub fn a_member_key_is_scoped_by_its_bundle_test() {
  let w = world.new()
  let report = bundle("r15", 2)
  assert decisions.member_key(report, "a") == "r15/a"
  let admit = fn() {
    world.in_tx(w, decisions.recommend_member(
      receipt_desk(),
      _,
      of: report,
      item: "a",
      proposal: proposal("a"),
    ))
    |> result.map(fn(known) { known.id })
  }
  assert admit() == Ok("r15/a")
  assert admit() == Ok("r15/a")
  let assert Ok(members) =
    world.in_tx(w, decisions.members(receipt_desk(), _, bundle: "r15"))
  assert list.length(members) == 1
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
  assert known.bundle == Some(bundle("report-7", 3))
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
        Ok(policies.checked(
          version: 1,
          rules: [policy.When(policy.Always, Proceed(Never, None))],
          otherwise: policy.AnyoneHolding("nobody"),
        ))
      },
      over: blind,
    )
  let admit = fn(item, size) {
    let assert Ok(_) =
      world.in_tx(w, decisions.recommend_member(
        desk,
        _,
        of: bundle("r11", size),
        item:,
        proposal: proposal(item),
      ))
    Nil
  }
  admit("a", 2)
  admit("b", 3)
  let assert Error(violations) =
    memory.transaction(
      w.db,
      testing.check(_, memory.inspection(), [
        testing.audit(receipt_desk(), effects: world.effects("receipts_filed")),
      ]),
    )
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
        #("a", proposal("a")),
        #("a", proposal("a again")),
      ]),
    )
  assert admitted
    == Error(decisions.BadBundle("r12", decisions.RepeatedItem("a")))
  assert statuses(w, "r12") == []
}

/// A key that already holds an occurrence proposed alone cannot be counted
/// as a member: the bundle would never complete. A member delivered again
/// with its own bundle is still found.
pub fn a_key_outside_the_bundle_is_refused_test() {
  let w = world.new()
  let assert Ok(_) =
    world.in_tx(w, decisions.recommend_once(
      line_desk(),
      _,
      key: "r13/a",
      proposal: proposal("alone"),
    ))
  let admitted =
    world.in_tx(
      w,
      decisions.recommend_bundle(line_desk(), _, bundle: "r13", items: [
        #("a", proposal("a")),
        #("b", proposal("b")),
      ]),
    )
  assert admitted
    == Error(decisions.BadBundle("r13", decisions.KeyOutsideBundle("r13/a")))
  // Nothing of the bundle was written.
  assert statuses(w, "r13") == []
  // A member of another size is outside too.
  let _ = admit_lines(w)
  let again =
    world.in_tx(w, decisions.recommend_member(
      line_desk(),
      _,
      of: bundle("report-7", 4),
      item: "l1",
      proposal: proposal("l1"),
    ))
  assert again
    == Error(decisions.BadBundle(
      "report-7",
      decisions.KeyOutsideBundle("report-7/l1"),
    ))
}

/// A key whose own deadline passed before anything was recommended has
/// already sent its one settlement notice; it cannot join a bundle.
pub fn a_key_that_ended_before_it_was_recommended_is_refused_test() {
  let w = world.new()
  let deadline = timestamp.add(world.t0(), duration.minutes(1))
  let assert Ok(Nil) =
    world.in_tx(w, decisions.expect_until(
      receipt_desk(),
      _,
      key: "r14/a",
      trigger: Trigger(kind: "report", id: "r14"),
      about: world.ana,
      valid_until: deadline,
    ))
  world.at(w, duration.minutes(2))
  assert world.deliver_due(w, [decisions.waker(receipt_desk())]) == 1
  let late =
    world.in_tx(w, decisions.recommend_member(
      receipt_desk(),
      _,
      of: bundle("r14", 1),
      item: "a",
      proposal: proposal("late"),
    ))
  assert late
    == Error(decisions.BadBundle("r14", decisions.EndedBefore("r14/a")))
  // Without a bundle the late recommendation is recorded expired, as before.
  let assert Ok(known) =
    world.in_tx(w, decisions.recommend_once(
      receipt_desk(),
      _,
      key: "r14/a",
      proposal: proposal("late"),
    ))
  let assert occurrence.Expired(_) = known.status
}

/// A head the inspection cannot read is reported, not left out of I9.
pub fn i9_reports_a_head_it_cannot_read_test() {
  let w = world.new()
  let _ = admit_lines(w)
  let inspection = memory.inspection()
  let failing =
    store.Inspection(..inspection, head: fn(tx, id) {
      case id {
        "report-7/l2" -> Error(store.Unavailable("lost"))
        _ -> inspection.head(tx, id)
      }
    })
  let assert Error(violations) =
    memory.transaction(
      w.db,
      testing.check(_, failing, [
        testing.audit(line_desk(), effects: world.effects("lines_paid")),
      ]),
    )
  assert list.any(violations, fn(v) {
    v.invariant == "I9" && v.occurrence == "report-7/l2"
  })
}
