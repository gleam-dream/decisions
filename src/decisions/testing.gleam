//// An invariant checker that applications and adapters run against any
//// store after a scenario: a race, a random walk, a restart.
////
//// It reads every occurrence of the audited points through the adapter's
//// `store.Inspection` and the points' desks, and checks:
////
//// | Invariant | Meaning |
//// | --- | --- |
//// | I1 | At most one release per occurrence; the gated tool's effects equal the released occurrences, when the audit counts effects |
//// | I2 | A release follows an acceptance: the policy proceeded, or the required verdicts approved or corrected |
//// | I3 | Nothing changes an outcome after it settles. After settlement only these entries are appended: `assessed`, `effected` and `verdict_refused` on any occurrence, and `reviewed`, `opened`, `noted` and `expanded` on a sampled one. A recorded refusal names a showing to its validator made before the occurrence settled. One exception: a `recommended` entry may follow the `expired` entry of a record not begun whose own deadline passed, and the occurrence stays expired |
//// | I4 | One deciding verdict per validator per output that stands |
//// | I5 | Every wake-up the occurrence needs as it stands (`occurrence.wake_times`: the end of a hold, the deadline, each later policy answer; for a record not begun, `occurrence.pending_wake_times`: its own deadline) is pending; a settled occurrence has none |
//// | I6 | A settled occurrence has exactly one settlement notice, an unsettled one none |
//// | I7 | Entries are numbered 1, 2, 3 and so on, and their times never decrease, so the record as known earlier is a prefix of the record now |
//// | I8 | The head equals the head the record implies (`occurrence.head`), field by field |
//// | I9 | The members of a bundle among the audited points agree on its size, and are no more than it |
////
//// I4 differs from STRESS.md's "one deciding verdict per validator per
//// occurrence" on purpose. A correction replaces the output that stands,
//// and four eyes then needs fresh approvals of the new output, possibly
//// from someone who approved the old one; so the rule is one verdict per
//// validator for each output that stands, and a correction starts a new
//// round that its author belongs to.
////
//// A record that has not begun (expected, or holding only failed attempts)
//// needs a wake-up at its own deadline when it has one
//// (`occurrence.pending_wake_times`) and no notice; once a newer event
//// superseded it or its deadline passed, it is settled: no wake-up,
//// exactly one notice, head status `Expired`. A recommendation may still
//// follow an expiry by deadline: the occurrence then starts expired, and
//// the notice the expiry admitted is its one notice.
////
//// ```gleam
//// import decisions/testing
////
//// let audits = [testing.audit(refund_desk, effects: count_refunds)]
//// let assert Ok(summary) =
////   testing.check(store, memory.inspection(), audits)
//// ```
////
//// Target-independent: builds for Erlang and JavaScript.

import decisions.{type Desk}
import decisions/entry.{type Entry}
import decisions/occurrence.{type Occurrence}
import decisions/store.{type Head, type Inspection, type Notice, type Wake}
import decisions/vocabulary.{Correct}
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import gleam/time/timestamp.{type Timestamp}

/// One point to audit, with its output type erased.
pub opaque type Audit(tx) {
  Audit(
    point: String,
    read: fn(tx, String) -> Result(Option(Seen), String),
    effects: fn(tx) -> Result(Option(Int), String),
  )
}

/// What one occurrence looked like to its audit.
type Seen {
  Seen(
    id: String,
    status: String,
    settled: Bool,
    released: Bool,
    head: Head,
    must_wake: List(Timestamp),
    violations: List(Violation),
  )
}

/// A broken invariant.
pub type Violation {
  Violation(invariant: String, occurrence: String, detail: String)
}

/// What the checker saw when every invariant held.
pub type Summary {
  Summary(occurrences: Int, settled: Int, released: Int)
}

/// Audit the occurrences of a desk's point. `effects` counts what the
/// gated tool did, for I1.
pub fn audit(
  desk: Desk(o, tx),
  effects effects: fn(tx) -> Result(Int, String),
) -> Audit(tx) {
  build(desk, fn(tx) { effects(tx) |> result.map(Some) })
}

/// Audit the occurrences of a desk's point without counting effects.
pub fn audit_record(desk: Desk(o, tx)) -> Audit(tx) {
  build(desk, fn(_) { Ok(None) })
}

fn build(
  desk: Desk(o, tx),
  effects: fn(tx) -> Result(Option(Int), String),
) -> Audit(tx) {
  let point = decisions.name(decisions.point_of(desk))
  Audit(point:, effects:, read: fn(tx, id) {
    case decisions.read_record(desk, tx, key: id) {
      Ok(decisions.Begun(known)) -> Ok(Some(see(known)))
      Ok(decisions.NotBegun(pending)) -> Ok(Some(see_pending(pending)))
      Error(refusal) -> Error(decisions.describe(refusal))
    }
  })
}

/// Check every invariant over the audited points, in `tx`.
pub fn check(
  tx: tx,
  inspect: Inspection(tx),
  audits: List(Audit(tx)),
) -> Result(Summary, List(Violation)) {
  let all = list.flat_map(audits, fn(audit) { check_point(tx, inspect, audit) })
  let seen = list.filter_map(all, fn(pair) { pair.0 })
  let violations =
    list.flat_map(all, fn(pair) { pair.1 })
    |> list.append(list.flat_map(seen, fn(seen) { seen.violations }))
    |> list.append(bundles(tx, inspect, audits))
  case violations {
    [] ->
      Ok(Summary(
        occurrences: list.length(seen),
        settled: list.count(seen, fn(seen) { seen.settled }),
        released: list.count(seen, fn(seen) { seen.released }),
      ))
    _ -> Error(violations)
  }
}

/// I9: group the audited records by the bundle their heads name.
fn bundles(
  tx: tx,
  inspect: Inspection(tx),
  audits: List(Audit(tx)),
) -> List(Violation) {
  let read =
    list.flat_map(audits, fn(audit) {
      case inspect.occurrences(tx, audit.point) {
        Ok(ids) ->
          list.map(ids, fn(id) {
            case inspect.head(tx, id) {
              Ok(Some(store.Head(bundle: Some(bundle), ..))) ->
                Ok(#(bundle.key, #(id, bundle.size)))
              Ok(_) -> Error(None)
              Error(error) ->
                Error(
                  Some(Violation(
                    invariant: "I9",
                    occurrence: id,
                    detail: "its head could not be read: "
                      <> store.describe(error),
                  )),
                )
            }
          })
        Error(error) -> [
          Error(
            Some(Violation(
              invariant: "I9",
              occurrence: audit.point,
              detail: "its records could not be listed: "
                <> store.describe(error),
            )),
          ),
        ]
      }
    })
  let unread =
    list.filter_map(read, fn(one) {
      case one {
        Error(Some(violation)) -> Ok(violation)
        _ -> Error(Nil)
      }
    })
  let members =
    list.filter_map(read, fn(one) { result.map_error(one, fn(_) { Nil }) })
  use <- bool.guard(unread != [], unread)
  members
  |> list.group(fn(pair) { pair.0 })
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.flat_map(fn(group) {
    let #(key, pairs) = group
    let found =
      list.map(pairs, fn(pair) { pair.1 })
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    let sizes = list.unique(list.map(found, fn(member) { member.1 }))
    let violation = fn(detail) {
      let assert [#(first, _), ..] = found
      [Violation(invariant: "I9", occurrence: first, detail:)]
    }
    case sizes {
      [size] ->
        case list.length(found) > size {
          True ->
            violation(
              "bundle "
              <> key
              <> " holds "
              <> int.to_string(list.length(found))
              <> " members but its size is "
              <> int.to_string(size),
            )
          False -> []
        }
      _ ->
        violation(
          "the members of bundle "
          <> key
          <> " record different sizes: "
          <> string.inspect(found),
        )
    }
  })
}

fn check_point(
  tx: tx,
  inspect: Inspection(tx),
  audit: Audit(tx),
) -> List(#(Result(Seen, Nil), List(Violation))) {
  let broken = fn(invariant, id, detail) {
    #(Error(Nil), [Violation(invariant:, occurrence: id, detail:)])
  }
  case
    inspect.occurrences(tx, audit.point),
    inspect.wakes(tx),
    inspect.notices(tx)
  {
    Ok(ids), Ok(wakes), Ok(notices) -> {
      let each =
        list.map(ids, fn(id) {
          case audit.read(tx, id), inspect.head(tx, id) {
            Ok(None), _ -> #(Error(Nil), [])
            Ok(Some(seen)), Ok(head) -> #(
              Ok(seen),
              stored(audit.point, seen, head, wakes, notices),
            )
            Error(reason), _ -> broken("readable", id, reason)
            _, Error(error) -> broken("readable", id, store.describe(error))
          }
        })
      let released =
        list.count(each, fn(pair) {
          case pair.0 {
            Ok(seen) -> seen.released
            Error(Nil) -> False
          }
        })
      let effects = case audit.effects(tx) {
        Ok(Some(count)) if count != released -> [
          Violation(
            invariant: "I1",
            occurrence: audit.point,
            detail: int.to_string(count)
              <> " effects for "
              <> int.to_string(released)
              <> " released occurrences",
          ),
        ]
        Ok(_) -> []
        Error(reason) -> [
          Violation(invariant: "I1", occurrence: audit.point, detail: reason),
        ]
      }
      [#(Error(Nil), effects), ..each]
    }
    _, _, _ -> [
      broken("readable", audit.point, "the store could not be inspected"),
    ]
  }
}

/// I5, I6 and I8: what the store holds beside the record.
fn stored(
  point: String,
  seen: Seen,
  head: Option(Head),
  wakes: List(Wake),
  notices: List(Notice),
) -> List(Violation) {
  let violation = fn(invariant, detail) {
    Violation(invariant:, occurrence: seen.id, detail:)
  }
  let pending =
    list.filter_map(wakes, fn(wake) {
      case wake.point == point && wake.occurrence == seen.id {
        True -> Ok(wake.at)
        False -> Error(Nil)
      }
    })
  let i5 = case seen.settled, pending {
    True, [_, ..] -> [violation("I5", "a settled occurrence has wake-ups")]
    True, [] -> []
    False, _ ->
      list.filter_map(seen.must_wake, fn(at) {
        case list.contains(pending, at) {
          True -> Error(Nil)
          False -> Ok(violation("I5", "a wake-up is missing"))
        }
      })
  }
  let notified =
    list.count(notices, fn(notice) {
      notice.point == point && notice.occurrence == seen.id
    })
  let i6 = case seen.settled, notified {
    True, 1 | False, 0 -> []
    _, _ -> [
      violation(
        "I6",
        int.to_string(notified)
          <> " settlement notices for status "
          <> seen.status,
      ),
    ]
  }
  let i8 = case head {
    None -> [violation("I8", "no head")]
    Some(head) if head == seen.head -> []
    Some(head) -> [
      violation(
        "I8",
        "the head is "
          <> string.inspect(head)
          <> " where the record implies "
          <> string.inspect(seen.head),
      ),
    ]
  }
  list.flatten([i5, i6, i8])
}

/// A record that has not begun: it needs a wake-up at its own deadline
/// while it waits; once it ended it is settled and has exactly one
/// settlement notice; its head is `occurrence.pending_head`.
fn see_pending(pending: occurrence.Pending) -> Seen {
  let head = occurrence.pending_head(pending)
  Seen(
    id: pending.id,
    status: store.status_name(head.status),
    settled: pending.ended != None,
    released: False,
    head:,
    must_wake: occurrence.pending_wake_times(pending),
    violations: [],
  )
}

/// I1, I2, I3, I4 and I7, from the record alone.
fn see(known: Occurrence(o)) -> Seen {
  let violation = fn(invariant, detail) {
    Violation(invariant:, occurrence: known.id, detail:)
  }
  let entries = known.entries
  let kinds = list.map(entries, fn(e) { entry.kind(e.event) })
  let releases = list.count(kinds, fn(kind) { kind == "released" })
  let i1 = case releases > 1 {
    True -> [violation("I1", int.to_string(releases) <> " releases")]
    False -> []
  }
  // The status after each prefix of the record.
  let statuses =
    prefixes(entries)
    |> list.filter_map(fn(prefix) {
      occurrence.fold(known.id, prefix)
      |> result.map(fn(folded) { #(prefix, folded.status) })
      |> result.replace_error(Nil)
    })
  let i2 =
    list.window_by_2(statuses)
    |> list.filter_map(fn(pair) {
      let #(#(_, before), #(prefix, _)) = pair
      case list.last(prefix) {
        Ok(entry.Entry(event: entry.Released(..), ..)) ->
          case before {
            occurrence.Accepted(..) | occurrence.Held(..) -> Error(Nil)
            _ -> Ok(violation("I2", "released without an acceptance"))
          }
        _ -> Error(Nil)
      }
    })
  let i3 = after_settlement(known, statuses, violation)
  let i4 = one_verdict_each(entries, violation)
  let i7 =
    list.index_map(entries, fn(e, index) { #(e, index + 1) })
    |> list.filter_map(fn(pair) {
      case { pair.0 }.seq == pair.1 {
        True -> Error(Nil)
        False -> Ok(violation("I7", "entries are not numbered in order"))
      }
    })
    |> list.append(
      list.window_by_2(entries)
      |> list.filter_map(fn(pair) {
        case timestamp.compare({ pair.0 }.at, { pair.1 }.at) {
          order.Gt ->
            Ok(violation("I7", "an entry is earlier than the one before"))
          _ -> Error(Nil)
        }
      }),
    )
  let must_wake = occurrence.wake_times(known)
  Seen(
    id: known.id,
    status: occurrence.status_name(known.status),
    settled: occurrence.is_settled(known.status),
    released: releases == 1,
    head: occurrence.head(known),
    must_wake:,
    violations: list.flatten([i1, i2, i3, i4, i7]),
  )
}

fn after_settlement(
  known: Occurrence(o),
  statuses: List(#(List(Entry(o)), occurrence.Status(o))),
  violation: fn(String, String) -> Violation,
) -> List(Violation) {
  let after =
    list.drop_while(statuses, fn(pair) { !occurrence.is_settled(pair.1) })
  let settled_at = case after {
    [#(prefix, _), ..] -> list.length(prefix)
    [] -> list.length(known.entries) + 1
  }
  // A recorded refusal names a showing to its validator, made before the
  // occurrence settled.
  let refusals =
    list.filter_map(known.entries, fn(e) {
      case e.event {
        entry.VerdictRefused(by:, seen:, ..) -> {
          let shown =
            list.any(known.entries, fn(other) {
              other.seq == seen
              && case other.event {
                entry.Opened(by: viewer, ..) -> viewer == by
                _ -> False
              }
            })
          case shown && seen < settled_at {
            True -> Error(Nil)
            False ->
              Ok(violation(
                "I3",
                "a refusal by " <> by <> " names no showing before settlement",
              ))
          }
        }
        _ -> Error(Nil)
      }
    })
  case after {
    [] -> refusals
    [#(prefix, settled), ..rest] -> {
      let changed = list.any(rest, fn(pair) { pair.1 != settled })
      let allowed = case known.sampled {
        True -> [
          "reviewed", "assessed", "effected", "verdict_refused", "opened",
          "expanded", "noted",
        ]
        False -> ["assessed", "effected", "verdict_refused"]
      }
      let added =
        list.drop(known.entries, list.length(prefix))
        |> list.filter(fn(e) { !list.contains(allowed, entry.kind(e.event)) })
      list.flatten([
        refusals,
        case changed {
          True -> [violation("I3", "the outcome changed after it settled")]
          False -> []
        },
        list.map(added, fn(e) {
          violation("I3", entry.kind(e.event) <> " appended after settlement")
        }),
      ])
    }
  }
}

fn one_verdict_each(
  entries: List(Entry(o)),
  violation: fn(String, String) -> Violation,
) -> List(Violation) {
  // A correction replaces the output that stands and starts a new round
  // of approvals, which its author belongs to.
  let #(_, _, found) =
    list.fold(entries, #(0, set.new(), []), fn(state, e) {
      let #(round, deciders, found) = state
      case e.event {
        entry.Decided(by:, verdict: Correct(..), ..) -> #(
          round + 1,
          set.from_list([by]),
          found,
        )
        entry.Decided(by:, ..) ->
          case set.contains(deciders, by) {
            True -> #(round, deciders, [
              violation("I4", by <> " decided twice on one output"),
              ..found
            ])
            False -> #(round, set.insert(deciders, by), found)
          }
        _ -> state
      }
    })
  found
}

fn prefixes(entries: List(a)) -> List(List(a)) {
  list.index_map(entries, fn(_, index) { list.take(entries, index + 1) })
}
