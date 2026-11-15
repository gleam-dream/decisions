//// The record of an occurrence: append-only entries. Everything that
//// happened to it, and every input that informed it, is an entry. Nothing
//// is updated in place, so "what was known at time T" is the entries up to
//// T, and `decisions/occurrence.fold` turns entries into where the
//// occurrence stands.
////
//// A record may begin with failed attempts (`AttemptFailed`) before its
//// recommendation, when a recommender failed under the occurrence's key.
//// Every other record begins with `Recommended`.
////
//// `to_stored` and `from_stored` are the only translation between an entry
//// and the text a store keeps, so an adapter never parses an entry.
////
//// `Event` may gain variants in a minor release. Code that matches it
//// should keep a `_` branch, or use the queries of `decisions/occurrence`.
////
//// Target-independent: builds for Erlang and JavaScript.

import decisions/model.{type Failure}
import decisions/policy.{type Outcome, type Step}
import decisions/store.{type Stored, Stored}
import decisions/vocabulary.{
  type Assessment, type Effect, type ExpiryCause, type Facts, type Manifest,
  type Parent, type Recommendation, type Ref, type Subject, type Trigger,
  type Verdict,
}
import decisions/wire.{type Codec}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/result
import gleam/time/timestamp.{type Timestamp}

/// One entry: its place in the record, when it was appended, and what
/// happened.
pub type Entry(output) {
  Entry(seq: Int, at: Timestamp, event: Event(output))
}

/// What happened.
pub type Event(output) {
  /// A recommender failed under this key before any recommendation
  /// existed. Appended by `decisions.record_failure`, in a transaction of
  /// its own.
  AttemptFailed(
    point: String,
    trigger: Trigger,
    subject: Subject,
    failure: Failure,
    /// Evidence the application stored about the attempt, such as the
    /// exchange that did not decode.
    evidence: List(Ref),
  )
  /// The recommendation the occurrence began with.
  Recommended(
    /// The decision point this is an occurrence of.
    point: String,
    trigger: Trigger,
    parent: Option(Parent),
    subject: Subject,
    /// Who asked, when a person did.
    requester: Option(String),
    context: Manifest,
    recommendation: Recommendation(output),
    valid_until: Option(Timestamp),
  )
  /// A consulted decision point's final output, as facts.
  Informed(from: String, facts: Facts)
  /// What the policy said, and what it will say as the occurrence waits.
  /// Appended again each time waiting changes the answer.
  PolicyApplied(
    version: Int,
    outcome: Outcome,
    sampled: Bool,
    later: List(Step),
  )
  /// The card was shown to a validator. `drifted` holds the newer revision
  /// of each input, in the context or among the model's reads, that changed
  /// since the model read it.
  Opened(by: String, drifted: List(Ref))
  /// The validator opened more than the card showed; `result` is the
  /// captured evidence of what that read returned.
  Expanded(by: String, read: String, result: Ref)
  /// What the validator brought from outside the card.
  Noted(by: String, note: String)
  /// A verdict the occurrence waited for. `seen` is the entry that showed
  /// the card the verdict was given on; `holds` the decision sets the
  /// validator held then, which decide which alternative of an `Either`
  /// their approval counts toward.
  Decided(by: String, verdict: Verdict(output), seen: Int, holds: List(String))
  /// A verdict whose release the guard or the gated tool refused, so the
  /// verdict's transaction rolled back. Appended afterwards by
  /// `decisions.record_refusal`, in a transaction of its own. It changes
  /// no status.
  VerdictRefused(
    by: String,
    verdict: Verdict(output),
    seen: Int,
    reason: String,
  )
  /// A verdict after the fact, on a sampled and released occurrence.
  Reviewed(by: String, verdict: Verdict(output))
  /// The accepted output waits until `until` before release, and its
  /// decider may withdraw it meanwhile.
  Held(until: Timestamp)
  Withdrawn(by: String)
  /// The final output reached the gated tool named `tool`. `relied` is the
  /// evidence the tool's guard read to allow it.
  Released(key: String, tool: String, relied: List(Ref))
  /// What became of the release outside the database.
  Effected(effect: Effect)
  /// The guard or the gated tool refused a release that nobody was waiting
  /// on, so the occurrence ended.
  Refused(reason: String)
  Expired(cause: ExpiryCause)
  Assessed(assessment: Assessment(output))
}

/// The stable name of an entry's kind, as a store keeps it.
pub fn kind(event: Event(output)) -> String {
  case event {
    AttemptFailed(..) -> "attempt_failed"
    Recommended(..) -> "recommended"
    Informed(..) -> "informed"
    PolicyApplied(..) -> "policy_applied"
    Opened(..) -> "opened"
    Expanded(..) -> "expanded"
    Noted(..) -> "noted"
    Decided(..) -> "decided"
    VerdictRefused(..) -> "verdict_refused"
    Reviewed(..) -> "reviewed"
    Held(..) -> "held"
    Withdrawn(..) -> "withdrawn"
    Released(..) -> "released"
    Effected(..) -> "effected"
    Refused(..) -> "refused"
    Expired(..) -> "expired"
    Assessed(..) -> "assessed"
  }
}

/// Every kind name, in the order of `Event`.
pub const kinds = [
  "attempt_failed", "recommended", "informed", "policy_applied", "opened",
  "expanded", "noted", "decided", "verdict_refused", "reviewed", "held",
  "withdrawn", "released", "effected", "refused", "expired", "assessed",
]

/// The entry as a store keeps it. An error means the point's codec cannot
/// encode an output the entry carries.
pub fn to_stored(entry: Entry(o), output: Codec(o)) -> Result(Stored, String) {
  use event <- result.map(event_to_json(entry.event, output))
  Stored(
    seq: entry.seq,
    at: entry.at,
    kind: kind(entry.event),
    event: json.to_string(event),
  )
}

/// The entry back from the store. An error means the text does not decode
/// with this point's codec: the record belongs to another point, or the
/// codec changed in a way the stored text does not survive.
pub fn from_stored(
  stored: Stored,
  output: Codec(o),
) -> Result(Entry(o), String) {
  json.parse(stored.event, event_decoder(stored.kind, output))
  |> result.map(Entry(seq: stored.seq, at: stored.at, event: _))
  |> result.replace_error(
    "entry "
    <> stored.kind
    <> " at "
    <> int_text(stored.seq)
    <> " does not decode with this point's codec",
  )
}

fn int_text(value: Int) -> String {
  json.to_string(json.int(value))
}

fn event_to_json(event: Event(o), output: Codec(o)) -> Result(Json, String) {
  case event {
    AttemptFailed(point:, trigger:, subject:, failure:, evidence:) ->
      Ok(
        json.object([
          #("point", json.string(point)),
          #("trigger", wire.trigger(trigger)),
          #("subject", wire.subject(subject)),
          #("failure", model.failure_to_json(failure)),
          #("evidence", json.array(evidence, wire.ref)),
        ]),
      )
    Recommended(
      point:,
      trigger:,
      parent:,
      subject:,
      requester:,
      context:,
      recommendation:,
      valid_until:,
    ) -> {
      use recommendation <- result.map(wire.recommendation(
        recommendation,
        output,
      ))
      json.object([
        #("point", json.string(point)),
        #("trigger", wire.trigger(trigger)),
        #("parent", wire.optional(parent, wire.parent)),
        #("subject", wire.subject(subject)),
        #("requester", wire.optional(requester, json.string)),
        #("context", wire.manifest(context)),
        #("recommendation", recommendation),
        #("valid_until", wire.optional(valid_until, wire.time)),
      ])
    }
    Informed(from:, facts:) ->
      Ok(
        json.object([
          #("from", json.string(from)),
          #("facts", wire.facts(facts)),
        ]),
      )
    PolicyApplied(version:, outcome:, sampled:, later:) ->
      Ok(
        json.object([
          #("version", json.int(version)),
          #("outcome", policy.outcome_to_json(outcome)),
          #("sampled", json.bool(sampled)),
          #("later", json.array(later, policy.step_to_json)),
        ]),
      )
    Opened(by:, drifted:) ->
      Ok(
        json.object([
          #("by", json.string(by)),
          #("drifted", json.array(drifted, wire.ref)),
        ]),
      )
    Expanded(by:, read:, result:) ->
      Ok(
        json.object([
          #("by", json.string(by)),
          #("read", json.string(read)),
          #("result", wire.ref(result)),
        ]),
      )
    Noted(by:, note:) ->
      Ok(json.object([#("by", json.string(by)), #("note", json.string(note))]))
    Decided(by:, verdict:, seen:, holds:) -> {
      use verdict <- result.map(wire.verdict(verdict, output))
      json.object([
        #("by", json.string(by)),
        #("verdict", verdict),
        #("seen", json.int(seen)),
        #("holds", json.array(holds, json.string)),
      ])
    }
    VerdictRefused(by:, verdict:, seen:, reason:) -> {
      use verdict <- result.map(wire.verdict(verdict, output))
      json.object([
        #("by", json.string(by)),
        #("verdict", verdict),
        #("seen", json.int(seen)),
        #("reason", json.string(reason)),
      ])
    }
    Reviewed(by:, verdict:) -> {
      use verdict <- result.map(wire.verdict(verdict, output))
      json.object([#("by", json.string(by)), #("verdict", verdict)])
    }
    Held(until:) -> Ok(json.object([#("until", wire.time(until))]))
    Withdrawn(by:) -> Ok(json.object([#("by", json.string(by))]))
    Released(key:, tool:, relied:) ->
      Ok(
        json.object([
          #("key", json.string(key)),
          #("tool", json.string(tool)),
          #("relied", json.array(relied, wire.ref)),
        ]),
      )
    Effected(effect:) -> Ok(json.object([#("effect", wire.effect(effect))]))
    Refused(reason:) -> Ok(json.object([#("reason", json.string(reason))]))
    Expired(cause:) -> Ok(json.object([#("cause", wire.expiry_cause(cause))]))
    Assessed(assessment:) -> {
      use assessment <- result.map(wire.assessment(assessment, output))
      json.object([#("assessment", assessment)])
    }
  }
}

fn event_decoder(kind: String, output: Codec(o)) -> Decoder(Event(o)) {
  case kind {
    "attempt_failed" -> {
      use point <- decode.field("point", decode.string)
      use trigger <- decode.field("trigger", wire.trigger_decoder())
      use subject <- decode.field("subject", wire.subject_decoder())
      use failure <- decode.field("failure", model.failure_decoder())
      use evidence <- decode.optional_field(
        "evidence",
        [],
        decode.list(wire.ref_decoder()),
      )
      decode.success(AttemptFailed(
        point:,
        trigger:,
        subject:,
        failure:,
        evidence:,
      ))
    }
    "recommended" -> {
      use point <- decode.field("point", decode.string)
      use trigger <- decode.field("trigger", wire.trigger_decoder())
      use parent <- decode.field(
        "parent",
        decode.optional(wire.parent_decoder()),
      )
      use subject <- decode.field("subject", wire.subject_decoder())
      use requester <- decode.field("requester", decode.optional(decode.string))
      use context <- decode.field("context", wire.manifest_decoder())
      use recommendation <- decode.field(
        "recommendation",
        wire.recommendation_decoder(output),
      )
      use valid_until <- decode.field(
        "valid_until",
        decode.optional(wire.time_decoder()),
      )
      decode.success(Recommended(
        point:,
        trigger:,
        parent:,
        subject:,
        requester:,
        context:,
        recommendation:,
        valid_until:,
      ))
    }
    "informed" -> {
      use from <- decode.field("from", decode.string)
      use facts <- decode.field("facts", wire.facts_decoder())
      decode.success(Informed(from:, facts:))
    }
    "policy_applied" -> {
      use version <- decode.field("version", decode.int)
      use outcome <- decode.field("outcome", policy.outcome_decoder())
      use sampled <- decode.field("sampled", decode.bool)
      use later <- decode.field("later", decode.list(policy.step_decoder()))
      decode.success(PolicyApplied(version:, outcome:, sampled:, later:))
    }
    "opened" -> {
      use by <- decode.field("by", decode.string)
      use drifted <- decode.field("drifted", decode.list(wire.ref_decoder()))
      decode.success(Opened(by:, drifted:))
    }
    "expanded" -> {
      use by <- decode.field("by", decode.string)
      use read <- decode.field("read", decode.string)
      use result <- decode.field("result", wire.ref_decoder())
      decode.success(Expanded(by:, read:, result:))
    }
    "noted" -> {
      use by <- decode.field("by", decode.string)
      use note <- decode.field("note", decode.string)
      decode.success(Noted(by:, note:))
    }
    "decided" -> {
      use by <- decode.field("by", decode.string)
      use verdict <- decode.field("verdict", wire.verdict_decoder(output))
      use seen <- decode.field("seen", decode.int)
      use holds <- decode.optional_field(
        "holds",
        [],
        decode.list(decode.string),
      )
      decode.success(Decided(by:, verdict:, seen:, holds:))
    }
    "verdict_refused" -> {
      use by <- decode.field("by", decode.string)
      use verdict <- decode.field("verdict", wire.verdict_decoder(output))
      use seen <- decode.field("seen", decode.int)
      use reason <- decode.field("reason", decode.string)
      decode.success(VerdictRefused(by:, verdict:, seen:, reason:))
    }
    "reviewed" -> {
      use by <- decode.field("by", decode.string)
      use verdict <- decode.field("verdict", wire.verdict_decoder(output))
      decode.success(Reviewed(by:, verdict:))
    }
    "held" -> {
      use until <- decode.field("until", wire.time_decoder())
      decode.success(Held(until:))
    }
    "withdrawn" -> {
      use by <- decode.field("by", decode.string)
      decode.success(Withdrawn(by:))
    }
    "released" -> {
      use key <- decode.field("key", decode.string)
      use tool <- decode.field("tool", decode.string)
      use relied <- decode.field("relied", decode.list(wire.ref_decoder()))
      decode.success(Released(key:, tool:, relied:))
    }
    "effected" -> {
      use effect <- decode.field("effect", wire.effect_decoder())
      decode.success(Effected(effect:))
    }
    "refused" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(Refused(reason:))
    }
    "expired" -> {
      use cause <- decode.field("cause", wire.expiry_cause_decoder())
      decode.success(Expired(cause:))
    }
    "assessed" -> {
      use assessment <- decode.field(
        "assessment",
        wire.assessment_decoder(output),
      )
      decode.success(Assessed(assessment:))
    }
    _ -> decode.failure(Refused(""), "a known entry kind")
  }
}

/// The point a stored record belongs to, read from its first entry
/// without decoding the output. `Error(Nil)` when the entry names none.
pub fn point_of(stored: Stored) -> Result(String, Nil) {
  json.parse(stored.event, decode.at(["point"], decode.string))
  |> result.replace_error(Nil)
}
