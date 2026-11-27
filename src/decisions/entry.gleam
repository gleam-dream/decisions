//// The record of an occurrence: append-only entries. Everything that
//// happened to it, and every input that informed it, is an entry. Nothing
//// is updated in place, so "what was known at time T" is the entries up to
//// T, and `decisions/occurrence.fold` turns entries into where the
//// occurrence stands.
////
//// A record may begin, before its recommendation, with expectations
//// (`Expected`: a trigger was received and work is in flight) and failed
//// attempts (`AttemptFailed`), in any order, and with the `Expired` entry
//// that ended it before it began: a newer event superseded it, or its own
//// deadline passed. After an expiry by deadline a `Recommended` entry may
//// still follow, and the occurrence starts expired. Otherwise a record
//// begins with `Recommended`.
////
//// `to_stored` and `from_stored` are the only translation between an entry
//// and the text a store keeps, so an adapter never parses an entry.
////
//// `Event` may gain variants in a minor release. Code that matches it
//// should keep a `_` branch, or use the queries of `decisions/occurrence`.
////
//// Target-independent: builds for Erlang and JavaScript.

import decisions/internal/exact
import decisions/model.{type Failure}
import decisions/policy.{type Outcome, type Step}
import decisions/store.{type Stored, Stored}
import decisions/vocabulary.{
  type Assessment, type Bundle, type Effect, type ExpiryCause, type Facts,
  type Manifest, type Parent, type Recommendation, type Ref, type Subject,
  type Trigger, type Verdict,
}
import decisions/wire.{type Codec}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import json/blueprint/value.{type Value}

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
  /// A recommendation is expected under this key, about this subject: the
  /// trigger was received and the model is at work. Appended by
  /// `decisions.expect`, in the transaction that received the trigger, so
  /// that `happened` can supersede the work in flight before it is
  /// recommended. `valid_until` is the occurrence's own deadline, when the
  /// application gave one (`decisions.expect_until`); a later expectation
  /// may only bring it earlier.
  Expected(
    point: String,
    trigger: Trigger,
    subject: Subject,
    valid_until: Option(Timestamp),
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
    /// The bundle the occurrence belongs to, when it was proposed with
    /// others. A record written before bundles existed has none.
    bundle: Option(Bundle),
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
    Expected(..) -> "expected"
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
  "attempt_failed", "expected", "recommended", "informed", "policy_applied",
  "opened", "expanded", "noted", "decided", "verdict_refused", "reviewed",
  "held", "withdrawn", "released", "effected", "refused", "expired", "assessed",
]

/// The entry as a store keeps it. An error means the point's codec cannot
/// encode an output the entry carries.
pub fn to_stored(entry: Entry(o), output: Codec(o)) -> Result(Stored, String) {
  use form <- result.map(event_to_json(entry.event, output))
  let event = case form {
    Plain(event) -> json.to_string(event)
    Exact(event) -> value.to_string(event)
  }
  Stored(seq: entry.seq, at: entry.at, kind: kind(entry.event), event:)
}

/// The stored form of an event: `gleam/json` for an event that holds no
/// output, and an exact `Value` for one that does, so the point's codec
/// keeps every number of the output as it wrote it.
type Form {
  Plain(Json)
  Exact(Value)
}

/// An exact object: the `gleam/json` members before and after, made exact,
/// around the member that holds an output.
fn exact_object(
  before: List(#(String, Json)),
  holding: #(String, Value),
  after: List(#(String, Json)),
) -> Form {
  let made_exact = fn(members: List(#(String, Json))) {
    list.map(members, fn(member) { #(member.0, exact.from_json(member.1)) })
  }
  Exact(
    value.Object(
      list.flatten([made_exact(before), [holding], made_exact(after)]),
    ),
  )
}

/// The entry back from the store. An error means the text does not decode
/// with this point's codec: the record belongs to another point, or the
/// codec changed in a way the stored text does not survive.
pub fn from_stored(
  stored: Stored,
  output: Codec(o),
) -> Result(Entry(o), String) {
  // An event that holds an output is read in two parts: the member that
  // holds it exactly, from a `Value`, and its other members with their
  // `gleam/json` decoders, which would read the output's numbers as floats.
  let split = fn(name: String, read: fn(Value) -> Result(a, String)) {
    use raw <- result.try(
      value.parse(stored.event, value.unlimited())
      |> result.replace_error("the entry does not parse"),
    )
    use members <- result.try(exact.members(raw))
    use part <- result.map(exact.output_member(members, name, read))
    let others = list.filter(members, fn(member) { member.0 != name })
    #(part, value.to_string(value.Object(others)))
  }
  let rest = fn(text: String, decoder: Decoder(Event(o))) {
    json.parse(text, decoder)
    |> result.replace_error("the entry does not decode")
  }
  let with_verdict = fn(decoder: fn(Verdict(o)) -> Decoder(Event(o))) {
    use #(verdict, others) <- result.try(
      split("verdict", wire.decode_verdict(_, output)),
    )
    rest(others, decoder(verdict))
  }
  case stored.kind {
    "recommended" -> {
      use #(recommendation, others) <- result.try(
        split("recommendation", wire.decode_recommendation(_, output)),
      )
      rest(others, recommended_decoder(recommendation))
    }
    "decided" -> with_verdict(decided_decoder)
    "verdict_refused" -> with_verdict(verdict_refused_decoder)
    "reviewed" -> with_verdict(reviewed_decoder)
    "assessed" ->
      split("assessment", wire.decode_assessment(_, output))
      |> result.map(fn(split) { Assessed(assessment: split.0) })
    kind -> rest(stored.event, event_decoder(kind))
  }
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

fn event_to_json(event: Event(o), output: Codec(o)) -> Result(Form, String) {
  case event {
    AttemptFailed(point:, trigger:, subject:, failure:, evidence:) ->
      Ok(
        Plain(
          json.object([
            #("point", json.string(point)),
            #("trigger", wire.trigger(trigger)),
            #("subject", wire.subject(subject)),
            #("failure", model.failure_to_json(failure)),
            #("evidence", json.array(evidence, wire.ref)),
          ]),
        ),
      )
    Expected(point:, trigger:, subject:, valid_until:) ->
      Ok(
        Plain(
          json.object(list.append(
            [
              #("point", json.string(point)),
              #("trigger", wire.trigger(trigger)),
              #("subject", wire.subject(subject)),
            ],
            // Left out when there is none, so such an entry is stored as
            // before deadlines per occurrence existed.
            case valid_until {
              Some(at) -> [#("valid_until", wire.time(at))]
              None -> []
            },
          )),
        ),
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
      bundle:,
    ) -> {
      use recommendation <- result.map(wire.recommendation(
        recommendation,
        output,
      ))
      exact_object(
        [
          #("point", json.string(point)),
          #("trigger", wire.trigger(trigger)),
          #("parent", wire.optional(parent, wire.parent)),
          #("subject", wire.subject(subject)),
          #("requester", wire.optional(requester, json.string)),
          #("context", wire.manifest(context)),
        ],
        #("recommendation", recommendation),
        list.append(
          [#("valid_until", wire.optional(valid_until, wire.time))],
          // Written only when present, so a record outside a bundle has no
          // bundle member.
          case bundle {
            Some(bundle) -> [#("bundle", wire.bundle(bundle))]
            None -> []
          },
        ),
      )
    }
    Informed(from:, facts:) ->
      Ok(
        Plain(
          json.object([
            #("from", json.string(from)),
            #("facts", wire.facts(facts)),
          ]),
        ),
      )
    PolicyApplied(version:, outcome:, sampled:, later:) ->
      Ok(
        Plain(
          json.object([
            #("version", json.int(version)),
            #("outcome", policy.outcome_to_json(outcome)),
            #("sampled", json.bool(sampled)),
            #("later", json.array(later, policy.step_to_json)),
          ]),
        ),
      )
    Opened(by:, drifted:) ->
      Ok(
        Plain(
          json.object([
            #("by", json.string(by)),
            #("drifted", json.array(drifted, wire.ref)),
          ]),
        ),
      )
    Expanded(by:, read:, result:) ->
      Ok(
        Plain(
          json.object([
            #("by", json.string(by)),
            #("read", json.string(read)),
            #("result", wire.ref(result)),
          ]),
        ),
      )
    Noted(by:, note:) ->
      Ok(
        Plain(
          json.object([#("by", json.string(by)), #("note", json.string(note))]),
        ),
      )
    Decided(by:, verdict:, seen:, holds:) -> {
      use verdict <- result.map(wire.verdict(verdict, output))
      exact_object([#("by", json.string(by))], #("verdict", verdict), [
        #("seen", json.int(seen)),
        #("holds", json.array(holds, json.string)),
      ])
    }
    VerdictRefused(by:, verdict:, seen:, reason:) -> {
      use verdict <- result.map(wire.verdict(verdict, output))
      exact_object([#("by", json.string(by))], #("verdict", verdict), [
        #("seen", json.int(seen)),
        #("reason", json.string(reason)),
      ])
    }
    Reviewed(by:, verdict:) -> {
      use verdict <- result.map(wire.verdict(verdict, output))
      exact_object([#("by", json.string(by))], #("verdict", verdict), [])
    }
    Held(until:) -> Ok(Plain(json.object([#("until", wire.time(until))])))
    Withdrawn(by:) -> Ok(Plain(json.object([#("by", json.string(by))])))
    Released(key:, tool:, relied:) ->
      Ok(
        Plain(
          json.object([
            #("key", json.string(key)),
            #("tool", json.string(tool)),
            #("relied", json.array(relied, wire.ref)),
          ]),
        ),
      )
    Effected(effect:) ->
      Ok(Plain(json.object([#("effect", wire.effect(effect))])))
    Refused(reason:) ->
      Ok(Plain(json.object([#("reason", json.string(reason))])))
    Expired(cause:) ->
      Ok(Plain(json.object([#("cause", wire.expiry_cause(cause))])))
    Assessed(assessment:) -> {
      use assessment <- result.map(wire.assessment(assessment, output))
      exact_object([], #("assessment", assessment), [])
    }
  }
}

fn event_decoder(kind: String) -> Decoder(Event(o)) {
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
    "expected" -> {
      use point <- decode.field("point", decode.string)
      use trigger <- decode.field("trigger", wire.trigger_decoder())
      use subject <- decode.field("subject", wire.subject_decoder())
      use valid_until <- decode.optional_field(
        "valid_until",
        None,
        decode.optional(wire.time_decoder()),
      )
      decode.success(Expected(point:, trigger:, subject:, valid_until:))
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
    _ -> decode.failure(Refused(""), "a known entry kind")
  }
}

/// The members of a `recommended` entry other than its recommendation,
/// which is read exactly.
fn recommended_decoder(recommendation: Recommendation(o)) -> Decoder(Event(o)) {
  use point <- decode.field("point", decode.string)
  use trigger <- decode.field("trigger", wire.trigger_decoder())
  use parent <- decode.field("parent", decode.optional(wire.parent_decoder()))
  use subject <- decode.field("subject", wire.subject_decoder())
  use requester <- decode.field("requester", decode.optional(decode.string))
  use context <- decode.field("context", wire.manifest_decoder())
  use valid_until <- decode.field(
    "valid_until",
    decode.optional(wire.time_decoder()),
  )
  use bundle <- decode.optional_field(
    "bundle",
    None,
    decode.optional(wire.bundle_decoder()),
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
    bundle:,
  ))
}

fn decided_decoder(verdict: Verdict(o)) -> Decoder(Event(o)) {
  use by <- decode.field("by", decode.string)
  use seen <- decode.field("seen", decode.int)
  use holds <- decode.optional_field("holds", [], decode.list(decode.string))
  decode.success(Decided(by:, verdict:, seen:, holds:))
}

fn verdict_refused_decoder(verdict: Verdict(o)) -> Decoder(Event(o)) {
  use by <- decode.field("by", decode.string)
  use seen <- decode.field("seen", decode.int)
  use reason <- decode.field("reason", decode.string)
  decode.success(VerdictRefused(by:, verdict:, seen:, reason:))
}

fn reviewed_decoder(verdict: Verdict(o)) -> Decoder(Event(o)) {
  use by <- decode.field("by", decode.string)
  decode.success(Reviewed(by:, verdict:))
}

/// The point a stored record belongs to, read from its first entry
/// without decoding the output. `Error(Nil)` when the entry names none.
pub fn point_of(stored: Stored) -> Result(String, Nil) {
  json.parse(stored.event, decode.at(["point"], decode.string))
  |> result.replace_error(Nil)
}
