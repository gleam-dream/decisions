//// What the record is read for besides queues: agreement and accuracy per
//// recommender version, the export of training examples, and the replay
//// of a candidate model against recorded decisions. Each is a fold over
//// occurrences; none writes, and none needs a store.
////
//// - **Agreement** is how often validators let the recommendation through:
////   an approval agrees; a correction or a rejection does not. An output
////   the policy accepted has no verdict and counts toward no agreement.
//// - **Accuracy** is how often the final output proved right, from
////   assessments.
//// - **Replay** runs a candidate model on self-contained examples. Its
////   whole world is the example: the recorded context and the recorded
////   reads, so it needs no network and calls no gated tool.
////
//// ```gleam
//// import decisions/learning
////
//// let assert Ok(examples) =
////   list.try_map(recorded, learning.example(_, as_of: now, from: archive))
//// let scored = learning.replay(examples, candidate, same: fn(a, b) { a == b })
//// // scored.tally.agreed of scored.tally.judged
//// ```
////
//// Target-independent: builds for Erlang and JavaScript.

import decisions.{type Point}
import decisions/model.{type Failure, type Model, type Resolver}
import decisions/occurrence.{type Occurrence}
import decisions/policy.{type Outcome, type Policy}
import decisions/vocabulary.{
  type Explanation, type Manifest, type Recommendation, type Recommender,
  type Ref, type Verdict, Approve, Correct, Person, Ref, Reject, Right, Wrong,
}
import decisions/wire.{type Codec}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/timestamp.{type Timestamp}

/// Agreement is `agreed` of `judged`, from verdicts and reviews. Accuracy
/// is `right` of `assessed`, from assessments.
pub type Tally {
  Tally(
    agreed: Int,
    judged: Int,
    /// Occurrences people rejected outright: nothing was let through, so
    /// they are not judged, and counted here instead.
    rejected: Int,
    right: Int,
    assessed: Int,
  )
}

/// A tally of nothing.
pub const nothing =
  Tally(agreed: 0, judged: 0, rejected: 0, right: 0, assessed: 0)

/// Agreement and accuracy per recommender version.
///
/// Agreement follows one rule, shared with `replay` so the two figures
/// have the same denominator: an occurrence is **judged** when people let
/// an output through to acceptance (it was accepted, held, released, or
/// accepted and then refused by the tool), and that output is what
/// agreement compares with. Walking its verdicts and then its reviews in
/// order, an approval lets
/// through the output that stands, a correction lets through its own
/// output, and a rejection lets nothing through. A person's own act counts
/// as their judgment of the output they proposed. Each judged occurrence
/// counts once, however many verdicts it has. Here it **agrees** when the
/// output let through is the one recommended; in `replay`, when it is the
/// candidate's output.
///
/// So an occurrence that was rejected, or whose review rejected it, is not
/// judged by either: nothing was let through to compare with. Both count
/// it in `rejected` instead, so neither figure hides it. Not judged and
/// not counted at all: an output the policy accepted with no verdict and
/// no review; a partial quorum that expired (approvals that never reached
/// acceptance are not a judgment); a withdrawn occurrence (the decider
/// took it back during its hold, which says they changed their mind, not
/// what the right output was); and an acceptance a newer event superseded
/// before its release, for the same reason as a withdrawal: the world
/// moved on, which says nothing about whether the output was right. Each assessment counts toward accuracy.
pub fn tally(occurrences: List(Occurrence(o))) -> List(#(Recommender, Tally)) {
  list.fold(occurrences, [], fn(tallies, known) {
    let by = known.recommendation.by
    let so_far = list.key_find(tallies, by) |> result.unwrap(nothing)
    let after_verdicts = case passed(known) {
      None ->
        Tally(..so_far, rejected: so_far.rejected + count(is_rejected(known)))
      Some(output) ->
        Tally(
          ..so_far,
          judged: so_far.judged + 1,
          agreed: so_far.agreed + count(output == known.recommendation.output),
        )
    }
    let after_assessments =
      list.fold(occurrence.assessments(known), after_verdicts, fn(tally, a) {
        case a.finding {
          Right ->
            Tally(..tally, right: tally.right + 1, assessed: tally.assessed + 1)
          Wrong(_) -> Tally(..tally, assessed: tally.assessed + 1)
        }
      })
    list.key_set(tallies, by, after_assessments)
  })
}

/// The tallies of several recommenders added together.
pub fn total(tallies: List(#(a, Tally))) -> Tally {
  list.fold(tallies, nothing, fn(sum, pair) { add(sum, pair.1) })
}

fn add(a: Tally, b: Tally) -> Tally {
  Tally(
    agreed: a.agreed + b.agreed,
    judged: a.judged + b.judged,
    rejected: a.rejected + b.rejected,
    right: a.right + b.right,
    assessed: a.assessed + b.assessed,
  )
}

/// A read a model made, with the evidence it returned.
pub type Read {
  Read(name: String, argument: String, result: Ref)
}

/// Where an example's parts are resolved from at export time.
pub type Archive {
  Archive(
    /// The renderer that built the model's prompt from a context. It fails
    /// for a renderer version it does not have. It sees only the manifest:
    /// when the real prompt was captured as evidence (one provider call's
    /// exact request), name that evidence among the context's references
    /// and return its content here through the same resolver.
    render: fn(Manifest) -> Result(String, String),
    /// Reads retained elsewhere, such as in the run an explanation points
    /// into. Return `[]` when the recommendation's own reads are the whole
    /// story.
    reads: fn(Explanation) -> List(Read),
    /// The content of a reference to immutable data or evidence: the same
    /// resolver a card uses.
    content: Resolver,
  )
}

/// Why an example could not be exported.
pub type ExportError {
  /// The occurrence had not been recommended at the stated time.
  NotYetRecommended
  /// The archive has no renderer for the context.
  RenderFailed(reason: String)
  /// The archive cannot resolve a reference the record names.
  MissingContent(ref: Ref, failure: Failure)
}

/// One training example: an occurrence as it was known at a stated time,
/// with every input resolved. It needs nothing else to be replayed.
pub type Example(output) {
  Example(
    as_of: Timestamp,
    /// The occurrence folded from only the entries up to `as_of`.
    known: Occurrence(output),
    prompt: String,
    context: List(#(Ref, String)),
    reads: List(#(Read, String)),
    /// What validators opened beyond the card, as `#(read, content)`.
    expansions: List(#(String, String)),
  )
}

/// Export an occurrence as it was known at `as_of`, resolving every input
/// once.
pub fn example(
  occurrence: Occurrence(o),
  as_of as_of: Timestamp,
  from archive: Archive,
) -> Result(Example(o), ExportError) {
  use known <- result.try(
    occurrence.as_of(occurrence, as_of)
    |> result.replace_error(NotYetRecommended),
  )
  use prompt <- result.try(
    archive.render(known.context) |> result.map_error(RenderFailed),
  )
  let resolve = fn(ref: Ref) {
    archive.content(ref) |> result.map_error(MissingContent(ref, _))
  }
  use context <- result.try(
    list.try_map(known.context.refs, fn(ref) {
      resolve(ref) |> result.map(fn(content) { #(ref, content) })
    }),
  )
  let on_record =
    list.map(known.recommendation.reads, fn(ref) {
      Read(name: ref.kind, argument: ref.id, result: ref)
    })
  let all_reads =
    list.append(on_record, archive.reads(known.recommendation.explanation))
    |> list.unique
  use reads <- result.try(
    list.try_map(all_reads, fn(read) {
      resolve(read.result) |> result.map(fn(content) { #(read, content) })
    }),
  )
  use expansions <- result.try(
    list.try_map(occurrence.expansions(known), fn(expansion) {
      resolve(expansion.1)
      |> result.map(fn(content) { #(expansion.0, content) })
    }),
  )
  Ok(Example(as_of:, known:, prompt:, context:, reads:, expansions:))
}

/// The example as a versioned `"decision-example.v1"` document, as a
/// durable job appends it to a training lake. An error means the codec
/// cannot encode an output the example carries.
pub fn example_to_json(
  example: Example(o),
  output: Codec(o),
) -> Result(Json, String) {
  let known = example.known
  let pair = fn(name: String, pair: #(String, String)) {
    json.object([
      #(name, json.string(pair.0)),
      #("content", json.string(pair.1)),
    ])
  }
  use recommendation <- result.try(wire.recommendation(
    known.recommendation,
    output,
  ))
  use verdicts <- result.try(
    list.try_map(verdicts(known), fn(verdict) {
      wire.verdict(verdict.1, output)
      |> result.map(fn(encoded) {
        json.object([#("by", json.string(verdict.0)), #("verdict", encoded)])
      })
    }),
  )
  use assessments <- result.try(
    list.try_map(occurrence.assessments(known), wire.assessment(_, output)),
  )
  use final <- result.map(case occurrence.final(known) {
    Some(final) -> wire.encode(output, final)
    None -> Ok(json.null())
  })
  json.object([
    #("format", json.string("decision-example.v1")),
    #("occurrence", json.string(known.id)),
    #("point", json.string(known.point)),
    #("as_of", wire.time(example.as_of)),
    #("renderer", json.string(known.context.renderer)),
    #("prompt", json.string(example.prompt)),
    #(
      "context",
      json.array(example.context, fn(pair) {
        json.object([
          #("ref", wire.ref(pair.0)),
          #("content", json.string(pair.1)),
        ])
      }),
    ),
    #(
      "reads",
      json.array(example.reads, fn(pair) {
        let read: Read = pair.0
        json.object([
          #("name", json.string(read.name)),
          #("argument", json.string(read.argument)),
          #("result", wire.ref(read.result)),
          #("content", json.string(pair.1)),
        ])
      }),
    ),
    #("recommendation", recommendation),
    #("policy_version", wire.optional(known.policy_version, json.int)),
    #("expansions", json.array(example.expansions, pair("read", _))),
    #("notes", json.array(occurrence.notes(known), pair("by", _))),
    #("verdicts", json.preprocessed_array(verdicts)),
    #("assessments", json.preprocessed_array(assessments)),
    #("final", final),
  ])
}

fn verdicts(known: Occurrence(o)) -> List(#(String, Verdict(o))) {
  list.append(occurrence.verdicts(known), occurrence.reviews(known))
}

/// What a candidate model would have scored on recorded occurrences.
pub type Replay {
  Replay(
    tally: Tally,
    /// Occurrences the candidate could not answer, as
    /// `#(occurrence, failure)`: a read the record does not hold, for one.
    unanswered: List(#(String, Failure)),
  )
}

/// Run `candidate` over examples through `decisions/model.run`. Its whole
/// world is each example. It calls no gated tool, writes no record, and
/// has no path to a network that `decisions` hands it. A candidate that
/// raises is reported as unanswered, not as a crash.
///
/// What is judged follows the rule `tally` states, so for the same
/// occurrences `replay(..).tally.judged` equals the recorded tally's
/// `judged`: an occurrence is judged when people let an output through,
/// and the candidate agrees when its output is `same` as that one. An
/// occurrence that was only rejected is judged by neither. Accuracy is
/// scored against what proved true: the truth an assessment names, or the
/// final output when it proved right.
pub fn replay(
  examples: List(Example(o)),
  candidate: Model(o),
  same same: fn(o, o) -> Bool,
) -> Replay {
  list.map(examples, replay_one(_, candidate, same:)) |> merge
}

/// Replay one example: the pure half of `replay`, for callers that spread
/// examples over processes and `merge` the results.
pub fn replay_one(
  example: Example(o),
  candidate: Model(o),
  same same: fn(o, o) -> Bool,
) -> Replay {
  case model.run(candidate, example.known.context, sources(example)) {
    Error(failure) ->
      Replay(tally: nothing, unanswered: [#(example.known.id, failure)])
    Ok(recommendation) ->
      Replay(
        tally: score(nothing, example.known, recommendation.output, same),
        unanswered: [],
      )
  }
}

/// What `policy` would have said about a recorded example when it was
/// recommended: the point's facts of the recommended output, the
/// recommender's signals and what consulted points returned, evaluated
/// under the candidate policy with no time waited. Use it beside `replay`
/// to see, before publishing a version, how many recorded occurrences it
/// would have let proceed and how many of those people corrected or
/// rejected.
pub fn answer_under(
  example: Example(o),
  policy candidate: Policy,
  point point: Point(o),
) -> Outcome {
  let known = example.known
  let facts =
    list.flatten([
      decisions.facts_of(point, known.recommendation.output),
      known.recommendation.signals,
      known.informed,
    ])
  policy.timeline(candidate, known.recommendation.by, facts, waited: 0).0
}

/// What `policy` would say about a candidate model's answer on a recorded
/// example: the candidate runs on the example's recorded sources (as in
/// `replay`), and its recommendation is evaluated as `answer_under`
/// evaluates the recorded one, with the facts consulted points returned.
/// Returns the candidate's recommendation with the policy's answer, or why
/// the candidate could not answer from the record.
pub fn candidate_under(
  example: Example(o),
  candidate candidate: Model(o),
  policy policy_version: Policy,
  point point: Point(o),
) -> Result(#(Recommendation(o), Outcome), Failure) {
  let known = example.known
  use recommendation <- result.map(model.run(
    candidate,
    known.context,
    sources(example),
  ))
  let facts =
    list.flatten([
      decisions.facts_of(point, recommendation.output),
      recommendation.signals,
      known.informed,
    ])
  #(
    recommendation,
    policy.timeline(policy_version, recommendation.by, facts, waited: 0).0,
  )
}

/// How triggers fared before a recommendation, for coverage: of the
/// records read, how many began with an expectation (`decisions.expect`),
/// how many of those a newer event superseded before anything was
/// recommended, and how many are still expected with nothing recommended
/// (work in flight, or a worker that died for good).
pub type Coverage {
  Coverage(expected: Int, superseded_before: Int, still_expected: Int)
}

/// Count `Coverage` over records read with `decisions.read_record`.
pub fn coverage(records: List(decisions.Record(o))) -> Coverage {
  list.fold(records, Coverage(0, 0, 0), fn(sum, record) {
    case record {
      decisions.Begun(known) ->
        case occurrence.was_expected(known) {
          True -> Coverage(..sum, expected: sum.expected + 1)
          False -> sum
        }
      decisions.NotBegun(pending) ->
        case pending.expected, pending.superseded {
          True, Some(_) ->
            Coverage(
              ..sum,
              expected: sum.expected + 1,
              superseded_before: sum.superseded_before + 1,
            )
          True, None ->
            Coverage(
              ..sum,
              expected: sum.expected + 1,
              still_expected: sum.still_expected + 1,
            )
          False, Some(_) ->
            Coverage(..sum, superseded_before: sum.superseded_before + 1)
          False, None -> sum
        }
    }
  })
}

/// Add up replays that ran apart, keeping their order.
pub fn merge(replays: List(Replay)) -> Replay {
  list.fold(replays, Replay(tally: nothing, unanswered: []), fn(sum, replay) {
    Replay(
      tally: add(sum.tally, replay.tally),
      unanswered: list.append(sum.unanswered, replay.unanswered),
    )
  })
}

/// A candidate's whole world for one example: the recorded context and
/// the recorded reads.
pub fn sources(example: Example(o)) -> model.Sources {
  model.recorded(
    context: example.context,
    reads: list.map(example.reads, fn(pair) {
      let read: Read = pair.0
      #(
        Ref(kind: read.name, id: read.argument, revision: read.result.revision),
        pair.1,
      )
    }),
  )
}

/// The example with what validators opened beyond the card added to what
/// a candidate may read: the context as the validator saw it. What a
/// validator opened is later knowledge, so it answers a read of the same
/// name and argument.
pub fn widened(example: Example(o)) -> Example(o) {
  let opened =
    list.zip(occurrence.expansions(example.known), example.expansions)
    |> list.map(fn(pair) {
      let #(#(_, ref), #(_, content)) = pair
      #(Read(name: ref.kind, argument: ref.id, result: ref), content)
    })
  Example(..example, reads: list.append(example.reads, opened))
}

/// Agreement against the output validators let through; accuracy against
/// what proved true.
/// People judged it and let nothing through: a rejection, as a verdict or
/// as a review, ended their judgment.
fn is_rejected(known: Occurrence(o)) -> Bool {
  case known.status {
    occurrence.Rejected(_) -> True
    occurrence.Released(..) ->
      passed(known) == None
      && list.any(occurrence.reviews(known), fn(review) {
        case review.1 {
          Reject(_) -> True
          Approve | Correct(..) -> False
        }
      })
    _ -> False
  }
}

/// The output people let through, by the rule `tally` states.
fn passed(known: Occurrence(o)) -> Option(o) {
  case known.status {
    occurrence.Accepted(..)
    | occurrence.Held(..)
    | occurrence.Released(..)
    | occurrence.Refused(_) -> let_through(known)
    occurrence.Recommended(_)
    | occurrence.Awaiting(_)
    | occurrence.Rejected(_)
    | occurrence.Expired(_)
    | occurrence.Withdrawn(_) -> None
  }
}

fn let_through(known: Occurrence(o)) -> Option(o) {
  let recommended = known.recommendation.output
  // A person's own act is itself a human judgment of the output.
  let own = case known.recommendation.by {
    Person(_) -> Some(recommended)
    _ -> None
  }
  list.fold(verdicts(known), own, fn(judged, verdict) {
    case verdict.1 {
      Approve -> Some(option.unwrap(judged, recommended))
      Correct(output:, ..) -> Some(output)
      Reject(_) -> None
    }
  })
}

fn score(
  tally: Tally,
  known: Occurrence(o),
  candidate: o,
  same: fn(o, o) -> Bool,
) -> Tally {
  let recommended = known.recommendation.output
  let tally = case passed(known) {
    Some(passed) ->
      Tally(
        ..tally,
        judged: tally.judged + 1,
        agreed: tally.agreed + count(same(candidate, passed)),
      )
    None -> Tally(..tally, rejected: tally.rejected + count(is_rejected(known)))
  }
  let final = occurrence.final(known) |> option.unwrap(recommended)
  list.fold(occurrence.assessments(known), tally, fn(tally, assessment) {
    case assessment.finding {
      Right ->
        Tally(
          ..tally,
          assessed: tally.assessed + 1,
          right: tally.right + count(same(candidate, final)),
        )
      Wrong(truth: Some(truth)) ->
        Tally(
          ..tally,
          assessed: tally.assessed + 1,
          right: tally.right + count(same(candidate, truth)),
        )
      // The truth is unknown: only repeating the wrong output can be scored.
      Wrong(truth: None) ->
        case same(candidate, final) {
          True -> Tally(..tally, assessed: tally.assessed + 1)
          False -> tally
        }
    }
  })
}

fn count(holds: Bool) -> Int {
  case holds {
    True -> 1
    False -> 0
  }
}
