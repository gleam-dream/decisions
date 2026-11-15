//// A model is a function of a context and the sources it may read. It has
//// no other way to the world that `decisions` hands out, so the same
//// function runs in production, where sources capture what they read, and
//// under replay, where the record answers.
////
//// `run` is the only way to call a model. It puts the reads the model
//// received on its recommendation, so the record says what the model had:
////
//// - A model built with `new`, `over` or `cascade` is **observed**: every
////   read that `Sources.read` answered while the model ran is recorded.
////   This is right for a model that uses every answer it asks for, such as
////   one provider call or a rule.
//// - A model built with `reporting` **reports** what it received in its
////   recommendation's `reads`, and that report is believed. An agent loop
////   whose tool can read and then fail uses this, so that a read the model
////   never received is never on the record.
////
//// `run` also contains a model that raises: the caller gets
//// `Error(Raised(..))`, nothing the run set up is left behind, and a read
//// made after the model returned answers without being recorded.
////
//// ```gleam
//// import decisions/model
////
//// let accountant =
////   model.over(read_brief, fn(brief) { Ok(recommend_code(brief)) })
//// let assert Ok(recommendation) = model.run(accountant, context, sources)
//// ```
////
//// `capture` stores what an outside system returned as evidence before the
//// model sees it, which is what makes a decision replayable without that
//// system.
////
//// Target-independent: builds for Erlang and JavaScript, with a small
//// foreign function on each for `run`.

import decisions/vocabulary.{
  type Manifest, type Recommendation, type Ref, Recommendation, Ref,
}
import decisions/wire
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}

/// Why a model has no recommendation. A caller decides on a retry from the
/// variant, never from text; `retryable` says which ones a retry can help.
pub type Failure {
  /// The record holds no answer for this read or reference. Under replay
  /// the example is unanswerable; a retry cannot help.
  NotRecorded(read: String, argument: String)
  /// A source failed to answer a read or resolve a reference. A retry may
  /// help.
  ReadFailed(read: String, argument: String, reason: String)
  /// The model did not answer within its deadline. A retry may help.
  Deadline(after: Duration)
  /// The model raised. A retry may help.
  Raised(reason: String)
  /// The model's provider could not be reached or answered with an error:
  /// a transport failure, a timeout at the provider, a 5xx. A retry may
  /// help.
  ProviderFailed(provider: String, reason: String)
  /// The model answered with something that does not decode as the
  /// output. A retry may help.
  Undecodable(reason: String)
  /// The model declined to recommend, or no stage of a cascade answered. A
  /// retry with the same context cannot help.
  Declined(reason: String)
}

/// Whether trying the same model on the same context again can give a
/// different answer.
pub fn retryable(failure: Failure) -> Bool {
  case failure {
    ReadFailed(..)
    | ProviderFailed(..)
    | Deadline(_)
    | Raised(_)
    | Undecodable(_) -> True
    NotRecorded(..) | Declined(_) -> False
  }
}

/// The failure as one line of text, for a log or an operator.
pub fn describe(failure: Failure) -> String {
  case failure {
    NotRecorded(read:, argument:) ->
      "not recorded: " <> read <> "(" <> argument <> ")"
    ReadFailed(read:, argument:, reason:) ->
      "read " <> read <> "(" <> argument <> ") failed: " <> reason
    Deadline(after:) ->
      "no answer within "
      <> int.to_string(duration.to_milliseconds(after))
      <> " ms"
    Raised(reason:) -> "the model raised: " <> reason
    ProviderFailed(provider:, reason:) ->
      "the provider " <> provider <> " failed: " <> reason
    Undecodable(reason:) -> "the answer does not decode: " <> reason
    Declined(reason:) -> "the model declined: " <> reason
  }
}

/// How a reference is resolved to the content it names, as it was read:
/// from the store's evidence or the application's immutable data. The card
/// (`decisions/view`) and the export (`decisions/learning.Archive`) take
/// the same type. A reference the source does not hold is `NotRecorded`.
pub type Resolver =
  fn(Ref) -> Result(String, Failure)

/// What a read returned, and the reference to the evidence that holds it.
pub type Captured {
  Captured(ref: Ref, body: String)
}

/// Everything a model may read.
pub type Sources {
  Sources(
    /// The content of a reference in the context.
    resolve: fn(Ref) -> Result(String, Failure),
    /// A named read beyond the context, with one argument. It returns the
    /// content with the reference to the evidence that holds it.
    read: fn(String, String) -> Result(Captured, Failure),
  )
}

type Counting {
  Observed
  Reported
}

/// A rule, a classifier, one provider call, an agent, or a cascade of them.
/// Call one with `run`.
pub opaque type Model(output) {
  Model(
    counting: Counting,
    call: fn(Manifest, Sources) -> Result(Recommendation(output), Failure),
  )
}

/// An observed model. The reads it receives through `Sources.read` are
/// recorded by `run`; any reads the recommendation already names are kept
/// beside them.
pub fn new(
  call: fn(Manifest, Sources) -> Result(Recommendation(output), Failure),
) -> Model(output) {
  Model(counting: Observed, call:)
}

/// A model that reports the reads it received in its recommendation's
/// `reads`. `run` believes the report and records nothing it observed.
pub fn reporting(
  call: fn(Manifest, Sources) -> Result(Recommendation(output), Failure),
) -> Model(output) {
  Model(counting: Reported, call:)
}

/// One step of a cascade: it recommends, or abstains with `None`.
pub type Stage(output) =
  fn(Manifest, Sources) -> Result(Option(Recommendation(output)), Failure)

/// A model whose first answering stage recommends. That stage's own
/// recommender and explanation are kept, so the record shows which stage
/// answered, and only the reads that stage received are recorded: a stage
/// that abstained contributes none. When no stage answers the failure is
/// `Declined`.
pub fn cascade(stages: List(Stage(output))) -> Model(output) {
  reporting(fn(context, sources) { first(stages, context, sources) })
}

fn first(
  stages: List(Stage(output)),
  context: Manifest,
  sources: Sources,
) -> Result(Recommendation(output), Failure) {
  case stages {
    [] -> Error(Declined("no stage of the cascade answered"))
    [stage, ..rest] ->
      case observing(sources, fn(observed) { stage(context, observed) }) {
        Error(failure) -> Error(failure)
        Ok(#(Error(failure), _)) -> Error(failure)
        Ok(#(Ok(None), _)) -> first(rest, context, sources)
        Ok(#(Ok(Some(recommendation)), reads)) ->
          Ok(with_reads(recommendation, reads))
      }
  }
}

/// How a point reads its context into a value of its own type. The same
/// function serves the model (through `over`), the card
/// (`decisions/view.context`), the export and a replay, so all of them
/// receive the same value.
pub type Reader(context) =
  fn(Manifest, Sources) -> Result(context, Failure)

/// An observed model that decides from a typed context read by `reader`.
pub fn over(
  reader: Reader(context),
  decide: fn(context) -> Result(Recommendation(output), Failure),
) -> Model(output) {
  new(fn(manifest, sources) { result.try(reader(manifest, sources), decide) })
}

/// A reporting model that decides from a typed context: the reads
/// `reader` makes are observed (a reader uses every answer it asks for),
/// and `decide` reports the reads its own loop received in its
/// recommendation's `reads`. Both are recorded, and nothing else. This is
/// the shape of an agent whose tools can read and then fail.
pub fn over_reporting(
  reader: Reader(context),
  decide: fn(context) -> Result(Recommendation(output), Failure),
) -> Model(output) {
  reporting(fn(manifest, sources) {
    case observing(sources, fn(observed) { reader(manifest, observed) }) {
      Error(failure) -> Error(failure)
      Ok(#(Error(failure), _)) -> Error(failure)
      Ok(#(Ok(context), read)) ->
        decide(context)
        |> result.map(fn(recommendation) {
          Recommendation(
            ..recommendation,
            reads: list.unique(list.append(read, recommendation.reads)),
          )
        })
    }
  })
}

/// Run a model on a context and put the reads it received on its
/// recommendation. A model that raises gives `Error(Raised(reason))`.
pub fn run(
  model: Model(output),
  context: Manifest,
  sources: Sources,
) -> Result(Recommendation(output), Failure) {
  case observing(sources, fn(observed) { model.call(context, observed) }) {
    Error(failure) -> Error(failure)
    Ok(#(Error(failure), _)) -> Error(failure)
    Ok(#(Ok(recommendation), observed)) ->
      Ok(case model.counting {
        Reported -> recommendation
        Observed -> with_reads(recommendation, observed)
      })
  }
}

fn with_reads(
  recommendation: Recommendation(output),
  reads: List(Ref),
) -> Recommendation(output) {
  Recommendation(
    ..recommendation,
    reads: list.unique(list.append(recommendation.reads, reads)),
  )
}

/// Run `body` with sources that note every read they answer, and return
/// what it returned with those reads. A raise becomes `Raised`.
fn observing(
  sources: Sources,
  body: fn(Sources) -> a,
) -> Result(#(a, List(Ref)), Failure) {
  with_cell(fn(cell) {
    body(
      Sources(resolve: sources.resolve, read: fn(name, argument) {
        use captured <- result.map(sources.read(name, argument))
        push(cell, captured.ref)
        captured
      }),
    )
  })
  |> result.map_error(Raised)
}

/// Sources that answer from a record and from nothing else. A reference or
/// a read the record does not hold is `NotRecorded`. When the record holds
/// several reads of one name and argument, the last one answers: it is the
/// latest the model received.
pub fn recorded(
  context context: List(#(Ref, String)),
  reads reads: List(#(Ref, String)),
) -> Sources {
  Sources(
    resolve: fn(ref) {
      list.key_find(context, ref)
      |> result.replace_error(NotRecorded(read: ref.kind, argument: ref.id))
    },
    read: fn(name, argument) {
      list.reverse(reads)
      |> list.find(fn(pair) {
        { pair.0 }.kind == name && { pair.0 }.id == argument
      })
      |> result.map(fn(pair) { Captured(ref: pair.0, body: pair.1) })
      |> result.replace_error(NotRecorded(read: name, argument:))
    },
  )
}

// -- Evidence ---------------------------------------------------------------------

/// Where captured responses are kept, in the caller's transaction. Evidence
/// is never changed: a reference names one content.
pub type Evidence(tx) {
  Evidence(
    put: fn(tx, Ref, String) -> Result(Nil, String),
    get: fn(tx, Ref) -> Result(String, String),
  )
}

/// Read `request` from `source` through `fetch`, store the response as
/// evidence under a reference that names its content, and only then
/// return it. A failed fetch stores nothing.
pub fn capture(
  evidence: Evidence(tx),
  tx: tx,
  source source: String,
  request request: String,
  fetch fetch: fn() -> Result(String, String),
) -> Result(Captured, String) {
  use body <- result.try(fetch())
  let ref = Ref(kind: source, id: request, revision: digest(body))
  use Nil <- result.try(evidence.put(tx, ref, body))
  Ok(Captured(ref:, body:))
}

/// The revision `capture` gives a content: the SHA-256 of its text, in
/// lowercase hexadecimal. Equal bodies give equal revisions and different
/// bodies, in practice, different ones. A `latest` function for drift reads
/// the content as it is now and returns `digest` of it, so it follows the
/// same rule as the capture.
pub fn digest(body: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(body))
  |> bit_array.base16_encode
  |> string.lowercase
}

/// A model as one stage of a cascade: it answers with its recommendation,
/// a model that declines (`Declined`) abstains, and any other failure
/// stops the cascade. Its reads are observed as the model's own are.
pub fn stage(model: Model(output)) -> Stage(output) {
  fn(context, sources) {
    case run(model, context, sources) {
      Ok(recommendation) -> Ok(Some(recommendation))
      Error(Declined(_)) -> Ok(None)
      Error(failure) -> Error(failure)
    }
  }
}

type Cell

@external(erlang, "decisions_model_ffi", "with_cell")
@external(javascript, "../decisions_model_ffi.mjs", "with_cell")
fn with_cell(body: fn(Cell) -> a) -> Result(#(a, List(Ref)), String)

@external(erlang, "decisions_model_ffi", "push")
@external(javascript, "../decisions_model_ffi.mjs", "push")
fn push(cell: Cell, ref: Ref) -> Nil

// -- As data ----------------------------------------------------------------------

/// A failure as JSON, as a failed attempt's entry keeps it.
pub fn failure_to_json(failure: Failure) -> Json {
  case failure {
    NotRecorded(read:, argument:) ->
      wire.tagged("not_recorded", [
        #("read", json.string(read)),
        #("argument", json.string(argument)),
      ])
    ReadFailed(read:, argument:, reason:) ->
      wire.tagged("read_failed", [
        #("read", json.string(read)),
        #("argument", json.string(argument)),
        #("reason", json.string(reason)),
      ])
    Deadline(after:) ->
      wire.tagged("deadline", [
        #("after_ms", json.int(duration.to_milliseconds(after))),
      ])
    Raised(reason:) -> wire.tagged("raised", [#("reason", json.string(reason))])
    ProviderFailed(provider:, reason:) ->
      wire.tagged("provider_failed", [
        #("provider", json.string(provider)),
        #("reason", json.string(reason)),
      ])
    Undecodable(reason:) ->
      wire.tagged("undecodable", [#("reason", json.string(reason))])
    Declined(reason:) ->
      wire.tagged("declined", [#("reason", json.string(reason))])
  }
}

/// Decodes a failure written by `failure_to_json`.
pub fn failure_decoder() -> Decoder(Failure) {
  use tag <- decode.field("t", decode.string)
  case tag {
    "not_recorded" -> {
      use read <- decode.field("read", decode.string)
      use argument <- decode.field("argument", decode.string)
      decode.success(NotRecorded(read:, argument:))
    }
    "read_failed" -> {
      use read <- decode.field("read", decode.string)
      use argument <- decode.field("argument", decode.string)
      use reason <- decode.field("reason", decode.string)
      decode.success(ReadFailed(read:, argument:, reason:))
    }
    "deadline" -> {
      use after <- decode.field("after_ms", decode.int)
      decode.success(Deadline(duration.milliseconds(after)))
    }
    "provider_failed" -> {
      use provider <- decode.field("provider", decode.string)
      use reason <- decode.field("reason", decode.string)
      decode.success(ProviderFailed(provider:, reason:))
    }
    "raised" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(Raised(reason:))
    }
    "undecodable" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(Undecodable(reason:))
    }
    "declined" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(Declined(reason:))
    }
    _ -> decode.failure(Declined(""), "Failure")
  }
}
