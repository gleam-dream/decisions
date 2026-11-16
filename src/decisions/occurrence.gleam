//// Where an occurrence stands is a fold of its entries. This module is the
//// whole lifecycle as one pure function, `apply`, and the read side of the
//// record.
////
//// An occurrence moves through nine statuses:
////
//// ```text
//// Recommended ──policy──▶ Awaiting ──verdicts──▶ Accepted ──▶ Held ──▶ Released
////      │  ╲                  │  ╲                   │           │ ╲
////      │   consulting        │   Rejected           │           │  Withdrawn
////      ▼                     ▼                      ▼           ▼
////   Expired               Expired                Refused     Refused
//// ```
////
//// `Accepted` lasts only inside a verb: an accepted output is held or
//// released in the same transaction. `Released`, `Rejected`, `Expired`,
//// `Withdrawn` and `Refused` are settled: nothing changes the outcome
//// after that. Only assessments, effect reports and recorded refusals are
//// appended to a settled occurrence, and, on a sampled one, its review and
//// the showings, notes and expansions that lead to it. This is invariant
//// I3 of `decisions/testing`, which lists the same entries.
////
//// ```gleam
//// import decisions/occurrence
////
//// case occurrence.final(known) {
////   Some(output) -> show(output)
////   None -> show_waiting(known.status)
//// }
//// ```
////
//// `Status` may gain variants in a minor release; match it with a `_`
//// branch where a new status needs no decision of yours.
////
//// Target-independent: builds for Erlang and JavaScript.

import decisions/entry.{type Entry, type Event}
import decisions/model.{type Failure}
import decisions/policy.{type Eligible, type Outcome, type Step}
import decisions/store
import decisions/vocabulary.{
  type Assessment, type Effect, type ExpiryCause, type Facts, type Manifest,
  type Parent, type Reason, type Recommendation, type Ref, type Subject,
  type Trigger, type Verdict, Approve, Correct, Reject,
}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}

/// Who accepted the final output: a policy version, or the validator whose
/// verdict completed the acceptance.
pub type Decider {
  ByPolicy(version: Int)
  ByValidator(subject: String)
}

/// Where an occurrence stands. Each status carries what is meaningful in
/// it.
pub type Status(output) {
  /// Recommended and not yet settled by the policy. `consulting` names the
  /// decision point it waits for, when the policy consulted one.
  Recommended(consulting: Option(String))
  /// Waiting for verdicts from whoever `eligible` admits.
  Awaiting(eligible: Eligible)
  /// Accepted and not yet held or released. A verb never ends here.
  Accepted(final: output, by: Decider)
  /// Accepted, and waiting until `until` before release.
  Held(final: output, until: Timestamp, by: Decider)
  /// The final output reached the gated tool under `key`.
  Released(final: output, key: String, by: Decider)
  /// A validator rejected it, for `reason`. Nothing is released.
  Rejected(reason: Reason)
  /// It can no longer be decided or released: its validity passed while it
  /// waited, or an event superseded it, while it waited or was held.
  Expired(cause: ExpiryCause)
  /// The decider, or a holder of the point's `withdrawn_by` set, took the
  /// held output back.
  Withdrawn(by: String)
  /// The guard or the gated tool refused a release nobody waited on.
  Refused(reason: String)
}

/// A recommender's failed attempt under the occurrence's key, before its
/// recommendation.
pub type Attempt {
  Attempt(
    at: Timestamp,
    trigger: Trigger,
    failure: Failure,
    evidence: List(Ref),
  )
}

/// An occurrence: the record and everything folded from it.
pub type Occurrence(output) {
  Occurrence(
    id: String,
    /// The decision point it is an occurrence of.
    point: String,
    /// Every entry, failed attempts included, in sequence order.
    entries: List(Entry(output)),
    /// Failed attempts made before the recommendation.
    attempts: List(Attempt),
    trigger: Trigger,
    parent: Option(Parent),
    subject: Subject,
    requester: Option(String),
    context: Manifest,
    recommendation: Recommendation(output),
    valid_until: Option(Timestamp),
    /// Facts consulted decision points returned.
    informed: Facts,
    /// The policy version the occurrence was given, once the policy
    /// answered.
    policy_version: Option(Int),
    /// What the applied policy will say as the occurrence goes on waiting.
    later: List(Step),
    /// Sampled for a review after release.
    sampled: Bool,
    status: Status(output),
  )
}

/// A record that has not begun: no recommendation yet. A trigger was
/// received (`expected`), or a recommender failed under the key
/// (`attempts`), or both; `superseded` names the event that superseded it
/// before it began, after which it never will.
pub type Pending {
  Pending(
    id: String,
    point: String,
    subject: Subject,
    /// When the record was first written.
    since: Timestamp,
    /// `decisions.expect` recorded that a recommendation is expected.
    expected: Bool,
    attempts: List(Attempt),
    superseded: Option(ExpiryCause),
  )
}

/// Why entries do not fold into an occurrence.
pub type NotBegun {
  /// There are no entries.
  NoEntries
  /// The record has not begun: it is expected, holds failed attempts, or
  /// was superseded before it began.
  NotYet(pending: Pending)
  /// The entries before the recommendation are not an expectation, a
  /// failed attempt or a supersession, or no recommendation follows the
  /// supersession. A store holding this was written by something other
  /// than the desk.
  NoRecommendation
}

/// Fold a record. An expectation, failed attempts and a supersession may
/// come first; the recommendation, when there is one, follows them.
pub fn fold(
  id: String,
  entries: List(Entry(o)),
) -> Result(Occurrence(o), NotBegun) {
  let #(prefix, rest) =
    list.split_while(entries, fn(entry) {
      case entry.event {
        entry.AttemptFailed(..) | entry.Expected(..) | entry.Expired(..) -> True
        _ -> False
      }
    })
  let attempts = list.filter_map(prefix, attempt)
  case rest, prefix {
    [], [] -> Error(NoEntries)
    [], [first, ..] ->
      case pending(id, first, prefix, attempts) {
        Ok(found) -> Error(NotYet(found))
        Error(Nil) -> Error(NoRecommendation)
      }
    [
      entry.Entry(
        event: entry.Recommended(
          point:,
          trigger:,
          parent:,
          subject:,
          requester:,
          context:,
          recommendation:,
          valid_until:,
        ),
        ..,
      ) as first,
      ..later
    ],
      _
    ->
      case list.any(prefix, is_expiry) {
        // Nothing is recommended after a supersession.
        True -> Error(NoRecommendation)
        False ->
          Ok(list.fold(
            later,
            Occurrence(
              id:,
              point:,
              entries: list.append(prefix, [first]),
              attempts:,
              trigger:,
              parent:,
              subject:,
              requester:,
              context:,
              recommendation:,
              valid_until:,
              informed: [],
              policy_version: None,
              later: [],
              sampled: False,
              status: Recommended(consulting: None),
            ),
            apply,
          ))
      }
    _, _ -> Error(NoRecommendation)
  }
}

fn is_expiry(entry: Entry(o)) -> Bool {
  case entry.event {
    entry.Expired(..) -> True
    _ -> False
  }
}

fn pending(
  id: String,
  first: Entry(o),
  prefix: List(Entry(o)),
  attempts: List(Attempt),
) -> Result(Pending, Nil) {
  let names = case first.event {
    entry.AttemptFailed(point:, subject:, ..)
    | entry.Expected(point:, subject:, ..) -> Ok(#(point, subject))
    _ -> Error(Nil)
  }
  use #(point, subject) <- result.map(names)
  Pending(
    id:,
    point:,
    subject:,
    since: first.at,
    expected: list.any(prefix, fn(entry) {
      case entry.event {
        entry.Expected(..) -> True
        _ -> False
      }
    }),
    attempts:,
    superseded: list.find_map(prefix, fn(entry) {
      case entry.event {
        entry.Expired(cause:) -> Ok(cause)
        _ -> Error(Nil)
      }
    })
      |> option.from_result,
  )
}

/// The head a store keeps beside a record that has not begun: `Pending`
/// while it may still be recommended, `Expired` once a newer event
/// superseded it.
pub fn pending_head(pending: Pending) -> store.Head {
  store.Head(
    point: pending.point,
    subject: pending.subject,
    status: case pending.superseded {
      Some(_) -> store.Expired
      None -> store.Pending
    },
    awaiting: [],
    due: None,
    arrived: pending.since,
    approved: [],
    may_not_decide: [],
    review_pending: False,
  )
}

/// Whether the recommendation was expected first (`decisions.expect`).
pub fn was_expected(occurrence: Occurrence(o)) -> Bool {
  list.any(occurrence.entries, fn(entry) {
    case entry.event {
      entry.Expected(..) -> True
      _ -> False
    }
  })
}

fn attempt(entry: Entry(o)) -> Result(Attempt, Nil) {
  case entry.event {
    entry.AttemptFailed(trigger:, failure:, evidence:, ..) ->
      Ok(Attempt(at: entry.at, trigger:, failure:, evidence:))
    _ -> Error(Nil)
  }
}

/// One more entry. An entry that is not legal from the current status
/// leaves the status as it is; the desk never writes one.
pub fn apply(occurrence: Occurrence(o), entry: Entry(o)) -> Occurrence(o) {
  let occurrence =
    Occurrence(..occurrence, entries: list.append(occurrence.entries, [entry]))
  case entry.event, occurrence.status {
    entry.Informed(facts:, ..), _ ->
      Occurrence(
        ..occurrence,
        informed: list.append(occurrence.informed, facts),
      )
    // The policy answers a fresh recommendation, and answers again when
    // waiting changes what it says.
    entry.PolicyApplied(version:, outcome:, sampled:, later:), Recommended(_)
    | entry.PolicyApplied(version:, outcome:, sampled:, later:), Awaiting(_)
    ->
      Occurrence(
        ..occurrence,
        policy_version: Some(version),
        later:,
        sampled: sampled || occurrence.sampled,
        status: case outcome {
          policy.Proceed(..) ->
            Accepted(standing(occurrence).0, ByPolicy(version))
          // A later answer that asks may already be met by the approvals
          // given under the earlier one.
          policy.Ask(eligible:) ->
            case
              is_met(occurrence, eligible),
              list.last(approvals(occurrence))
            {
              True, Ok(#(last, _)) ->
                Accepted(standing(occurrence).0, ByValidator(last))
              _, _ -> Awaiting(eligible:)
            }
          policy.Consult(point:) -> Recommended(consulting: Some(point))
        },
      )
    entry.Decided(by:, verdict:, ..), Awaiting(eligible:) ->
      Occurrence(..occurrence, status: case verdict {
        Reject(reason:) -> Rejected(reason:)
        Approve | Correct(..) ->
          case is_met(occurrence, eligible) {
            True -> Accepted(standing(occurrence).0, ByValidator(by))
            False -> Awaiting(eligible:)
          }
      })
    entry.Held(until:), Accepted(final:, by:) ->
      Occurrence(..occurrence, status: Held(final:, until:, by:))
    entry.Withdrawn(by:), Held(..) ->
      Occurrence(..occurrence, status: Withdrawn(by:))
    entry.Released(key:, ..), Accepted(final:, by:)
    | entry.Released(key:, ..), Held(final:, by:, ..)
    -> Occurrence(..occurrence, status: Released(final:, key:, by:))
    entry.Refused(reason:), Accepted(..) | entry.Refused(reason:), Held(..) ->
      Occurrence(..occurrence, status: Refused(reason:))
    entry.Expired(cause:), Recommended(_)
    | entry.Expired(cause:), Awaiting(_)
    | entry.Expired(cause:), Held(..)
    -> Occurrence(..occurrence, status: Expired(cause:))
    _, _ -> occurrence
  }
}

/// The occurrence as it was known at `at`: only the entries appended at or
/// before it. `Error` when it had not been recommended yet.
pub fn as_of(
  occurrence: Occurrence(o),
  at: Timestamp,
) -> Result(Occurrence(o), NotBegun) {
  occurrence.entries
  |> list.filter(fn(entry) { timestamp.compare(entry.at, at) != order.Gt })
  |> fold(occurrence.id, _)
}

/// The stable name of a status, as a head keeps it.
pub fn status_name(status: Status(o)) -> String {
  store.status_name(head_status(status))
}

/// The head a store keeps beside this occurrence: what the desk writes
/// with every append, and what `decisions/testing` compares a store's head
/// with.
pub fn head(occurrence: Occurrence(o)) -> store.Head {
  let #(awaiting, approved) = case occurrence.status {
    Awaiting(eligible:) -> #(policy.sets(eligible), standing(occurrence).1)
    _ -> #([], [])
  }
  store.Head(
    point: occurrence.point,
    subject: occurrence.subject,
    status: head_status(occurrence.status),
    awaiting:,
    due: due(occurrence),
    arrived: recommended_at(occurrence),
    approved:,
    may_not_decide: case occurrence.status {
      Awaiting(eligible:) -> barred(occurrence, eligible)
      _ -> []
    },
    review_pending: case occurrence.sampled, occurrence.status {
      True, Released(..) -> reviews(occurrence) == []
      _, _ -> False
    },
  )
}

/// Who may not decide whatever sets they hold: whoever already approved
/// the output that stands (nobody gives it a second verdict), and who
/// every alternative of `eligible` bars by identity (`SomeoneElseHolding`
/// bars the requester and a `Person` recommender; `Either` bars only who
/// all its alternatives bar). Someone barred under the one alternative
/// they qualify for is not listed: `admits`, which `open` and `decide`
/// apply, refuses them.
fn barred(occurrence: Occurrence(o), eligible: Eligible) -> List(String) {
  // Nobody gives a second verdict on the output that stands.
  list.append(by_identity(occurrence, eligible), standing(occurrence).1)
  |> list.unique
}

fn by_identity(occurrence: Occurrence(o), eligible: Eligible) -> List(String) {
  case eligible {
    policy.AnyoneHolding(_) -> []
    policy.SomeoneElseHolding(_) ->
      list.append(
        option.values([occurrence.requester]),
        case occurrence.recommendation.by {
          vocabulary.Person(subject:) -> [subject]
          _ -> []
        },
      )
      |> list.unique
    policy.Either(of) ->
      case list.map(of, by_identity(occurrence, _)) {
        [] -> []
        [first, ..rest] ->
          list.filter(first, fn(name) {
            list.all(rest, fn(other) { list.contains(other, name) })
          })
      }
    policy.Several(of:, ..) -> by_identity(occurrence, of)
  }
}

/// Whether one validator, holding `holds`, is admitted by `eligible`,
/// whatever approvals it still needs: `AnyoneHolding` admits a holder of
/// the set; `SomeoneElseHolding` a holder who neither asked nor recommended
/// it as their own act; `Either` whoever any alternative admits; `Several`
/// whoever its inner eligibility admits.
pub fn admits(
  occurrence: Occurrence(o),
  eligible: Eligible,
  subject: String,
  holds: List(String),
) -> Bool {
  case eligible {
    policy.AnyoneHolding(set:) -> list.contains(holds, set)
    policy.SomeoneElseHolding(set:) ->
      list.contains(holds, set)
      && Some(subject) != occurrence.requester
      && occurrence.recommendation.by != vocabulary.Person(subject)
    policy.Either(of) -> list.any(of, admits(occurrence, _, subject, holds))
    policy.Several(of:, ..) -> admits(occurrence, of, subject, holds)
  }
}

/// Whether the approvals of the output that stands satisfy `eligible`.
/// One approval admitted by it satisfies `AnyoneHolding` and
/// `SomeoneElseHolding`; `Several(count, of)` needs `count` different
/// approvers each admitted by `of`; `Either` is satisfied when any one of
/// its alternatives is, each judged on the same approvals. So
/// `Either([Several(2, AnyoneHolding("finance")), AnyoneHolding("head")])`
/// accepts on two finance approvals or on one by the head, never on one
/// finance approval.
pub fn is_met(occurrence: Occurrence(o), eligible: Eligible) -> Bool {
  let approvals = approvals(occurrence)
  met(occurrence, eligible, approvals)
}

fn met(
  occurrence: Occurrence(o),
  eligible: Eligible,
  approvals: List(#(String, List(String))),
) -> Bool {
  case eligible {
    policy.AnyoneHolding(_) | policy.SomeoneElseHolding(_) ->
      list.any(approvals, fn(given) {
        admits(occurrence, eligible, given.0, given.1)
      })
    policy.Either(of) -> list.any(of, met(occurrence, _, approvals))
    policy.Several(count:, of:) ->
      list.count(approvals, fn(given) {
        admits(occurrence, of, given.0, given.1)
      })
      >= count
  }
}

/// Who has approved the output that stands, with the decision sets each
/// held when they did, in order. A correction counts as its author's
/// approval of the corrected output.
pub fn approvals(occurrence: Occurrence(o)) -> List(#(String, List(String))) {
  list.fold(occurrence.entries, [], fn(given, entry) {
    case entry.event {
      entry.Decided(by:, verdict: Approve, holds:, ..) ->
        case
          list.any(given, fn(pair: #(String, List(String))) { pair.0 == by })
        {
          True -> given
          False -> list.append(given, [#(by, holds)])
        }
      entry.Decided(by:, verdict: Correct(..), holds:, ..) -> [#(by, holds)]
      _ -> given
    }
  })
}

/// The status as a head keeps it.
pub fn head_status(status: Status(o)) -> store.Status {
  case status {
    Recommended(_) -> store.Recommended
    Awaiting(_) -> store.Awaiting
    Accepted(..) -> store.Accepted
    Held(..) -> store.Held
    Released(..) -> store.Released
    Rejected(_) -> store.Rejected
    Expired(_) -> store.Expired
    Withdrawn(_) -> store.Withdrawn
    Refused(_) -> store.Refused
  }
}

/// Nothing further can happen to the outcome.
pub fn is_settled(status: Status(o)) -> Bool {
  case status {
    Recommended(_) | Awaiting(_) | Accepted(..) | Held(..) -> False
    Released(..) | Rejected(_) | Expired(_) | Withdrawn(_) | Refused(_) -> True
  }
}

/// Still waiting for the policy, a consulted point, or verdicts.
pub fn is_undecided(status: Status(o)) -> Bool {
  case status {
    Recommended(_) | Awaiting(_) -> True
    Accepted(..)
    | Held(..)
    | Released(..)
    | Rejected(_)
    | Expired(_)
    | Withdrawn(_)
    | Refused(_) -> False
  }
}

/// Undecided, and its validity ended at or before `now`. No verdict, answer
/// or policy step is accepted for it any more, whether or not the wake-up
/// that expires it was delivered.
pub fn has_lapsed(occurrence: Occurrence(o), now: Timestamp) -> Bool {
  case occurrence.valid_until, is_undecided(occurrence.status) {
    Some(deadline), True -> timestamp.compare(now, deadline) != order.Lt
    _, _ -> False
  }
}

/// When the occurrence next needs attention: the end of its validity while
/// it waits, the end of its hold while it is held.
pub fn due(occurrence: Occurrence(o)) -> Option(Timestamp) {
  case occurrence.status {
    Recommended(_) | Awaiting(_) -> occurrence.valid_until
    Held(until:, ..) -> Some(until)
    _ -> None
  }
}

/// Every time at which a wake-up must be delivered for the occurrence as
/// it stands: the end of a hold, or the end of validity and each later
/// policy answer while it waits. Empty once it settles.
pub fn wake_times(occurrence: Occurrence(o)) -> List(Timestamp) {
  case occurrence.status {
    Held(until:, ..) -> [until]
    Recommended(_) | Awaiting(_) -> {
      let started = recommended_at(occurrence)
      let steps =
        list.map(occurrence.later, fn(step: Step) {
          timestamp.add(started, duration.minutes(step.after))
        })
      list.append(option.values([occurrence.valid_until]), steps)
      |> list.filter(fn(at) {
        case occurrence.valid_until {
          // A step after the deadline never applies.
          Some(deadline) -> timestamp.compare(at, deadline) != order.Gt
          None -> True
        }
      })
      |> list.unique
      |> list.sort(timestamp.compare)
    }
    _ -> []
  }
}

fn events(occurrence: Occurrence(o)) -> List(Event(o)) {
  list.map(occurrence.entries, fn(entry) { entry.event })
}

/// When the recommendation was appended.
pub fn recommended_at(occurrence: Occurrence(o)) -> Timestamp {
  list.find_map(occurrence.entries, fn(entry) {
    case entry.event {
      entry.Recommended(..) -> Ok(entry.at)
      _ -> Error(Nil)
    }
  })
  |> result.lazy_unwrap(fn() { timestamp.unix_epoch })
}

/// The output that stands and who has approved exactly that output, in
/// order. A correction replaces the output and counts as its corrector's
/// approval; approvals of the earlier output no longer count.
pub fn standing(occurrence: Occurrence(o)) -> #(o, List(String)) {
  list.fold(
    events(occurrence),
    #(occurrence.recommendation.output, []),
    fn(standing, event) {
      case event {
        entry.Decided(by:, verdict: Approve, ..) ->
          case list.contains(standing.1, by) {
            True -> standing
            False -> #(standing.0, list.append(standing.1, [by]))
          }
        entry.Decided(by:, verdict: Correct(output:, ..), ..) -> #(output, [by])
        _ -> standing
      }
    },
  )
}

/// The first verdict the occurrence waited for, when a validator gave one.
pub fn verdict(occurrence: Occurrence(o)) -> Option(#(String, Verdict(o))) {
  list.first(verdicts(occurrence)) |> option.from_result
}

/// Every verdict the occurrence waited for, in order. More than one when
/// the policy asked for several approvals.
pub fn verdicts(occurrence: Occurrence(o)) -> List(#(String, Verdict(o))) {
  list.filter_map(events(occurrence), fn(event) {
    case event {
      entry.Decided(by:, verdict:, ..) -> Ok(#(by, verdict))
      _ -> Error(Nil)
    }
  })
}

/// For each verdict, who gave it and the entry that showed the card it was
/// given on.
pub fn seen(occurrence: Occurrence(o)) -> List(#(String, Int)) {
  list.filter_map(events(occurrence), fn(event) {
    case event {
      entry.Decided(by:, seen:, ..) -> Ok(#(by, seen))
      _ -> Error(Nil)
    }
  })
}

/// Verdicts given after the fact, on a sampled occurrence.
pub fn reviews(occurrence: Occurrence(o)) -> List(#(String, Verdict(o))) {
  list.filter_map(events(occurrence), fn(event) {
    case event {
      entry.Reviewed(by:, verdict:) -> Ok(#(by, verdict))
      _ -> Error(Nil)
    }
  })
}

/// Verdicts whose release was refused and rolled back, as
/// `#(by, verdict, reason)`.
pub fn refusals(
  occurrence: Occurrence(o),
) -> List(#(String, Verdict(o), String)) {
  list.filter_map(events(occurrence), fn(event) {
    case event {
      entry.VerdictRefused(by:, verdict:, reason:, ..) ->
        Ok(#(by, verdict, reason))
      _ -> Error(Nil)
    }
  })
}

/// The latest report of what the release did outside the database.
pub fn effect(occurrence: Occurrence(o)) -> Option(Effect) {
  list.fold(events(occurrence), None, fn(latest, event) {
    case event {
      entry.Effected(effect:) -> Some(effect)
      _ -> latest
    }
  })
}

/// The evidence the tool's guard read to allow the release.
pub fn relied(occurrence: Occurrence(o)) -> List(Ref) {
  list.flat_map(events(occurrence), fn(event) {
    case event {
      entry.Released(relied:, ..) -> relied
      _ -> []
    }
  })
}

/// Every answer the policy gave, with the time it gave it.
pub fn policy_answers(
  occurrence: Occurrence(o),
) -> List(#(Timestamp, Outcome)) {
  list.filter_map(occurrence.entries, fn(entry) {
    case entry.event {
      entry.PolicyApplied(outcome:, ..) -> Ok(#(entry.at, outcome))
      _ -> Error(Nil)
    }
  })
}

/// What proved true later, in order.
pub fn assessments(occurrence: Occurrence(o)) -> List(Assessment(o)) {
  list.filter_map(events(occurrence), fn(event) {
    case event {
      entry.Assessed(assessment:) -> Ok(assessment)
      _ -> Error(Nil)
    }
  })
}

/// What validators entered from outside the card, as `#(by, note)`.
pub fn notes(occurrence: Occurrence(o)) -> List(#(String, String)) {
  list.filter_map(events(occurrence), fn(event) {
    case event {
      entry.Noted(by:, note:) -> Ok(#(by, note))
      _ -> Error(Nil)
    }
  })
}

/// What validators opened beyond the card, as `#(read, evidence)`.
pub fn expansions(occurrence: Occurrence(o)) -> List(#(String, Ref)) {
  list.filter_map(events(occurrence), fn(event) {
    case event {
      entry.Expanded(read:, result:, ..) -> Ok(#(read, result))
      _ -> Error(Nil)
    }
  })
}

/// The inputs marked as changed the last time the card was shown: newer
/// revisions of context references and of the model's reads.
pub fn drift(occurrence: Occurrence(o)) -> List(Ref) {
  list.fold(events(occurrence), [], fn(latest, event) {
    case event {
      entry.Opened(drifted:, ..) -> drifted
      _ -> latest
    }
  })
}

/// The final output, once one is accepted.
pub fn final(occurrence: Occurrence(o)) -> Option(o) {
  case occurrence.status {
    Accepted(final:, ..) | Held(final:, ..) | Released(final:, ..) ->
      Some(final)
    _ -> None
  }
}

// -- What really happened --------------------------------------------------------

/// What really happened to an occurrence, as a follower or an agent tells
/// someone: the settled truth, never a status in between.
pub type Account(output) {
  /// Nothing final yet: it waits for the policy, a consulted point or
  /// verdicts, or it is accepted and held, and can still be withdrawn.
  Undecided
  /// Released with this final output under the release `key` (the key an
  /// outside effect is sent under). `effect` is the latest report of what
  /// happened outside the database, `None` while nothing is known: no
  /// report yet, or the latest one is `Uncertain`.
  Done(final: output, key: String, effect: Option(Effect))
  /// A validator rejected it.
  TurnedDown(by: String, reason: Reason)
  /// It can no longer be decided: the validity passed or an event
  /// superseded it.
  Lapsed(cause: ExpiryCause)
  /// The decider, or someone entitled to, withdrew it during its hold.
  TakenBack(by: String)
  /// The guard or the gated tool refused to release it.
  Blocked(reason: String)
}

/// What really happened, by status: see `Account`.
pub fn account(occurrence: Occurrence(o)) -> Account(o) {
  case occurrence.status {
    Recommended(_) | Awaiting(_) | Accepted(..) | Held(..) -> Undecided
    Released(final:, key:, ..) ->
      Done(final:, key:, effect: case effect(occurrence) {
        Some(vocabulary.Uncertain(_)) | None -> None
        Some(known) -> Some(known)
      })
    Rejected(reason:) ->
      TurnedDown(
        by: list.last(verdicts(occurrence))
          |> result.map(fn(given) { given.0 })
          |> result.unwrap(""),
        reason:,
      )
    Expired(cause:) -> Lapsed(cause:)
    Withdrawn(by:) -> TakenBack(by:)
    Refused(reason:) -> Blocked(reason:)
  }
}

/// Who answers for an occurrence's outcome.
pub type Responsible {
  /// The policy, at this version, let it proceed.
  ThePolicy(version: Int)
  /// A person: the validator whose verdict settled it, or who withdrew it.
  APerson(subject: String)
}

/// Who decided: the policy version or the validator that accepted it
/// (also for an output later held, released or refused by the tool), the
/// validator who rejected it, or who withdrew it. `None` while it waits and
/// when it expired, since nobody decided.
pub fn decided_by(occurrence: Occurrence(o)) -> Option(Responsible) {
  let from_decider = fn(decider) {
    case decider {
      ByPolicy(version:) -> Some(ThePolicy(version:))
      ByValidator(subject:) -> Some(APerson(subject:))
    }
  }
  case occurrence.status {
    Accepted(by:, ..) | Held(by:, ..) | Released(by:, ..) -> from_decider(by)
    Rejected(_) ->
      list.last(verdicts(occurrence))
      |> result.map(fn(given) { APerson(given.0) })
      |> option.from_result
    Withdrawn(by:) -> Some(APerson(by))
    Refused(_) ->
      // Who accepted the output the tool then refused.
      case
        fold(
          occurrence.id,
          list.filter(occurrence.entries, fn(e) {
            case e.event {
              entry.Refused(..) -> False
              _ -> True
            }
          }),
        )
      {
        Ok(Occurrence(status: Accepted(by:, ..), ..))
        | Ok(Occurrence(status: Held(by:, ..), ..)) -> from_decider(by)
        _ -> None
      }
    Recommended(_) | Awaiting(_) | Expired(_) -> None
  }
}
