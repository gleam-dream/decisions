//// The JSON form of every value a record holds, and `Codec`, which carries
//// a point's output type across the store and across a process boundary.
////
//// An occurrence survives a restart only as text, so every value in
//// `decisions/vocabulary` has an encoder and a decoder here. A tagged sum
//// is an object whose `"t"` field names the variant. Times are whole
//// milliseconds since the Unix epoch.
////
//// A value that holds an output (a recommendation, a verdict, an
//// assessment) is written and read as a json_blueprint `Value`, so the
//// point's codec keeps every number exact: an output such as the decimal
//// `12345678901234567.89` is stored, read back and released unchanged.
//// The other values are `gleam/json` forms. `parse` and
//// `decisions/view.verdict` read text that a client sent strictly: within
//// json_blueprint's default limits, refusing a key given twice.
////
//// Build a point's codec from a `json_blueprint` codec with `codec`, and
//// the codec also carries the output's JSON Schema, which a card shows so
//// that a client with none of the point's code can build a correction
//// form. `plain` builds a codec without a schema.
////
//// ```gleam
//// import decisions/wire
//// import json/blueprint/codec
////
//// pub type Refund {
////   Refund(fee: String, cents: Int)
//// }
////
//// pub fn refund() -> wire.Codec(Refund) {
////   wire.codec({
////     use fee <- codec.field("fee", codec.string(), get: fn(r) { r.fee })
////     use cents <- codec.field("cents", codec.int(), get: fn(r) { r.cents })
////     codec.success(Refund(fee:, cents:))
////   })
//// }
//// ```
////
//// A point holds its codec, and a point is copied wherever its desk goes:
//// into Grind job closures, into the state of `decisions_otp`'s processes,
//// and, through a model that captures a codec, into each isolated model
//// call. A copy between processes does not keep sharing. `Codec` therefore
//// holds only what it was built from, and derives its encoder, decoder and
//// schema on each call. For how to write a json_blueprint codec that stays
//// small when copied, see json_blueprint's
//// [codec practice](https://github.com/gleam-dream/json_blueprint/blob/main/docs/CODEC-PRACTICE.md).
////
//// Target-independent: builds for Erlang and JavaScript.

import decisions/internal/exact
import decisions/vocabulary.{
  type Assessment, type Bundle, type Effect, type ExpiryCause, type Explanation,
  type Fact, type Facts, type Finding, type Manifest, type Parent, type Reason,
  type Recommendation, type Recommender, type Ref, type Subject, type Trigger,
  type Validator, type Verdict, type Verdicts, Agent, Approve, ApproveOrReject,
  ApproveRejectOrCorrect, Assessment, Bundle, Classifier, Correct,
  DeadlinePassed, Flag, Manifest, ModelCall, NotPerformed, Number, OwnAct,
  ParentOccurrence, ParentRun, Performed, Person, Reason, Receipt,
  Recommendation, Ref, Reject, Right, RuleFired, Rules, RunAction, RunAnswer,
  Subject, Superseded, Text, Trigger, Uncertain, Validator, Wrong,
}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import json/blueprint/codec as blueprint
import json/blueprint/value.{type Value}

/// How a point's output type becomes JSON and comes back. Build one with
/// `codec` (which also carries the output's schema) or `plain`.
///
/// It holds only what it was built from, because it is copied with its
/// point (see the module documentation).
pub opaque type Codec(a) {
  Blueprinted(blueprint: blueprint.Codec(a))
  Plain(encode: fn(a) -> Json, decoder: Decoder(a))
}

/// A codec from a `json_blueprint` codec. It carries the output's JSON
/// Schema (Draft 2020-12), which `schema` returns and a card shows.
pub fn codec(blueprint: blueprint.Codec(a)) -> Codec(a) {
  Blueprinted(blueprint:)
}

/// A codec from an encoder and a decoder, with no schema. A card for a
/// point with this codec can be approved or rejected by any client, and a
/// correction form must be built by code that knows the output type.
pub fn plain(encode: fn(a) -> Json, decoder: Decoder(a)) -> Codec(a) {
  Plain(encode:, decoder:)
}

/// A json_blueprint codec over any JSON, through an encoder and a decoder.
/// Its schema admits any value. Encoding re-reads the text the encoder just
/// wrote, which is trusted, so it parses without json_blueprint's limits for
/// untrusted input (1 MiB, 128 levels deep).
fn any_json(encode: fn(a) -> Json, decoder: Decoder(a)) -> blueprint.Codec(a) {
  blueprint.try_map(
    blueprint.value(),
    decode: fn(raw) {
      json.parse(value.to_string(raw), decoder)
      |> result.replace_error("the value does not decode")
    },
    encode: fn(item) {
      value.parse(json.to_string(encode(item)), value.unlimited())
      |> result.replace_error("the value does not encode")
    },
    placeholder: placeholder(decoder),
  )
}

@external(erlang, "gleam_stdlib", "identity")
@external(javascript, "../../gleam_stdlib/gleam_stdlib.mjs", "identity")
fn coerce(value: a) -> b

/// A placeholder of `a` for json_blueprint, which needs one to describe a
/// codec and never encodes it: the zero value of a decoder that failed.
fn placeholder(decoder: Decoder(a)) -> a {
  case decode.run(coerce(Nil), decoder) {
    Ok(item) -> item
    Error(_) -> coerce(Nil)
  }
}

/// The output's codec as a `json_blueprint` codec, for building a document
/// that holds outputs, such as the card's (`decisions/view.codec`). For a
/// `plain` codec its schema admits any JSON.
pub fn blueprint(codec: Codec(a)) -> blueprint.Codec(a) {
  case codec {
    Blueprinted(blueprint:) -> blueprint
    Plain(encode:, decoder:) -> any_json(encode, decoder)
  }
}

/// A codec for text outputs, with its schema.
pub fn text() -> Codec(String) {
  codec(blueprint.string())
}

/// Encode an output, exactly. An error means the codec refuses the value.
pub fn encode(codec: Codec(a), item: a) -> Result(Value, String) {
  case codec {
    Blueprinted(blueprint:) ->
      blueprint.encode(blueprint, item)
      |> result.map_error(blueprint.describe_encode_error)
    Plain(encode:, ..) -> Ok(exact.from_json(encode(item)))
  }
}

/// Decode an output from a `Value`, exactly.
pub fn decode(codec: Codec(a), raw: Value) -> Result(a, String) {
  case codec {
    Blueprinted(blueprint:) ->
      blueprint.decode(blueprint, raw)
      |> result.map_error(blueprint.describe_decode_error)
    Plain(decoder:, ..) ->
      json.parse(value.to_string(raw), decoder)
      |> result.replace_error("the value does not decode")
  }
}

/// The output's JSON Schema document, when the codec carries one. It is
/// rendered from the json_blueprint codec on each call.
pub fn schema(codec: Codec(a)) -> Option(Json) {
  case codec {
    Blueprinted(blueprint:) ->
      blueprint.schema(blueprint)
      |> result.replace_error(Nil)
      |> result.try(fn(found) {
        blueprint.schema_document(found)
        |> value.to_json
        |> result.replace_error(Nil)
      })
      |> option.from_result
    Plain(..) -> None
  }
}

/// Decode an output from JSON text that a client sent: within
/// json_blueprint's default limits (1 MiB, 128 levels deep), refusing a key
/// given twice, with exact numbers.
pub fn parse(
  codec: Codec(a),
  text: String,
) -> Result(a, blueprint.DecodeError) {
  blueprint.decode_json(blueprint(codec), text)
}

// -- Helpers --------------------------------------------------------------------

/// An object whose `"t"` field names the variant, followed by `fields`.
pub fn tagged(tag: String, fields: List(#(String, Json))) -> Json {
  json.object([#("t", json.string(tag)), ..fields])
}

/// `null` for `None`, the encoded value otherwise.
pub fn optional(item: Option(a), encode: fn(a) -> Json) -> Json {
  case item {
    Some(item) -> encode(item)
    None -> json.null()
  }
}

/// Whole milliseconds since the Unix epoch, rounded down.
pub fn milliseconds(at: Timestamp) -> Int {
  let #(seconds, nanoseconds) = timestamp.to_unix_seconds_and_nanoseconds(at)
  seconds * 1000 + nanoseconds / 1_000_000
}

/// The time `ms` milliseconds after the Unix epoch.
pub fn from_milliseconds(ms: Int) -> Timestamp {
  timestamp.from_unix_seconds_and_nanoseconds(
    seconds: ms / 1000,
    nanoseconds: { ms % 1000 } * 1_000_000,
  )
}

/// A time as whole milliseconds.
pub fn time(at: Timestamp) -> Json {
  json.int(milliseconds(at))
}

/// Decodes a time written by `time`.
pub fn time_decoder() -> Decoder(Timestamp) {
  decode.map(decode.int, from_milliseconds)
}

// -- References and context -------------------------------------------------------

/// `{"kind", "id", "revision"}`.
pub fn ref(ref: Ref) -> Json {
  json.object([
    #("kind", json.string(ref.kind)),
    #("id", json.string(ref.id)),
    #("revision", json.string(ref.revision)),
  ])
}

/// Decodes a `Ref` written by `ref`.
pub fn ref_decoder() -> Decoder(Ref) {
  use kind <- decode.field("kind", decode.string)
  use id <- decode.field("id", decode.string)
  use revision <- decode.field("revision", decode.string)
  decode.success(Ref(kind:, id:, revision:))
}

/// `{"refs", "renderer"}`.
pub fn manifest(manifest: Manifest) -> Json {
  json.object([
    #("refs", json.array(manifest.refs, ref)),
    #("renderer", json.string(manifest.renderer)),
  ])
}

/// Decodes a `Manifest` written by `manifest`.
pub fn manifest_decoder() -> Decoder(Manifest) {
  use refs <- decode.field("refs", decode.list(ref_decoder()))
  use renderer <- decode.field("renderer", decode.string)
  decode.success(Manifest(refs:, renderer:))
}

/// `{"kind", "id"}`.
pub fn subject(subject: Subject) -> Json {
  json.object([
    #("kind", json.string(subject.kind)),
    #("id", json.string(subject.id)),
  ])
}

/// Decodes a `Subject` written by `subject`.
pub fn subject_decoder() -> Decoder(Subject) {
  use kind <- decode.field("kind", decode.string)
  use id <- decode.field("id", decode.string)
  decode.success(Subject(kind:, id:))
}

/// `{"kind", "id"}`.
pub fn trigger(trigger: Trigger) -> Json {
  json.object([
    #("kind", json.string(trigger.kind)),
    #("id", json.string(trigger.id)),
  ])
}

/// Decodes a `Trigger` written by `trigger`.
pub fn trigger_decoder() -> Decoder(Trigger) {
  use kind <- decode.field("kind", decode.string)
  use id <- decode.field("id", decode.string)
  decode.success(Trigger(kind:, id:))
}

/// Tagged `run` or `occurrence`, with `"id"`.
pub fn parent(parent: Parent) -> Json {
  case parent {
    ParentRun(run:) -> tagged("run", [#("id", json.string(run))])
    ParentOccurrence(id:) -> tagged("occurrence", [#("id", json.string(id))])
  }
}

/// A `Bundle` as JSON.
pub fn bundle(bundle: Bundle) -> Json {
  json.object([
    #("key", json.string(bundle.key)),
    #("size", json.int(bundle.size)),
  ])
}

/// Decodes a `Bundle` written by `bundle`.
pub fn bundle_decoder() -> Decoder(Bundle) {
  use key <- decode.field("key", decode.string)
  use size <- decode.field("size", decode.int)
  decode.success(Bundle(key:, size:))
}

/// Decodes a `Parent` written by `parent`.
pub fn parent_decoder() -> Decoder(Parent) {
  use tag <- decode.field("t", decode.string)
  use id <- decode.field("id", decode.string)
  case tag {
    "run" -> decode.success(ParentRun(id))
    "occurrence" -> decode.success(ParentOccurrence(id))
    _ -> decode.failure(ParentRun(id), "Parent")
  }
}

/// Tagged by recommender kind, with `"name"` and `"version"`.
pub fn recommender(by: Recommender) -> Json {
  let #(tag, name, version) = case by {
    Rules(name:, version:) -> #("rules", name, version)
    Classifier(name:, version:) -> #("classifier", name, version)
    ModelCall(configuration:, version:) -> #(
      "model_call",
      configuration,
      version,
    )
    Agent(kind:, version:) -> #("agent", kind, version)
    Person(subject:) -> #("person", subject, "")
  }
  tagged(tag, [#("name", json.string(name)), #("version", json.string(version))])
}

/// Decodes a `Recommender` written by `recommender`.
pub fn recommender_decoder() -> Decoder(Recommender) {
  use tag <- decode.field("t", decode.string)
  use name <- decode.field("name", decode.string)
  use version <- decode.field("version", decode.string)
  case tag {
    "rules" -> decode.success(Rules(name:, version:))
    "classifier" -> decode.success(Classifier(name:, version:))
    "model_call" -> decode.success(ModelCall(configuration: name, version:))
    "agent" -> decode.success(Agent(kind: name, version:))
    "person" -> decode.success(Person(subject: name))
    _ -> decode.failure(Person(name), "Recommender")
  }
}

/// Tagged by explanation kind.
pub fn explanation(explanation: Explanation) -> Json {
  case explanation {
    RuleFired(rule:) -> tagged("rule", [#("rule", json.string(rule))])
    Receipt(evidence:) -> tagged("receipt", [#("evidence", ref(evidence))])
    RunAnswer(run:) -> tagged("run_answer", [#("run", json.string(run))])
    RunAction(run:, action:) ->
      tagged("run_action", [
        #("run", json.string(run)),
        #("action", json.string(action)),
      ])
    OwnAct -> tagged("own_act", [])
  }
}

/// Decodes an `Explanation` written by `explanation`.
pub fn explanation_decoder() -> Decoder(Explanation) {
  use tag <- decode.field("t", decode.string)
  case tag {
    "rule" -> {
      use rule <- decode.field("rule", decode.string)
      decode.success(RuleFired(rule:))
    }
    "receipt" -> {
      use evidence <- decode.field("evidence", ref_decoder())
      decode.success(Receipt(evidence:))
    }
    "run_answer" -> {
      use run <- decode.field("run", decode.string)
      decode.success(RunAnswer(run:))
    }
    "run_action" -> {
      use run <- decode.field("run", decode.string)
      use action <- decode.field("action", decode.string)
      decode.success(RunAction(run:, action:))
    }
    "own_act" -> decode.success(OwnAct)
    _ -> decode.failure(OwnAct, "Explanation")
  }
}

// -- Facts ----------------------------------------------------------------------

/// Tagged `number`, `text` or `flag`, with the value in `"v"`.
pub fn fact(fact: Fact) -> Json {
  case fact {
    Number(value) -> tagged("number", [#("v", json.float(value))])
    Text(value) -> tagged("text", [#("v", json.string(value))])
    Flag(value) -> tagged("flag", [#("v", json.bool(value))])
  }
}

/// Decodes a `Fact` written by `fact`. A number written as an integer
/// decodes as well.
pub fn fact_decoder() -> Decoder(Fact) {
  use tag <- decode.field("t", decode.string)
  case tag {
    "number" -> {
      use value <- decode.field("v", number_decoder())
      decode.success(Number(value))
    }
    "text" -> {
      use value <- decode.field("v", decode.string)
      decode.success(Text(value))
    }
    "flag" -> {
      use value <- decode.field("v", decode.bool)
      decode.success(Flag(value))
    }
    _ -> decode.failure(Flag(False), "Fact")
  }
}

/// A JSON number as a float, whether it was written with a decimal point
/// or not.
pub fn number_decoder() -> Decoder(Float) {
  decode.one_of(decode.float, [decode.map(decode.int, int.to_float)])
}

/// A list of `{"name", "fact"}`.
pub fn facts(facts: Facts) -> Json {
  json.array(facts, fn(named) {
    json.object([#("name", json.string(named.0)), #("fact", fact(named.1))])
  })
}

/// Decodes `Facts` written by `facts`.
pub fn facts_decoder() -> Decoder(Facts) {
  decode.list({
    use name <- decode.field("name", decode.string)
    use fact <- decode.field("fact", fact_decoder())
    decode.success(#(name, fact))
  })
}

// -- Recommendations, verdicts, assessments ------------------------------------------

/// A recommendation, with the output encoded exactly by the point's codec.
pub fn recommendation(
  recommendation: Recommendation(o),
  output: Codec(o),
) -> Result(Value, String) {
  use encoded <- result.map(encode(output, recommendation.output))
  value.Object([
    #("output", encoded),
    #("by", exact.from_json(recommender(recommendation.by))),
    #("explanation", exact.from_json(explanation(recommendation.explanation))),
    #("signals", exact.from_json(facts(recommendation.signals))),
    #("reads", exact.from_json(json.array(recommendation.reads, ref))),
  ])
}

/// Decodes a recommendation written by `recommendation`.
pub fn decode_recommendation(
  raw: Value,
  output: Codec(o),
) -> Result(Recommendation(o), String) {
  use members <- result.try(exact.members(raw))
  use item <- result.try(
    exact.output_member(members, "output", decode(output, _)),
  )
  use by <- result.try(exact.member(members, "by", recommender_decoder()))
  use explanation <- result.try(exact.member(
    members,
    "explanation",
    explanation_decoder(),
  ))
  use signals <- result.try(exact.member(members, "signals", facts_decoder()))
  use reads <- result.try(exact.member(
    members,
    "reads",
    decode.list(ref_decoder()),
  ))
  Ok(Recommendation(output: item, by:, explanation:, signals:, reads:))
}

/// `{"category", "note"}`.
pub fn reason(reason: Reason) -> Json {
  json.object([
    #("category", json.string(reason.category)),
    #("note", optional(reason.note, json.string)),
  ])
}

/// Decodes a `Reason` written by `reason`. A missing note is `None`.
pub fn reason_decoder() -> Decoder(Reason) {
  use category <- decode.field("category", decode.string)
  use note <- decode.optional_field(
    "note",
    None,
    decode.optional(decode.string),
  )
  decode.success(Reason(category:, note:))
}

/// Tagged `approve`, `reject` or `correct`, with a corrected output encoded
/// exactly by the point's codec.
pub fn verdict(verdict: Verdict(o), output: Codec(o)) -> Result(Value, String) {
  case verdict {
    Approve -> Ok(exact.tagged("approve", []))
    Reject(reason: why) ->
      Ok(exact.tagged("reject", [#("reason", exact.from_json(reason(why)))]))
    Correct(output: item, reason: why) -> {
      use encoded <- result.map(encode(output, item))
      exact.tagged("correct", [
        #("output", encoded),
        #("reason", exact.from_json(reason(why))),
      ])
    }
  }
}

/// Decodes a verdict written by `verdict`. Only the point's own codec can
/// decode a corrected output.
pub fn decode_verdict(
  raw: Value,
  output: Codec(o),
) -> Result(Verdict(o), String) {
  use members <- result.try(exact.members(raw))
  use tag <- result.try(exact.member(members, "t", decode.string))
  case tag {
    "approve" -> Ok(Approve)
    "reject" -> {
      use why <- result.map(exact.member(members, "reason", reason_decoder()))
      Reject(reason: why)
    }
    "correct" -> {
      use item <- result.try(
        exact.output_member(members, "output", decode(output, _)),
      )
      use why <- result.map(exact.member(members, "reason", reason_decoder()))
      Correct(output: item, reason: why)
    }
    _ -> Error("unknown verdict \"" <> tag <> "\"")
  }
}

/// A verdict as a json_blueprint codec over the forms `verdict` writes, for
/// reading a client's text with `codec.decode_json` and writing it with
/// `codec.encode_json`. Its schema admits any JSON.
pub fn verdict_codec(output: Codec(o)) -> blueprint.Codec(Verdict(o)) {
  blueprint.try_map(
    blueprint.value(),
    decode: decode_verdict(_, output),
    encode: verdict(_, output),
    placeholder: Approve,
  )
}

/// The names of the verdicts a declaration allows, as a card lists them.
pub fn verdicts(allowed: Verdicts) -> Json {
  json.array(
    case allowed {
      ApproveOrReject -> ["approve", "reject"]
      ApproveRejectOrCorrect -> ["approve", "reject", "correct"]
    },
    json.string,
  )
}

fn finding(finding: Finding(o), output: Codec(o)) -> Result(Value, String) {
  case finding {
    Right -> Ok(exact.tagged("right", []))
    Wrong(truth: None) -> Ok(exact.tagged("wrong", [#("truth", value.Null)]))
    Wrong(truth: Some(truth)) -> {
      use encoded <- result.map(encode(output, truth))
      exact.tagged("wrong", [#("truth", encoded)])
    }
  }
}

fn decode_finding(raw: Value, output: Codec(o)) -> Result(Finding(o), String) {
  use members <- result.try(exact.members(raw))
  use tag <- result.try(exact.member(members, "t", decode.string))
  case tag, list.key_find(members, "truth") {
    "right", _ -> Ok(Right)
    "wrong", Ok(value.Null) | "wrong", Error(Nil) -> Ok(Wrong(truth: None))
    "wrong", Ok(truth) ->
      decode(output, truth)
      |> result.map(fn(truth) { Wrong(truth: Some(truth)) })
    _, _ -> Error("unknown finding \"" <> tag <> "\"")
  }
}

/// `{"finding", "evidence", "source", "known_at"}`, with a true output
/// encoded exactly by the point's codec.
pub fn assessment(
  assessment: Assessment(o),
  output: Codec(o),
) -> Result(Value, String) {
  use found <- result.map(finding(assessment.finding, output))
  value.Object([
    #("finding", found),
    #("evidence", exact.from_json(ref(assessment.evidence))),
    #("source", value.String(assessment.source)),
    #("known_at", exact.from_json(time(assessment.known_at))),
  ])
}

/// Decodes an assessment written by `assessment`.
pub fn decode_assessment(
  raw: Value,
  output: Codec(o),
) -> Result(Assessment(o), String) {
  use members <- result.try(exact.members(raw))
  use finding <- result.try(
    exact.output_member(members, "finding", decode_finding(_, output)),
  )
  use evidence <- result.try(exact.member(members, "evidence", ref_decoder()))
  use source <- result.try(exact.member(members, "source", decode.string))
  use known_at <- result.try(exact.member(members, "known_at", time_decoder()))
  Ok(Assessment(finding:, evidence:, source:, known_at:))
}

/// Tagged `deadline` or `superseded`.
pub fn expiry_cause(cause: ExpiryCause) -> Json {
  case cause {
    DeadlinePassed -> tagged("deadline", [])
    Superseded(event:) -> tagged("superseded", [#("event", json.string(event))])
  }
}

/// Decodes an `ExpiryCause` written by `expiry_cause`.
pub fn expiry_cause_decoder() -> Decoder(ExpiryCause) {
  use tag <- decode.field("t", decode.string)
  case tag {
    "deadline" -> decode.success(DeadlinePassed)
    "superseded" -> {
      use event <- decode.field("event", decode.string)
      decode.success(Superseded(event:))
    }
    _ -> decode.failure(DeadlinePassed, "ExpiryCause")
  }
}

/// Tagged `performed`, `not_performed` or `uncertain`.
pub fn effect(effect: Effect) -> Json {
  case effect {
    Performed(receipt:) -> tagged("performed", [#("receipt", ref(receipt))])
    NotPerformed(reason:) ->
      tagged("not_performed", [#("reason", json.string(reason))])
    Uncertain(reason:) ->
      tagged("uncertain", [#("reason", json.string(reason))])
  }
}

/// Decodes an `Effect` written by `effect`.
pub fn effect_decoder() -> Decoder(Effect) {
  use tag <- decode.field("t", decode.string)
  case tag {
    "performed" -> {
      use receipt <- decode.field("receipt", ref_decoder())
      decode.success(Performed(receipt:))
    }
    "not_performed" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(NotPerformed(reason:))
    }
    "uncertain" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(Uncertain(reason:))
    }
    _ -> decode.failure(Uncertain(""), "Effect")
  }
}

/// `{"subject", "holds"}`.
pub fn validator(validator: Validator) -> Json {
  json.object([
    #("subject", json.string(validator.subject)),
    #("holds", json.array(validator.holds, json.string)),
  ])
}

/// Decodes a `Validator` written by `validator`.
pub fn validator_decoder() -> Decoder(Validator) {
  use subject <- decode.field("subject", decode.string)
  use holds <- decode.field("holds", decode.list(decode.string))
  decode.success(Validator(subject:, holds:))
}
