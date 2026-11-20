//// The card as a document: what a person, or another system, is shown.
//// Everything on it is resolved from the record: the context the model
//// started from, what the model read beyond it, and what validators opened
//// since, each with the content as it was read and, when it has changed
//// since, the newer revision.
////
//// `context` runs a point's `Reader` against the record alone, so the card
//// gets the same typed value the model got, and a reader that asks for
//// more than the model read is told `NotRecorded`.
////
//// A view crosses a process boundary as JSON (`to_json`, format
//// `"decision-card.v1"`), with the allowed verdicts and, when the point's
//// codec carries one, the output's JSON Schema. A verdict returns as JSON
//// that only the point's own codec decodes (`verdict`).
////
//// `codec` builds the document's json_blueprint codec around the point's
//// codec. A copy of it to another process holds about twelve copies of the
//// point's codec, so build it where a document is encoded or decoded and
//// do not keep it in state that is sent between processes.
////
//// ```gleam
//// import decisions/view
////
//// let document = view.of(card, content: recorded_content)
//// let assert Ok(brief) =
////   view.context(decisions.shown(card), with: read_brief, content: recorded_content)
//// ```
////
//// Target-independent: builds for Erlang and JavaScript.

import decisions.{type Card}
import decisions/model.{type Failure, type Reader, type Resolver}
import decisions/occurrence.{type Occurrence}
import decisions/policy
import decisions/vocabulary.{
  type Recommendation, type Ref, type Subject, type Verdict, type Verdicts,
  Recommendation, Ref, Rules, Subject,
}
import decisions/wire.{type Codec}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import json/blueprint/codec as blueprint
import json/blueprint/value

/// One input, with its content as it was read. `now` is the newer
/// revision when the input changed after the model read it.
pub type Item {
  Item(ref: Ref, content: Result(String, Failure), now: Option(Ref))
}

/// Who has approved the output that stands, and what each way of
/// accepting it still needs. The occurrence is accepted when any one
/// alternative has as many approvals as it needs. Both lists are empty
/// once it no longer waits.
pub type Approvals {
  Approvals(by: List(String), alternatives: List(Alternative))
}

/// One way the occurrence can be accepted: `need` approvals from holders of
/// any of `sets`, of which it has `have`. Under `Either` there is one per
/// alternative; under `Several(count, of)` one, needing `count`.
pub type Alternative {
  Alternative(sets: List(String), have: Int, need: Int)
}

/// What a card shows.
pub type View(output) {
  View(
    occurrence: String,
    /// The entry that showed the card. With `occurrence` it is the ticket a
    /// verdict comes back with.
    seen: Int,
    point: String,
    subject: Subject,
    status: String,
    /// The decision sets it waits for.
    waiting_for: List(String),
    approvals: Approvals,
    /// The context the model started from.
    pushed: List(Item),
    /// What the model received beyond it.
    pulled: List(Item),
    /// What validators opened beyond the card, as `#(read, item)`.
    opened: List(#(String, Item)),
    /// What validators entered, as `#(by, note)`.
    notes: List(#(String, String)),
    /// What the recommender proposed.
    recommendation: Recommendation(output),
    /// The output a verdict on this card would be about: the
    /// recommendation's, or the latest correction's. An approval approves
    /// this output.
    standing: output,
    allowed: Verdicts,
  )
}

/// What a card shows. `content` resolves a reference to the evidence it
/// names: the content as it was read, whatever the world says now. The
/// point's name and allowed verdicts come from the card, so a view can
/// never be built against the wrong point.
pub fn of(card: Card(o), content content: Resolver) -> View(o) {
  let shown = decisions.shown(card)
  let drift = occurrence.drift(shown)
  let item = fn(ref: Ref) {
    Item(
      ref:,
      content: content(ref),
      now: list.find(drift, fn(newer) {
        newer.kind == ref.kind && newer.id == ref.id
      })
        |> option.from_result,
    )
  }
  let #(standing, approved) = occurrence.standing(shown)
  let #(waiting_for, approvals) = case shown.status {
    occurrence.Awaiting(eligible:) -> #(
      policy.sets(eligible),
      Approvals(by: approved, alternatives: alternatives(shown, eligible)),
    )
    _ -> #([], Approvals(by: [], alternatives: []))
  }
  View(
    occurrence: shown.id,
    seen: decisions.ticket(card).seen,
    point: shown.point,
    subject: shown.subject,
    status: occurrence.status_name(shown.status),
    waiting_for:,
    approvals:,
    pushed: list.map(shown.context.refs, item),
    pulled: list.map(shown.recommendation.reads, item),
    opened: list.map(occurrence.expansions(shown), fn(expansion) {
      #(expansion.0, item(expansion.1))
    }),
    notes: occurrence.notes(shown),
    recommendation: shown.recommendation,
    standing:,
    allowed: decisions.allowed(card),
  )
}

/// The context as the model received it, as the point's own type. The
/// reader runs against the record alone: the context references and the
/// reads on the recommendation, resolved by `content`. It returns what the
/// model's reader returned, or `NotRecorded` for a read the model never
/// received.
pub fn context(
  shown: Occurrence(o),
  with reader: Reader(context),
  content content: Resolver,
) -> Result(context, Failure) {
  let resolved = fn(refs: List(Ref)) {
    list.try_map(refs, fn(ref) {
      content(ref) |> result.map(fn(body) { #(ref, body) })
    })
  }
  use pushed <- result.try(resolved(shown.context.refs))
  use pulled <- result.try(resolved(shown.recommendation.reads))
  reader(shown.context, model.recorded(context: pushed, reads: pulled))
}

// -- Across a process boundary ---------------------------------------------------

/// The view as a `"decision-card.v1"` document. A client needs none of the
/// point's code to show it, approve or reject it; with `output_schema` it
/// can also build a correction form. It is exactly what `codec` encodes,
/// so a client can decode it typed and check it against `codec`'s schema.
/// An error means the codec cannot encode an output the card holds.
pub fn to_json(view: View(o), output: Codec(o)) -> Result(Json, String) {
  blueprint.to_json(codec(output), view)
  |> result.map_error(blueprint.describe_encode_error)
}

/// The `"decision-card.v1"` document as a `json_blueprint` codec, given the
/// point's output codec: encode a view to serve a card with a schema (for
/// example as a typed MCP tool result), decode one on the client side.
///
/// The document holds the occurrence and its ticket fields (`occurrence`,
/// `seen`), `point`, `subject`, `status`, `waiting_for`, `approvals`
/// (`by`, and `alternatives`, each with `sets`, `have` and `need`), the inputs as read (`context`, `model_read`,
/// `opened`, each item with `ref`, `content`, `unavailable` and
/// `changed_to`), `notes`, the `recommendation`, the `standing_output`,
/// the allowed `verdicts`, and the output's `output_schema` (null for a
/// `plain` codec). The recommender, its explanation and its signals keep
/// the JSON form of `decisions/wire`.
///
/// Decoding is faithful except for an input that could not be resolved:
/// it comes back as `ReadFailed` with the reason's text, whatever failure
/// it was.
pub fn codec(output: Codec(o)) -> blueprint.Codec(View(o)) {
  use _format <- blueprint.field(
    "format",
    blueprint.try_map(
      blueprint.string(),
      decode: fn(format) {
        case format == "decision-card.v1" {
          True -> Ok(Nil)
          False -> Error("not a decision-card.v1 document")
        }
      },
      encode: fn(_) { Ok("decision-card.v1") },
      placeholder: Nil,
    ),
    get: fn(_: View(o)) { Nil },
  )
  use occurrence <- blueprint.field(
    "occurrence",
    blueprint.string(),
    get: fn(v: View(o)) { v.occurrence },
  )
  use seen <- blueprint.field("seen", blueprint.int(), get: fn(v: View(o)) {
    v.seen
  })
  use point <- blueprint.field("point", blueprint.string(), get: fn(v: View(o)) {
    v.point
  })
  use subject <- blueprint.field(
    "subject",
    subject_codec(),
    get: fn(v: View(o)) { v.subject },
  )
  use status <- blueprint.field(
    "status",
    blueprint.string(),
    get: fn(v: View(o)) { v.status },
  )
  use waiting_for <- blueprint.field(
    "waiting_for",
    blueprint.list(blueprint.string()),
    get: fn(v: View(o)) { v.waiting_for },
  )
  use approvals <- blueprint.field(
    "approvals",
    approvals_codec(),
    get: fn(v: View(o)) { v.approvals },
  )
  use pushed <- blueprint.field(
    "context",
    blueprint.list(item_codec()),
    get: fn(v: View(o)) { v.pushed },
  )
  use pulled <- blueprint.field(
    "model_read",
    blueprint.list(item_codec()),
    get: fn(v: View(o)) { v.pulled },
  )
  use opened <- blueprint.field(
    "opened",
    blueprint.list({
      use read <- blueprint.field(
        "read",
        blueprint.string(),
        get: fn(pair: #(String, Item)) { pair.0 },
      )
      use item <- blueprint.field(
        "item",
        item_codec(),
        get: fn(pair: #(String, Item)) { pair.1 },
      )
      blueprint.success(#(read, item))
    }),
    get: fn(v: View(o)) { v.opened },
  )
  use notes <- blueprint.field(
    "notes",
    blueprint.list({
      use by <- blueprint.field(
        "by",
        blueprint.string(),
        get: fn(pair: #(String, String)) { pair.0 },
      )
      use note <- blueprint.field(
        "note",
        blueprint.string(),
        get: fn(pair: #(String, String)) { pair.1 },
      )
      blueprint.success(#(by, note))
    }),
    get: fn(v: View(o)) { v.notes },
  )
  use recommendation <- blueprint.field(
    "recommendation",
    recommendation_codec(wire.blueprint(output)),
    get: fn(v: View(o)) { v.recommendation },
  )
  use standing <- blueprint.field(
    "standing_output",
    wire.blueprint(output),
    get: fn(v: View(o)) { v.standing },
  )
  use allowed <- blueprint.field(
    "verdicts",
    verdicts_codec(),
    get: fn(v: View(o)) { v.allowed },
  )
  use _schema <- blueprint.field(
    "output_schema",
    blueprint.nullable(blueprint.value()),
    get: fn(_: View(o)) { output_schema(output) },
  )
  blueprint.success(View(
    occurrence:,
    seen:,
    point:,
    subject:,
    status:,
    waiting_for:,
    approvals:,
    pushed:,
    pulled:,
    opened:,
    notes:,
    recommendation:,
    standing:,
    allowed:,
  ))
}

/// The output's schema as a json_blueprint value, rendered when a document
/// is encoded rather than held by the card codec.
fn output_schema(output: Codec(o)) -> Option(value.Value) {
  use schema <- option.map(wire.schema(output))
  let assert Ok(parsed) =
    value.parse(json.to_string(schema), value.default_limits())
  parsed
}

fn ref_codec() -> blueprint.Codec(Ref) {
  use kind <- blueprint.field("kind", blueprint.string(), get: fn(r: Ref) {
    r.kind
  })
  use id <- blueprint.field("id", blueprint.string(), get: fn(r: Ref) { r.id })
  use revision <- blueprint.field(
    "revision",
    blueprint.string(),
    get: fn(r: Ref) { r.revision },
  )
  blueprint.success(Ref(kind:, id:, revision:))
}

fn subject_codec() -> blueprint.Codec(Subject) {
  use kind <- blueprint.field("kind", blueprint.string(), get: fn(s: Subject) {
    s.kind
  })
  use id <- blueprint.field("id", blueprint.string(), get: fn(s: Subject) {
    s.id
  })
  blueprint.success(Subject(kind:, id:))
}

fn alternatives(
  shown: Occurrence(o),
  eligible: policy.Eligible,
) -> List(Alternative) {
  let given = occurrence.approvals(shown)
  let have = fn(admitted_by) {
    list.count(given, fn(pair) {
      occurrence.admits(shown, admitted_by, pair.0, pair.1)
    })
  }
  case eligible {
    policy.AnyoneHolding(set:) | policy.SomeoneElseHolding(set:) -> [
      Alternative(sets: [set], have: have(eligible), need: 1),
    ]
    policy.Either(of) -> list.flat_map(of, alternatives(shown, _))
    policy.Several(count:, of:) -> [
      Alternative(sets: policy.sets(of), have: have(of), need: count),
    ]
  }
}

fn approvals_codec() -> blueprint.Codec(Approvals) {
  use by <- blueprint.field(
    "by",
    blueprint.list(blueprint.string()),
    get: fn(a: Approvals) { a.by },
  )
  use alternatives <- blueprint.field(
    "alternatives",
    blueprint.list({
      use sets <- blueprint.field(
        "sets",
        blueprint.list(blueprint.string()),
        get: fn(a: Alternative) { a.sets },
      )
      use have <- blueprint.field(
        "have",
        blueprint.int(),
        get: fn(a: Alternative) { a.have },
      )
      use need <- blueprint.field(
        "need",
        blueprint.int(),
        get: fn(a: Alternative) { a.need },
      )
      blueprint.success(Alternative(sets:, have:, need:))
    }),
    get: fn(a: Approvals) { a.alternatives },
  )
  blueprint.success(Approvals(by:, alternatives:))
}

fn item_codec() -> blueprint.Codec(Item) {
  use ref <- blueprint.field("ref", ref_codec(), get: fn(i: Item) { i.ref })
  use content <- blueprint.field(
    "content",
    blueprint.nullable(blueprint.string()),
    get: fn(i: Item) { option.from_result(i.content) },
  )
  use unavailable <- blueprint.field(
    "unavailable",
    blueprint.nullable(blueprint.string()),
    get: fn(i: Item) {
      case i.content {
        Ok(_) -> None
        Error(failure) -> Some(model.describe(failure))
      }
    },
  )
  use now <- blueprint.field(
    "changed_to",
    blueprint.nullable(ref_codec()),
    get: fn(i: Item) { i.now },
  )
  blueprint.success(Item(
    ref:,
    content: case content {
      Some(body) -> Ok(body)
      None ->
        Error(model.ReadFailed(
          read: ref.kind,
          argument: ref.id,
          reason: option.unwrap(unavailable, ""),
        ))
    },
    now:,
  ))
}

fn recommendation_codec(
  output: blueprint.Codec(o),
) -> blueprint.Codec(Recommendation(o)) {
  use item <- blueprint.field("output", output, get: fn(r: Recommendation(o)) {
    r.output
  })
  use by <- blueprint.field(
    "by",
    passthrough(wire.recommender, wire.recommender_decoder(), Rules("", "")),
    get: fn(r: Recommendation(o)) { r.by },
  )
  use explanation <- blueprint.field(
    "explanation",
    passthrough(wire.explanation, wire.explanation_decoder(), vocabulary.OwnAct),
    get: fn(r: Recommendation(o)) { r.explanation },
  )
  use signals <- blueprint.field(
    "signals",
    passthrough(wire.facts, wire.facts_decoder(), []),
    get: fn(r: Recommendation(o)) { r.signals },
  )
  use reads <- blueprint.field(
    "reads",
    blueprint.list(ref_codec()),
    get: fn(r: Recommendation(o)) { r.reads },
  )
  blueprint.success(Recommendation(
    output: item,
    by:,
    explanation:,
    signals:,
    reads:,
  ))
}

fn verdicts_codec() -> blueprint.Codec(Verdicts) {
  blueprint.try_map(
    blueprint.list(blueprint.string()),
    decode: fn(names) {
      case names {
        ["approve", "reject"] -> Ok(vocabulary.ApproveOrReject)
        ["approve", "reject", "correct"] ->
          Ok(vocabulary.ApproveRejectOrCorrect)
        _ -> Error("unknown verdicts")
      }
    },
    encode: fn(allowed) {
      Ok(case allowed {
        vocabulary.ApproveOrReject -> ["approve", "reject"]
        vocabulary.ApproveRejectOrCorrect -> ["approve", "reject", "correct"]
      })
    },
    placeholder: vocabulary.ApproveOrReject,
  )
}

/// A value kept in its `decisions/wire` JSON form inside the document.
fn passthrough(
  encode: fn(a) -> Json,
  decoder: decode.Decoder(a),
  placeholder: a,
) -> blueprint.Codec(a) {
  blueprint.try_map(
    blueprint.value(),
    decode: fn(raw) {
      json.parse(value.to_string(raw), decoder)
      |> result.replace_error("does not decode")
    },
    encode: fn(item) {
      value.parse(json.to_string(encode(item)), value.default_limits())
      |> result.replace_error("does not encode")
    },
    placeholder:,
  )
}

/// A verdict that arrived as JSON text, decoded with the point's codec. A
/// correction whose output is not this point's output does not decode.
pub fn verdict(
  text: String,
  output: Codec(o),
) -> Result(Verdict(o), json.DecodeError) {
  json.parse(text, wire.verdict_decoder(output))
}

/// A verdict as JSON, as a client sends it back.
pub fn verdict_to_json(
  verdict: Verdict(o),
  output: Codec(o),
) -> Result(Json, String) {
  wire.verdict(verdict, output)
}

/// The ticket fields of a card document, read back by a client.
pub fn ticket_decoder() -> decode.Decoder(decisions.Ticket) {
  use occurrence <- decode.field("occurrence", decode.string)
  use seen <- decode.field("seen", decode.int)
  decode.success(decisions.Ticket(occurrence:, seen:))
}
