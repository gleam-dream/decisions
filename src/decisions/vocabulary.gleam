//// The words every part of `decisions` shares: references to immutable
//// data, the context a model started from, who an occurrence is about,
//// what recommended, verdicts and assessments.
////
//// These are plain values. Nothing here reads a store or a clock, and every
//// value has a JSON form in `decisions/wire`.
////
//// ```gleam
//// import decisions/vocabulary.{Manifest, Ref, Subject}
////
//// let context =
////   Manifest(refs: [Ref("message", "m1", "1")], renderer: "reply-1")
//// let ana = Subject(kind: "person", id: "ana")
//// ```
////
//// Target-independent: builds for Erlang and JavaScript.

import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}

/// A reference to immutable data. `id` names the thing and `revision`
/// names the exact value that was read. For a read a model made beyond its
/// context, `kind` is the read's name and `id` its argument.
pub type Ref {
  Ref(kind: String, id: String, revision: String)
}

/// The context a model started from: references only, and the version of
/// the renderer that turns them into a prompt, a card and a training
/// example. The content behind each reference never changes.
pub type Manifest {
  Manifest(refs: List(Ref), renderer: String)
}

/// Who a gated tool call is about: a person, a company, a service.
pub type Subject {
  Subject(kind: String, id: String)
}

/// What asked for the decision: a message, a run, a build. It is not the
/// model.
pub type Trigger {
  Trigger(kind: String, id: String)
}

/// What an occurrence hangs from, so that settling it can start what
/// follows: the run to follow on, or the occurrence that consulted this
/// one.
pub type Parent {
  ParentRun(run: String)
  ParentOccurrence(id: String)
}

/// The bundle an occurrence belongs to: the occurrences one recommendation
/// proposed together, each judged, released and measured on its own.
/// Its key names the bundle and its size is how many occurrences it holds,
/// so a reader can tell a bundle that is complete from one still arriving.
/// Build it with `bundle`, so its key is never empty and its size is at
/// least one.
pub opaque type Bundle {
  Bundle(key: String, size: Int)
}

/// Why `bundle` refuses a key and a size.
pub type MalformedBundle {
  /// The bundle's key is empty.
  NoBundleKey
  /// The bundle's size is below one.
  EmptyBundle
}

/// A bundle of `size` occurrences named `key`. Bundle keys are one
/// namespace across every point of a store, as occurrence keys are, so
/// begin the key with something the application owns.
pub fn bundle(
  key key: String,
  size size: Int,
) -> Result(Bundle, MalformedBundle) {
  case key, size {
    "", _ -> Error(NoBundleKey)
    _, size if size < 1 -> Error(EmptyBundle)
    _, _ -> Ok(Bundle(key:, size:))
  }
}

/// The bundle's key.
pub fn bundle_key(bundle: Bundle) -> String {
  bundle.key
}

/// How many occurrences the bundle holds.
pub fn bundle_size(bundle: Bundle) -> Int {
  bundle.size
}

/// What recommended. Agreement and accuracy are counted per value of this
/// type, so a new version is a new value.
pub type Recommender {
  Rules(name: String, version: String)
  Classifier(name: String, version: String)
  ModelCall(configuration: String, version: String)
  Agent(kind: String, version: String)
  /// A person, for their own act only. A policy can let a person's own act
  /// proceed with the `OwnAct` condition.
  Person(subject: String)
}

/// Why the recommender recommended this output. Every kind of recommender
/// produces the same record and differs only here.
pub type Explanation {
  RuleFired(rule: String)
  /// Captured evidence holds the explanation, such as a provider's answer.
  Receipt(evidence: Ref)
  RunAnswer(run: String)
  RunAction(run: String, action: String)
  OwnAct
}

/// A value a policy may read. A policy reads nothing but named facts and
/// the recommender.
pub type Fact {
  Number(Float)
  Text(String)
  Flag(Bool)
}

/// Named facts. Build them with the typed keys of `decisions/fact`.
pub type Facts =
  List(#(String, Fact))

/// What a recommender proposes, with everything a policy and a person need
/// to judge it.
pub type Recommendation(output) {
  Recommendation(
    output: output,
    by: Recommender,
    explanation: Explanation,
    /// Facts the recommender reports beside its output, such as a score.
    signals: Facts,
    /// What the model received beyond its context, each as a reference to
    /// captured evidence. `decisions/model.run` fills it; see
    /// `decisions/model` for observed and reported reads.
    reads: List(Ref),
  )
}

/// What became of a released output outside the database.
pub type Effect {
  /// The outside system did it; `receipt` is its evidence.
  Performed(receipt: Ref)
  NotPerformed(reason: String)
  /// Nobody knows yet. Only evidence, such as a lookup by the release's
  /// key, settles it; nothing should retry blindly.
  Uncertain(reason: String)
}

/// Why a validator rejected or corrected. `category` is required and
/// machine-readable; `note` is free text.
pub type Reason {
  Reason(category: String, note: Option(String))
}

/// A validator's verdict on the output that stands. A correction carries an
/// output of the point's own type, so a verdict for another point does not
/// type-check.
pub type Verdict(output) {
  Approve
  Reject(reason: Reason)
  Correct(output: output, reason: Reason)
}

/// The verdicts a point's declaration allows.
pub type Verdicts {
  ApproveOrReject
  ApproveRejectOrCorrect
}

/// What proved true later. It is appended and never overwrites a verdict
/// or the output.
pub type Assessment(output) {
  Assessment(
    finding: Finding(output),
    evidence: Ref,
    source: String,
    known_at: Timestamp,
  )
}

/// Whether the final output proved right. `Wrong` may carry the output that
/// would have been right.
pub type Finding(output) {
  Right
  Wrong(truth: Option(output))
}

/// Why an occurrence can no longer be decided.
pub type ExpiryCause {
  DeadlinePassed
  Superseded(event: String)
}

/// A person, or another system, giving verdicts, with the decision sets
/// they hold. Who holds a set is a fact of the session, not of the record.
pub type Validator {
  Validator(subject: String, holds: List(String))
}

/// Why a guard, a release check or an executor did not let a release
/// happen.
pub type Stop {
  /// It refuses this release, for good. With a validator present the
  /// verdict rolls back (`ToolRefused`); with nobody waiting the occurrence
  /// ends `Refused`.
  Refuse(reason: String)
  /// It could not tell: its database connection dropped, a provider timed
  /// out. Its savepoint rolls back, nothing is recorded as refused, and
  /// the verb fails with `ToolUnsure`, so the caller or the runtime tries
  /// again later (counted toward setting the job aside).
  Unsure(reason: String)
}
