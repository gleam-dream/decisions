//// A decision point: a place in a system where a recommender proposes an
//// output, a policy either proceeds or asks a person, the person approves,
//// rejects or corrects, and the final output is released exactly once to a
//// gated tool. Everything that happened is kept as an append-only record
//// of entries, which is the data the system learns from.
////
//// This module holds the declaration (`Point`), the gated tool (`Gated`
//// and `Released`), and the desk with its verbs. A `Desk` binds a point to
//// its gated tool, its current policy and a storage port. It is a plain
//// value: build one where you need it, and call its verbs inside your own
//// transaction. Nothing here keeps global state, starts a process or
//// performs I/O; the port does that, in the transaction you pass.
////
//// ```gleam
//// import decisions
//// import decisions/memory
//// import decisions/policy.{AnyoneHolding}
//// import decisions/vocabulary.{Approve}
////
//// let point = decisions.point("billing.fee_refund", refund_codec())
//// let desk =
////   decisions.desk(
////     point,
////     drives: fn(_) { refund_fee() },
////     under: fn(_) {
////       policy.new(version: 1, rules: [], otherwise: AnyoneHolding("finance"))
////       |> result.replace_error("malformed")
////     },
////     over: memory.port(),
////   )
////
//// // A request: the recommendation is recorded and waits for finance.
//// let assert Ok(waiting) = memory.transaction(store, decisions.recommend(desk, _, proposal))
////
//// // Another request: Bia opens the card and approves. The refund is
//// // released to the gated tool in her verdict's transaction.
//// let assert Ok(released) =
////   memory.transaction(store, fn(tx) {
////     use card <- result.try(decisions.open(desk, tx, waiting.id, by: bia, latest: unchanged))
////     decisions.decide(desk, tx, card, Approve)
////   })
//// ```
////
//// The verbs, grouped by who calls them:
////
//// - Whoever admits a trigger: `happened` for what the trigger reports,
////   then `expect` (or `expect_until`, with the occurrence's own
////   deadline), in the transaction that receives it, before the
////   recommender runs. `happened` locks the point and subject first, so
////   two admissions about one subject run one after the other.
//// - A recommender: `recommend`, `recommend_once`, `record_failure`, and
////   `recommend_bundle` (or `recommend_member`) for several occurrences
////   proposed together.
//// - A validator: `open`, `resume` (with a `Ticket`), `expand`, `note`,
////   `decide`, `review`, `withdraw`, `record_refusal`.
//// - The world and the system: `happened`, `inform`, `wake` (or `waker`),
////   `report`, `assess`, `read`, `read_record`, and `members` with
////   `is_complete` for whoever follows a bundle.
////
//// A record's life, by the status of its head: `pending` (expected, or
//// only failed attempts so far), then `recommended`, `awaiting` a person,
//// `accepted`, possibly `held` for an undo window, and finally one of
//// `released`, `rejected`, `expired` or `withdrawn`. `happened` ends every
//// record of its subject that has not been released yet: a pending record
//// is reported in `not_begun` and its later recommendation is refused with
//// `SupersededBefore` (unless its own deadline had already passed: it then
//// expires as deadline passed, and a later recommendation is recorded
//// expired); an undecided or held one expires and nothing is released. Only a key never expected can still
//// be recommended after the event that should have superseded it.
////
//// Every verb loads the occurrence first, which locks it, then reads the
//// store's clock, so entries are stored in time order. A verb that returns
//// `Error` has written nothing the caller must keep: roll the transaction
//// back. The two exceptions to "nothing is kept" are recorded on purpose
//// by `record_failure` and `record_refusal`, each in a transaction of its
//// own.
////
//// Target-independent: builds for Erlang and JavaScript.

import decisions/entry.{type Entry, type Event}
import decisions/fact.{type Key, type Kind}
import decisions/model.{type Failure}
import decisions/occurrence.{type Attempt, type Decider, type Occurrence}
import decisions/policy.{type Eligible, type Fault, type Policy, type Sample}
import decisions/store.{type Port, type StoreError}
import decisions/vocabulary.{
  type Assessment, type Bundle, type Effect, type Fact, type Facts, type Item,
  type Manifest, type Parent, type Recommendation, type Ref, type Stop,
  type Subject, type Trigger, type Validator, type Verdict, type Verdicts,
  Approve, ApproveOrReject, Correct, Person, Ref, Refuse, Reject, Superseded,
  Unsure,
}
import decisions/wire.{type Codec}
import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}
import json/blueprint/value

// -- The declaration ----------------------------------------------------------

/// A decision point's declaration: its name, its output type, the verdicts
/// it allows, the facts a policy may read, and its timing. It holds no
/// condition for proceeding without a person; that is the policy's.
pub opaque type Point(output) {
  Point(
    name: String,
    output: Codec(output),
    verdicts: Verdicts,
    facts: List(#(String, Source(output))),
    hold: Option(Duration),
    validity: Option(Duration),
    superseded_by: List(String),
    reviewers: Option(String),
    withdrawers: Option(String),
  )
}

/// A point with this name and output codec. It allows approve and reject,
/// declares no facts, has no hold and no validity, and nothing supersedes
/// it. The name is stored on every occurrence: keep it stable.
pub fn point(name: String, output: Codec(output)) -> Point(output) {
  Point(
    name:,
    output:,
    verdicts: ApproveOrReject,
    facts: [],
    hold: None,
    validity: None,
    superseded_by: [],
    reviewers: None,
    withdrawers: None,
  )
}

/// The verdicts a validator may give.
pub fn allowing(point: Point(o), verdicts: Verdicts) -> Point(o) {
  Point(..point, verdicts:)
}

/// Where a declared fact comes from. Each name a point declares has one
/// source.
type Source(output) {
  /// Computed from the recommended output.
  FromOutput(kind: Kind, compute: fn(output) -> Fact)
  /// Carried by the recommendation, beside its output.
  FromSignal(kind: Kind)
  /// Returned by the consulted point named `point`, through `inform`.
  FromAnswer(kind: Kind, point: String)
}

/// Declare a fact of the output, such as an amount, that a policy may read.
/// `from` computes it from the recommended output. Declaring a name again,
/// with this or with `signal` or `answer`, replaces its earlier
/// declaration, so each fact has one source.
pub fn fact(point: Point(o), key: Key(a), from: fn(o) -> a) -> Point(o) {
  declare(
    point,
    key,
    FromOutput(kind: fact.kind(key), compute: fn(output) {
      fact.wrap(key, from(output))
    }),
  )
}

/// Declare a fact the recommendation carries beside its output in its
/// signals, such as a model's score, that a policy may read. `recommend`
/// refuses a recommendation whose signals hold a fact not declared with
/// `signal`, or of another type, with `InvalidFacts`. Declaring a name
/// again replaces its earlier declaration.
pub fn signal(point: Point(o), key: Key(a)) -> Point(o) {
  declare(point, key, FromSignal(kind: fact.kind(key)))
}

/// Declare a fact that the consulted point named `from` returns through
/// `inform`, such as a compliance check's verdict, that a policy may read.
/// `inform` accepts it only from that point, and no recommendation can
/// carry it as a signal. Declaring a name again replaces its earlier
/// declaration.
pub fn answer(
  point: Point(o),
  key: Key(a),
  from consulted: String,
) -> Point(o) {
  declare(point, key, FromAnswer(kind: fact.kind(key), point: consulted))
}

fn declare(point: Point(o), key: Key(a), source: Source(o)) -> Point(o) {
  let name = fact.name(key)
  Point(..point, facts: [
    #(name, source),
    ..list.filter(point.facts, fn(declared) { declared.0 != name })
  ])
}

/// A wait between every acceptance and its release, during which the
/// decider, or a holder of the `withdrawn_by` set, may withdraw. A
/// `Proceed` that declares its own hold takes the place of this one for
/// the acceptances it makes; to hold only what the policy lets proceed,
/// put the hold in the policy's `Proceed` and not here. The guard and the tool run when it ends, at the
/// wake-up: a refusal then ends the occurrence `Refused`, and never
/// reaches the validator who approved, who has already been answered.
pub fn with_hold(point: Point(o), hold: Duration) -> Point(o) {
  Point(..point, hold: Some(hold))
}

/// How long an occurrence may wait to be decided. After it, no verdict is
/// accepted and the occurrence expires.
pub fn valid_for(point: Point(o), validity: Duration) -> Point(o) {
  Point(..point, validity: Some(validity))
}

/// Who may withdraw a held occurrence besides its decider: holders of
/// `set`, through `withdraw_as`. Without it only the decider may, which
/// for an output the policy accepted from a model is nobody. Pair it with
/// a `Proceed` that holds (an undo window the policy declares) or with
/// `with_hold`.
pub fn withdrawn_by(point: Point(o), set: String) -> Point(o) {
  Point(..point, withdrawers: Some(set))
}

/// Who may review a sampled occurrence after its release: holders of
/// `set`. Without it anyone may, except the people `review` always
/// excludes (whoever decided it, asked for it, or recommended it as their
/// own act).
pub fn reviewed_by(point: Point(o), set: String) -> Point(o) {
  Point(..point, reviewers: Some(set))
}

/// A world event that expires an occurrence about the same subject that
/// has not been released, reported with `happened`: one still undecided,
/// and one accepted and held, since nothing is released while it is held.
pub fn superseded_by(point: Point(o), event: String) -> Point(o) {
  Point(..point, superseded_by: [event, ..point.superseded_by])
}

/// The point's name.
pub fn name(point: Point(o)) -> String {
  point.name
}

/// The point's output codec.
pub fn codec(point: Point(o)) -> Codec(o) {
  point.output
}

/// The verdicts the point allows.
pub fn verdicts(point: Point(o)) -> Verdicts {
  point.verdicts
}

/// Every fact a policy for this point may read, with its type.
pub fn declared(point: Point(o)) -> List(#(String, Kind)) {
  list.reverse(point.facts)
  |> list.map(fn(declared) { #(declared.0, kind_of_source(declared.1)) })
}

fn kind_of_source(source: Source(o)) -> Kind {
  case source {
    FromOutput(kind:, ..) | FromSignal(kind:) | FromAnswer(kind:, ..) -> kind
  }
}

/// The facts a policy reads about a recommendation: the facts the point
/// computes from its output, the declared signals it carries, and the
/// declared answers consulted points returned (`informed`). Each fact is
/// taken only from the source its point declares, so a signal never
/// stands for an output fact or a consulted point's answer.
pub fn policy_facts(
  point: Point(o),
  recommendation: Recommendation(o),
  informed informed: Facts,
) -> Facts {
  let from = fn(facts: Facts, keep: fn(Source(o)) -> Bool) {
    list.filter(facts, fn(named) {
      case list.key_find(point.facts, named.0) {
        Ok(source) -> keep(source)
        Error(Nil) -> False
      }
    })
  }
  list.flatten([
    list.filter_map(list.reverse(point.facts), fn(declared) {
      case declared.1 {
        FromOutput(compute:, ..) ->
          Ok(#(declared.0, compute(recommendation.output)))
        FromSignal(..) | FromAnswer(..) -> Error(Nil)
      }
    }),
    from(recommendation.signals, fn(source) {
      case source {
        FromSignal(..) -> True
        FromOutput(..) | FromAnswer(..) -> False
      }
    }),
    from(informed, fn(source) {
      case source {
        FromAnswer(..) -> True
        FromOutput(..) | FromSignal(..) -> False
      }
    }),
  ])
}

/// The faults of facts that arrive from one source: each must be declared
/// with that source and its declared type.
fn fact_faults(
  point: Point(o),
  facts: Facts,
  from source: fn(Source(o)) -> Bool,
) -> List(Fault) {
  list.filter_map(facts, fn(named) {
    let #(name, value) = named
    case list.key_find(point.facts, name) {
      Ok(declared) ->
        case source(declared), kind_of_source(declared) == fact.kind_of(value) {
          False, _ -> Ok(policy.UndeclaredFact(name))
          True, True -> Error(Nil)
          True, False ->
            Ok(policy.WrongKind(
              fact: name,
              declared: kind_of_source(declared),
              used: fact.kind_of(value),
            ))
        }
      Error(Nil) -> Ok(policy.UndeclaredFact(name))
    }
  })
}

/// Whether a policy may be published for this point: it reads only facts
/// the point declares, each as its declared type. Call it before storing a
/// policy version. The desk checks it again each time it reads a policy.
pub fn publishable(
  point: Point(o),
  policy: Policy,
) -> Result(Nil, List(Fault)) {
  policy.check(policy, declared: declared(point))
}

// -- Tools --------------------------------------------------------------------

/// A guard states facts about the world for a subject, such as "the
/// service window is open". Its parameters are the transaction and the
/// subject. A check that needs the output, such as an amount against a
/// balance, belongs in the release check (`checking`), where its evidence
/// is recorded; a threshold on the output belongs in the policy. A guard
/// built inside `drives` can close over the output, and nothing stops it;
/// do not. It returns the evidence it relied on, which the release
/// records, or a `Stop`.
pub type Guard(tx) =
  fn(tx, Subject) -> Result(List(Ref), Stop)

/// What the release check sees: the output about to be released, who it
/// is about, the context it was recommended from, and the release's key.
/// It is a plain value; no executor accepts it.
pub type ToRelease(output) {
  ToRelease(output: output, subject: Subject, context: Manifest, key: String)
}

/// A final output being released. Only the desk constructs one, for one
/// release attempt, inside the savepoint, after the guard and the release
/// check allowed it, and hands it to the gated tool's executor alone. If
/// the executor refuses, the attempt rolls back and no release happened:
/// an executor must not keep the value or pass it on, because it names a
/// release only within the call it was handed to. A gated tool's executor
/// accepts nothing else.
pub opaque type Released(output) {
  Released(
    occurrence: String,
    key: String,
    subject: Subject,
    parent: Option(Parent),
    by: Decider,
    output: output,
    context: Manifest,
  )
}

/// The released output.
pub fn output(released: Released(o)) -> o {
  released.output
}

/// A stable key for the outside effect: the idempotency key a provider is
/// sent and the cause a command log cites. An uncertain outcome is settled
/// by looking the effect up by this key.
pub fn key(released: Released(o)) -> String {
  released.key
}

/// Who the release is about.
pub fn subject(released: Released(o)) -> Subject {
  released.subject
}

/// The id of the occurrence that was released.
pub fn occurrence_of(released: Released(o)) -> String {
  released.occurrence
}

/// What the occurrence hangs from: the run to follow on, or the occurrence
/// that consulted this one.
pub fn parent(released: Released(o)) -> Option(Parent) {
  released.parent
}

/// The context the occurrence was recommended from: its references, never
/// the output. A release check (`checking`) or an executor that must know
/// which revision of the subject the occurrence is about reads it here.
pub fn context_of(released: Released(o)) -> Manifest {
  released.context
}

/// Who accepted the output: a policy version or a validator. An executor
/// that attributes its writes uses this.
pub fn decider(released: Released(o)) -> Decider {
  released.by
}

/// A gated tool: a guard, and an executor that accepts nothing but a
/// released output. Its `name` is recorded on the release. The guard, the
/// desk's release check and the executor run in that order inside one
/// savepoint (`store.Port.atomically`), so an executor that writes and
/// then returns `Error` leaves nothing behind, and the release records the
/// evidence of both the guard and the check. `drives` picks the tool from
/// the output; see `Guard` for what a guard should and should not read.
pub type Gated(output, tx) {
  Gated(
    name: String,
    guard: Guard(tx),
    execute: fn(tx, Released(output)) -> Result(Nil, Stop),
  )
}

// -- The desk -------------------------------------------------------------------

/// A decision point bound to its gated tool, its current policy and a
/// storage port. Build one per point wherever it is needed; it holds no
/// state.
pub opaque type Desk(output, tx) {
  Desk(
    point: Point(output),
    tool: fn(output) -> Gated(output, tx),
    policy: fn(tx) -> Result(Policy, String),
    port: Port(tx),
    consult: fn(tx, Consultation(output)) -> Result(Nil, String),
    check: fn(tx, ToRelease(output)) -> Result(List(Ref), Stop),
  )
}

/// What a policy's `Consult` hands to the consulted decision point.
pub type Consultation(output) {
  Consultation(
    point: String,
    occurrence: String,
    subject: Subject,
    context: Manifest,
    recommendation: Recommendation(output),
  )
}

/// A desk for `point`. `drives` picks the gated tool for a final output,
/// so a point whose output has several variants can drive one tool per
/// variant. The tool it returns closes over that output, and so can its
/// guard; a guard should read only its parameters, the transaction and the
/// subject, and leave checks on the output to `checking` (where their
/// evidence is recorded) and thresholds to the policy. `under` reads the current policy in the caller's transaction,
/// so publishing a version is a write. `over` is the storage port.
pub fn desk(
  point: Point(o),
  drives tool: fn(o) -> Gated(o, tx),
  under policy: fn(tx) -> Result(Policy, String),
  over port: Port(tx),
) -> Desk(o, tx) {
  Desk(
    point:,
    tool:,
    policy:,
    port:,
    consult: fn(_, consultation) {
      Error("no decision point is wired to answer " <> consultation.point)
    },
    check: fn(_, _) { Ok([]) },
  )
}

/// How this desk reaches the points its policy may consult. The handler
/// recommends at the consulted point, whose gated tool calls `inform` on
/// this occurrence, in this transaction or a later one.
pub fn consulting(
  desk: Desk(o, tx),
  with consult: fn(tx, Consultation(o)) -> Result(Nil, String),
) -> Desk(o, tx) {
  Desk(..desk, consult:)
}

/// A check the release makes with the output in hand, such as "the amount
/// is covered by the balance": it runs after the gated tool's guard and
/// before its executor, inside the same savepoint, and returns the
/// evidence it relied on, which the release records beside the guard's in
/// `relied`, or a `Stop`. It sees a `ToRelease`, never a `Released`, so it
/// cannot reach the executor. A threshold on the output alone belongs in
/// the policy; this is for a fact of the world that must be compared with
/// the output at release.
pub fn checking(
  desk: Desk(o, tx),
  with check: fn(tx, ToRelease(o)) -> Result(List(Ref), Stop),
) -> Desk(o, tx) {
  Desk(..desk, check:)
}

/// The desk's point.
pub fn point_of(desk: Desk(o, tx)) -> Point(o) {
  desk.point
}

/// What a recommender proposes, and about whom. Build one with `proposal`
/// and add what applies with `asked_by`, `hanging_from` and `valid_until`.
pub opaque type Proposal(output) {
  Proposal(
    trigger: Trigger,
    subject: Subject,
    context: Manifest,
    recommendation: Recommendation(output),
    parent: Option(Parent),
    requester: Option(String),
    valid_until: Option(Timestamp),
  )
}

/// A proposal that hangs from nothing and that nobody asked for.
pub fn proposal(
  trigger trigger: Trigger,
  about subject: Subject,
  context context: Manifest,
  recommending recommendation: Recommendation(o),
) -> Proposal(o) {
  Proposal(
    trigger:,
    subject:,
    context:,
    recommendation:,
    parent: None,
    requester: None,
    valid_until: None,
  )
}

/// The person who asked. `SomeoneElseHolding` keeps them from approving
/// it. A recommendation by `Person(subject)` is that person's request
/// without this.
pub fn asked_by(proposal: Proposal(o), requester: String) -> Proposal(o) {
  Proposal(..proposal, requester: Some(requester))
}

/// What the occurrence hangs from, so settling it can start what follows.
pub fn hanging_from(proposal: Proposal(o), parent: Parent) -> Proposal(o) {
  Proposal(..proposal, parent: Some(parent))
}

/// The occurrence's own deadline, an instant the application knows, such
/// as the end of a service window. The deadline written on the
/// recommendation is the earliest of this, the point's validity counted
/// from the recommendation, and the deadline the key's expectation carries
/// (`expect_until`): a proposal brings a deadline earlier, never later.
/// When it has already passed, the recommendation is recorded and expires
/// at once. The instant is kept in whole milliseconds, rounded down.
pub fn valid_until(
  proposal: Proposal(o),
  at deadline: Timestamp,
) -> Proposal(o) {
  Proposal(..proposal, valid_until: Some(whole_milliseconds(deadline)))
}

/// Why a verb did not do what was asked. Every refusal leaves nothing the
/// caller must keep: roll the transaction back.
///
/// `Refusal` may gain variants in a minor release; keep a `_` branch.
pub type Refusal {
  /// No occurrence of this point has this id.
  UnknownOccurrence
  /// The key was tried and nothing was recommended yet; these are the
  /// failed attempts.
  NotRecommended(attempts: List(Attempt))
  /// The occurrence is not waiting for this: it settled, or its deadline
  /// passed, or it waits for a consulted point.
  NotAwaiting
  /// The occurrence no longer waits because `by`'s verdict settled it:
  /// accepted it (held or released after) or rejected it. Only a verdict
  /// settles this way; an occurrence that expired, was withdrawn or was
  /// refused by the tool is `NotAwaiting`. The same verdict sent again on
  /// the same card or ticket is not refused: it returns the occurrence.
  AlreadyDecided(by: String)
  /// This validator may not open or decide this occurrence.
  NotEligible
  /// The point's declaration does not allow this verdict.
  VerdictNotAllowed
  /// A rejection or a correction needs a reason category.
  ReasonRequired
  /// A verdict for missing context needs a note saying what was missing.
  NoteRequired
  /// The card names no recorded showing of this occurrence to this
  /// validator: a ticket for someone else, or a card opened while the
  /// occurrence was not waiting for verdicts.
  NeverShown
  /// The output that stands was corrected after this card was shown. Open
  /// the card again to see the output the verdict would be about.
  OutputChanged
  /// The occurrence is not on hold, or its hold has already ended.
  NotHeld
  /// Only whoever decided may withdraw.
  NotTheDecider
  /// The occurrence has not been released, so nothing outside the database
  /// can have happened yet.
  NotReleased
  /// The occurrence was not sampled for a review, or is not released yet.
  NotSampled
  /// The occurrence has not settled, so there is no outcome to assess.
  NotSettled
  /// The occurrence is not waiting for an answer from this point.
  NotConsulting
  /// A recommendation's signals, or a consulted point's answer, hold facts
  /// the point does not declare from that source, or of the wrong type: a
  /// signal must be declared with `signal`, an answer with `answer` from
  /// the point that gives it.
  InvalidFacts(faults: List(Fault))
  /// The guard or the gated tool refused in the verdict's own
  /// transaction. Roll the transaction back, then pass `rollback` to
  /// `record_refusal` in a transaction of its own to keep the attempt on
  /// the record.
  ToolRefused(reason: String, rollback: Rollback)
  /// The guard, the release check or the tool could not tell (`Unsure`).
  /// Nothing was recorded; roll back and try again later.
  ToolUnsure(reason: String)
  /// The handler wired with `consulting` failed to ask `point`.
  ConsultFailed(point: String, reason: String)
  /// A newer event, `event`, superseded this key before anything was
  /// recommended under it: the trigger's work is moot. Nothing was written,
  /// shown or released. A runtime drops the job as done.
  SupersededBefore(event: String)
  /// The key's own deadline (`expect_until`) passed by the store clock
  /// before anything was recommended under it: nothing can be decided any
  /// more. Nothing was written. `expect`, `expect_until`, `record_failure`,
  /// `record_failure_with`, `read` and every verb that needs an occurrence
  /// refuse such a key this
  /// way; `recommend_once` does not, it records the late recommendation
  /// expired. A runtime drops the job as done.
  DeadlinePassedBefore(deadline: Timestamp)
  /// `recommend_once` or `record_failure` was given a key that an
  /// occurrence of another point already holds. Keys are one namespace
  /// across every point of a store.
  KeyTaken(point: String)
  /// The policy could not be read.
  NoPolicy(reason: String)
  /// The policy read for this point fails `publishable`.
  Unpublishable(faults: List(Fault))
  /// The stored record does not decode with this point's codec.
  Unreadable(reason: String)
  /// The point's codec cannot encode an output to be stored.
  Unencodable(reason: String)
  /// The bundle cannot take this occurrence; `fault` says why. Nothing was
  /// written.
  BadBundle(bundle: String, fault: BundleFault)
  /// The store refused or failed.
  StoreFailed(error: StoreError)
}

/// Why a bundle cannot take an occurrence.
pub type BundleFault {
  /// `recommend_bundle` was given an empty key or no items.
  Malformed(reason: vocabulary.MalformedBundle)
  /// A member already recorded the bundle with this other size.
  SizeDiffers(recorded: Int)
  /// The bundle already holds as many members as its size.
  BundleFull
  /// `recommend_bundle` was given this item more than once.
  RepeatedItem(item: String)
  /// The key already holds an occurrence that is not a member of this
  /// bundle: one proposed alone, or a member of another bundle or size.
  KeyOutsideBundle(key: String)
  /// The key's record ended before anything was recommended under it (its
  /// own deadline passed), and its one settlement notice went out then,
  /// before it belonged to the bundle. Admitted now, it would settle
  /// without a notice, and if it were the last member to settle nothing
  /// would see the bundle complete.
  EndedBefore(key: String)
}

/// What a verdict refused at release leaves behind once its transaction
/// rolled back: who gave it, on which showing, the verdict and why it was
/// refused. Only the desk makes one, inside `ToolRefused`, and
/// `record_refusal` accepts nothing else, so the record can only show a
/// refusal that happened.
pub opaque type Rollback {
  Rollback(
    point: String,
    occurrence: String,
    by: String,
    seen: Int,
    verdict: String,
    reason: String,
  )
}

/// Why a handler the application wrote (a settlement follower, a wake-up
/// or job handler) failed: one type both runtimes take.
pub type HandlerFailure {
  /// A verb of the desk refused; `disposition` classifies it.
  DeskRefused(refusal: Refusal)
  /// The application's own work failed, such as a call to another system.
  ApplicationFailed(reason: String)
}

/// What a runtime does with a job whose handler failed. A runtime decides
/// everything from this value, without looking at the failure.
pub type Handling {
  /// Deliver the job again soon, and do not count this failure: the store
  /// was contended, or its outcome is unknown. Nothing about the job is
  /// wrong.
  Redeliver
  /// Deliver the job again after a backoff, and count this failure toward
  /// setting the job aside: the application's own work failed, or a desk
  /// refusal that may pass later or may never pass (`Retry`). When the
  /// runtime's attempts are used, it sets the job aside as for `SetAside`.
  Backoff
  /// Set the job aside now for an operator, without delivering it again:
  /// the record does not decode, and every delivery would fail the same
  /// way.
  SetAside
  /// The job is done; drop it. The desk refused for a reason another
  /// delivery will not change: the occurrence moved on, the job was not
  /// eligible, or the request was malformed.
  Drop
}

/// What a runtime does with a handler's failure. A desk refusal follows
/// its `disposition`: `Transient` is `Redeliver`, `Retry` is `Backoff`,
/// `Poisoned` is `SetAside`, `Final` is `Drop`. An application failure is
/// `Backoff`.
pub fn handling(failure: HandlerFailure) -> Handling {
  case failure {
    ApplicationFailed(_) -> Backoff
    DeskRefused(refusal:) ->
      case disposition(refusal) {
        Transient -> Redeliver
        Retry -> Backoff
        Poisoned -> SetAside
        Final -> Drop
      }
  }
}

/// What a runtime that delivers wake-ups or notices may do after a
/// refusal, without reading its text.
pub type Disposition {
  /// Contention, or a store whose outcome is unknown: deliver again soon,
  /// not counted. Nothing about the job is wrong.
  Transient
  /// It may pass on another try, or may never pass: deliver again after a
  /// backoff, counted, and set the job aside when the attempts are used.
  Retry
  /// It needs an operator, and the occurrence still waits for what the job
  /// was delivering: set the job aside, do not drop it.
  Poisoned
  /// The occurrence moved on, or the job can never apply to it: the job is
  /// done.
  Final
}

/// Classify a refusal. Every variant is named here, so a new one cannot be
/// classified by accident.
///
/// | Refusal | Disposition | Why |
/// | --- | --- | --- |
/// | `StoreFailed(Contended)`, `StoreFailed(Unavailable)` | `Transient` | Nothing written, or the outcome is unknown; another try is the remedy |
/// | `StoreFailed(Conflict)` | `Retry` | A rerun reloads the record, but a conflict that repeats is a second writer that needs looking at |
/// | `NoPolicy`, `ConsultFailed`, `ToolUnsure` | `Retry` | May pass later (a policy published, a handler wired, a provider back), or may never |
/// | `Unreadable`, `Unpublishable`, `InvalidFacts`, `Unencodable`, `KeyTaken`, `BadBundle` | `Poisoned` | An operator must fix the record, the policy, the answer, the codec, the key or the bundle; the occurrence or its trigger still waits |
/// | every other refusal | `Final` | The occurrence moved on (settled, decided, expired, not waiting for this), or the request can never apply |
pub fn disposition(refusal: Refusal) -> Disposition {
  case refusal {
    StoreFailed(store.Contended(_)) | StoreFailed(store.Unavailable(_)) ->
      Transient
    StoreFailed(store.Conflict(_))
    | NoPolicy(_)
    | ConsultFailed(..)
    | ToolUnsure(_) -> Retry
    Unreadable(_)
    | Unpublishable(_)
    | InvalidFacts(_)
    | Unencodable(_)
    | KeyTaken(_)
    | BadBundle(..) -> Poisoned
    UnknownOccurrence
    | NotRecommended(_)
    | NotAwaiting
    | AlreadyDecided(_)
    | NotEligible
    | VerdictNotAllowed
    | ReasonRequired
    | NoteRequired
    | NeverShown
    | OutputChanged
    | NotHeld
    | NotTheDecider
    | NotReleased
    | NotSampled
    | NotSettled
    | NotConsulting
    | SupersededBefore(_)
    | DeadlinePassedBefore(_)
    | ToolRefused(..) -> Final
  }
}

/// What a guard, a release check or an executor answers when a verb it
/// ran refused, or a store call of its own failed (pass
/// `StoreFailed(error)`), so the refusal keeps its meaning through the
/// verb that runs the tool:
///
/// | Refusal | Stop |
/// | --- | --- |
/// | `StoreFailed(Contended)` | `Contended`: nothing was written; the outer verb fails as contention |
/// | any other `Transient` or `Retry` refusal | `Unsure`: the outer verb fails with `ToolUnsure` |
/// | a `Poisoned` or `Final` refusal | `Refuse` |
pub fn stop_for(refusal: Refusal) -> Stop {
  case refusal, disposition(refusal) {
    StoreFailed(store.Contended(detail:)), _ -> vocabulary.Contended(detail:)
    _, Transient | _, Retry -> Unsure(describe(refusal))
    _, Poisoned | _, Final -> Refuse(describe(refusal))
  }
}

/// The reason category that requires a note: the validator knows
/// something the card does not show and must say what.
pub const missing_context = "missing_context"

/// A refusal as one line of text, for a person.
pub fn describe(refusal: Refusal) -> String {
  case refusal {
    UnknownOccurrence -> "no such occurrence"
    NotRecommended(attempts:) ->
      "nothing was recommended yet after "
      <> int.to_string(list.length(attempts))
      <> " failed attempts"
    NotAwaiting -> "the occurrence is not waiting for a verdict"
    AlreadyDecided(by:) -> "the occurrence was decided by " <> by
    NotEligible -> "this validator may not decide this occurrence"
    VerdictNotAllowed -> "the declaration does not allow this verdict"
    ReasonRequired -> "a rejection or a correction needs a reason"
    NoteRequired -> "say what was missing before deciding on missing context"
    NeverShown -> "this card was never shown to this validator"
    OutputChanged -> "the output was corrected after this card was shown"
    NotHeld -> "the occurrence is not on hold"
    NotTheDecider -> "only whoever decided may withdraw"
    NotReleased -> "the occurrence has not been released"
    NotSampled -> "the occurrence was not sampled for review"
    NotSettled -> "the occurrence has not settled yet"
    NotConsulting -> "the occurrence is not waiting for an answer from there"
    InvalidFacts(faults:) ->
      "the facts are not declared from their source: "
      <> string.join(list.map(faults, policy.describe), "; ")
    ToolRefused(reason:, ..) -> reason
    ToolUnsure(reason:) -> "the tool could not tell: " <> reason
    ConsultFailed(point:, reason:) ->
      "consulting " <> point <> " failed: " <> reason
    KeyTaken(point:) -> "the key is taken by an occurrence of " <> point
    SupersededBefore(event:) ->
      "superseded by " <> event <> " before it was recommended"
    DeadlinePassedBefore(deadline:) ->
      "its deadline, "
      <> timestamp.to_rfc3339(deadline, duration.seconds(0))
      <> ", passed before it was recommended"
    NoPolicy(reason:) -> "the policy could not be read: " <> reason
    Unpublishable(faults:) ->
      "the policy cannot be used: "
      <> string.join(list.map(faults, policy.describe), "; ")
    Unreadable(reason:) -> "the record does not decode: " <> reason
    Unencodable(reason:) -> "the output does not encode: " <> reason
    BadBundle(bundle:, fault:) ->
      "bundle "
      <> string.inspect(bundle)
      <> " cannot take this occurrence: "
      <> case fault {
        Malformed(reason: vocabulary.NoBundleKey) -> "its key is empty"
        Malformed(reason: vocabulary.EmptyBundle) -> "it has no items"
        SizeDiffers(recorded:) ->
          "a member recorded its size as " <> int.to_string(recorded)
        BundleFull -> "it already holds all its members"
        RepeatedItem(item:) -> "the item " <> item <> " is given twice"
        KeyOutsideBundle(key:) ->
          "the key " <> key <> " already holds an occurrence outside it"
        EndedBefore(key:) ->
          "the record under " <> key <> " ended before it was recommended"
      }
    StoreFailed(error:) -> store.describe(error)
  }
}

// -- Recommending -----------------------------------------------------------------

/// Record a recommendation under a new id and apply the policy. When the
/// policy proceeds and the point has no hold, the gated tool runs here,
/// once; when it refuses, the occurrence ends `Refused`. When the
/// proposal's own deadline (`valid_until`) has already passed, the
/// recommendation is recorded and expires at once, and no policy runs.
pub fn recommend(
  desk: Desk(o, tx),
  tx: tx,
  proposal: Proposal(o),
) -> Result(Occurrence(o), Refusal) {
  let id = desk.port.new_id(tx)
  use now <- result.try(clock(desk, tx))
  begin(desk, tx, id, proposal, None, [], None, now)
}

/// `recommend`, at most once per `key`, which becomes the occurrence's id.
/// A trigger delivered again finds the occurrence it already made and
/// writes nothing. Safe under concurrent deliveries because the port locks
/// a key that does not exist yet. Keys are one namespace across every
/// point of a store: a key another point's occurrence holds is refused
/// with `KeyTaken`, so prefix keys with something the point owns.
///
/// An expectation (`expect`) and failed attempts recorded under the key
/// stay at the start of the record. A key that a newer event superseded
/// before it was recommended is refused with `SupersededBefore(event)`, and
/// nothing is written, shown or released: the work in flight is moot.
///
/// **Deadlines.** The deadline written on the recommendation is the
/// earliest of the point's validity counted from now, the deadline the
/// key's expectations carry (`expect_until`) and the proposal's
/// (`valid_until`). When the occurrence's own deadline (the key's or the
/// proposal's) has already passed by the store clock, the recommendation
/// is recorded and the occurrence expires at once with
/// `DeadlinePassed`: no policy runs and nothing is shown or released, and
/// the expired occurrence is returned, so the late output stays on the
/// record. That holds whether or not the wake-up that expires the key was
/// delivered first; when it was not, the expiry is written before the
/// recommendation, so the record has one shape either way.
///
/// **The superseding window.** `happened` supersedes what the record holds
/// when it runs. Call `expect` with this key in the transaction that
/// receives the trigger, and the record holds it while the model works;
/// the window stays open only for a key that was not expected first.
pub fn recommend_once(
  desk: Desk(o, tx),
  tx: tx,
  key key: String,
  proposal proposal: Proposal(o),
) -> Result(Occurrence(o), Refusal) {
  admit_once(desk, tx, key, proposal, None)
}

/// `recommend_once` under `key`, as a member of `bundle` when it names one.
fn admit_once(
  desk: Desk(o, tx),
  tx: tx,
  key: String,
  proposal: Proposal(o),
  bundle: Option(Bundle),
) -> Result(Occurrence(o), Refusal) {
  use #(entries, now) <- result.try(fetch(desk, tx, key))
  case occurrence.fold(key, entries) {
    Ok(found) -> {
      use found <- result.try(mine(desk, found))
      // A trigger delivered again finds its occurrence; a key that holds
      // an occurrence outside the bundle would leave the bundle short.
      case found.bundle == bundle, bundle {
        True, _ -> Ok(found)
        False, Some(bundle) ->
          Error(BadBundle(
            bundle: vocabulary.bundle_key(bundle),
            fault: KeyOutsideBundle(key),
          ))
        False, None -> Ok(found)
      }
    }
    Error(occurrence.NoEntries) ->
      begin(desk, tx, key, proposal, bundle, [], None, now)
    Error(occurrence.NotYet(pending)) ->
      case pending.ended {
        Some(Superseded(event:)) -> Error(SupersededBefore(event:))
        Some(vocabulary.DeadlinePassed) | None ->
          begin(desk, tx, key, proposal, bundle, entries, Some(pending), now)
      }
    Error(occurrence.NoRecommendation) -> Error(not_a_record())
  }
}

/// Admit the occurrences one recommendation proposed together, at this
/// desk's point, as one bundle: `recommend_member` for each item, with the
/// bundle's size the number of items. Call it in one transaction, so the
/// bundle is admitted whole or not at all. A trigger delivered again finds
/// every occurrence it already made and writes nothing. The occurrences
/// come back in the order of `items`.
///
/// Each item names its member (`vocabulary.item`, which refuses an empty
/// name or a slash), and the member's key is `member_key(bundle, item)`.
/// An empty key or empty `items` is refused
/// with `BadBundle(Malformed(..))`, and an item given twice with
/// `BadBundle(RepeatedItem(item))`, before anything is written. For a
/// bundle that spans several points, call `recommend_member` at each
/// point's desk.
pub fn recommend_bundle(
  desk: Desk(o, tx),
  tx: tx,
  bundle key: String,
  items items: List(#(Item, Proposal(o))),
) -> Result(List(Occurrence(o)), Refusal) {
  let names = list.map(items, fn(item) { vocabulary.item_name(item.0) })
  let repeated =
    list.find(names, fn(item) { list.count(names, fn(n) { n == item }) > 1 })
  case vocabulary.bundle(key:, size: list.length(items)), repeated {
    Error(malformed), _ ->
      Error(BadBundle(bundle: key, fault: Malformed(malformed)))
    _, Ok(item) -> Error(BadBundle(bundle: key, fault: RepeatedItem(item)))
    Ok(bundle), Error(Nil) -> {
      use Nil <- result.try(lock_bundle(desk, tx, bundle))
      list.try_map(items, fn(item) {
        admit_once(desk, tx, member_key(bundle, item.0), item.1, Some(bundle))
      })
    }
  }
}

/// Admit one occurrence of `bundle`, named `item`, at this desk's point:
/// `recommend_once` under `member_key(bundle, item)`. Members of one
/// bundle may belong to several points and be admitted in several
/// transactions. A trigger delivered again finds its member and writes
/// nothing.
///
/// The desk refuses, with `BadBundle`, a size that differs from the one a
/// member already recorded, a member beyond the size, a key that already
/// holds an occurrence outside the bundle, and a key whose record ended
/// before it was recommended. It first loads `bundle_lock(bundle)`
/// through the port, which locks that id for the rest of the transaction,
/// so two transactions admitting members of one bundle run one after the
/// other and the second sees the first's member: the bundle never holds
/// more members than its size. Locks are taken in one order: the bundle
/// lock, then the member's key; in a transaction that also expects a
/// member of the same bundle, admit members first. Expect the member, or
/// record its failed attempts, under `member_key(bundle, item)`.
pub fn recommend_member(
  desk: Desk(o, tx),
  tx: tx,
  of bundle: Bundle,
  item item: Item,
  proposal proposal: Proposal(o),
) -> Result(Occurrence(o), Refusal) {
  use Nil <- result.try(lock_bundle(desk, tx, bundle))
  admit_once(desk, tx, member_key(bundle, item), proposal, Some(bundle))
}

/// The key of the member `item` of `bundle`: the bundle's key, a slash and
/// the item, such as `"report-7/l1"`. It is the member's occurrence id.
/// An item holds no slash, so two members of different bundles never
/// share a key: the key's last slash ends the bundle's key.
pub fn member_key(bundle: Bundle, item: Item) -> String {
  vocabulary.bundle_key(bundle) <> "/" <> vocabulary.item_name(item)
}

/// The prefix of every bundle lock id (`bundle_lock`). It is reserved: do
/// not use it for keys of your own.
pub const bundle_lock_prefix = "decisions.bundle-lock:"

/// The id `recommend_member` and `recommend_bundle` load, purely as a
/// lock, before they count a bundle's members: `bundle_lock_prefix`
/// followed by the lowercase hex SHA-256 of the bundle's key. No entry is
/// ever stored under it.
pub fn bundle_lock(bundle: Bundle) -> String {
  bundle_lock_prefix
  <> crypto.hash(
    crypto.Sha256,
    bit_array.from_string(vocabulary.bundle_key(bundle)),
  )
  |> bit_array.base16_encode
  |> string.lowercase
}

fn lock_bundle(
  desk: Desk(o, tx),
  tx: tx,
  bundle: Bundle,
) -> Result(Nil, Refusal) {
  desk.port.load(tx, bundle_lock(bundle))
  |> result.map_error(StoreFailed)
  |> result.replace(Nil)
}

/// An occurrence of a bundle, as its head stands: what `members` returns.
pub type Member {
  Member(
    occurrence: String,
    /// The decision point it is an occurrence of.
    point: String,
    status: store.Status,
    /// The bundle's size as this member recorded it.
    size: Int,
  )
}

/// The occurrences of the bundle `key`, of every point, in ascending id
/// order, as the store holds them now. It writes nothing and locks
/// nothing. Empty for a key no occurrence names.
///
/// Whoever follows the bundle's points calls it with each settlement
/// notice and starts what follows once `is_complete` holds, with
/// `recommend_once` under a key derived from the bundle. A follower runs
/// after the settlement it was told of committed, so the follower of the
/// member that committed last sees every member settled; followers of
/// earlier members may see it too, and `recommend_once` makes their extra
/// calls write nothing. A follower must check, not assume: a bundle whose
/// last notice is never delivered stays complete with nothing started.
pub fn members(
  desk: Desk(o, tx),
  tx: tx,
  bundle key: String,
) -> Result(List(Member), Refusal) {
  use found <- result.map(
    desk.port.members(tx, key) |> result.map_error(StoreFailed),
  )
  list.filter_map(found, fn(pair) {
    let #(id, head) = pair
    case head.bundle {
      Some(bundle) ->
        case vocabulary.bundle_key(bundle) == key {
          True ->
            Ok(Member(
              occurrence: id,
              point: head.point,
              status: head.status,
              size: vocabulary.bundle_size(bundle),
            ))
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

/// Whether a bundle is complete: it has as many members as every member
/// says it holds, and every one has settled (released, rejected, expired,
/// withdrawn or refused). A bundle still arriving, or one whose members
/// disagree on its size, is not.
pub fn is_complete(members: List(Member)) -> Bool {
  let count = list.length(members)
  count > 0
  && list.all(members, fn(member) {
    member.size == count && store.is_settled(member.status)
  })
}

/// Whether `bundle`, if there is one, can take occurrence `id`: the size its
/// other members recorded, and room for one more. The caller holds the
/// bundle's lock.
fn admits_member(
  desk: Desk(o, tx),
  tx: tx,
  id: String,
  bundle: Option(Bundle),
) -> Result(Nil, Refusal) {
  case bundle {
    None -> Ok(Nil)
    Some(bundle) -> {
      let key = vocabulary.bundle_key(bundle)
      let size = vocabulary.bundle_size(bundle)
      use found <- result.try(members(desk, tx, bundle: key))
      let others = list.filter(found, fn(member) { member.occurrence != id })
      case list.find(others, fn(member) { member.size != size }) {
        Ok(member) ->
          Error(BadBundle(
            bundle: key,
            fault: SizeDiffers(recorded: member.size),
          ))
        Error(Nil) ->
          case list.length(others) >= size {
            True -> Error(BadBundle(bundle: key, fault: BundleFull))
            False -> Ok(Nil)
          }
      }
    }
  }
}

/// Record, in the transaction that receives a trigger, that a
/// recommendation is expected under `key` about `subject`. From then on
/// the record holds the key, so `happened` for a newer event about the
/// subject supersedes it like any waiting occurrence, and the
/// `recommend_once` that follows for this key is refused with
/// `SupersededBefore`. Call it in the same transaction as the `happened`
/// that the trigger itself reports, **after** that `happened`, and in the
/// transaction that admits the job that will recommend, so the expectation
/// and the job exist together or not at all.
///
/// `happened` takes the subject lock and then the records' locks; `expect`
/// before `happened` would take a record's lock first, which could
/// deadlock with a transaction that keeps that order, and the `happened`
/// would supersede the key just expected. `expect` takes no subject lock
/// itself: what orders two admissions about one subject is the `happened`
/// each runs first.
///
/// Safe to repeat: an expected key is recorded once. On a key that already
/// holds a recommendation it does nothing; on a key another point holds it
/// is refused with `KeyTaken`; on a key already superseded it is refused
/// with `SupersededBefore`, and on one whose own deadline passed with
/// `DeadlinePassedBefore`. An expectation made with `expect` has no
/// deadline: a record that stays expected (its worker died for good) keeps
/// the head status `Pending` and its arrival time, which a queue or an
/// operator can ask for. To give it one, use `expect_until`.
pub fn expect(
  desk: Desk(o, tx),
  tx: tx,
  key key: String,
  trigger trigger: Trigger,
  about subject: Subject,
) -> Result(Nil, Refusal) {
  expect_with(desk, tx, key, trigger, subject, None)
}

/// `expect`, with the occurrence's own deadline: an instant the
/// application knows when it admits the trigger, such as the end of a
/// service window. It is written on the `expected` entry, in whole
/// milliseconds rounded down, and the record is due at it: its head's due
/// time is the deadline and a wake-up is scheduled for it.
///
/// At or after the deadline by the store clock the record is lapsed,
/// whether or not that wake-up was delivered: `wake` expires it with
/// `DeadlinePassed` and admits its settlement notice, and `expect`,
/// `expect_until`, `record_failure`, `record_failure_with`, `read` and
/// every verb that needs an occurrence are refused with
/// `DeadlinePassedBefore` and write nothing. A recommendation that comes
/// after is still recorded, and starts expired (`recommend_once`). The
/// deadline the recommendation carries is the earliest of this one, the
/// point's validity and the proposal's.
///
/// Repeated with an earlier deadline, it appends another expectation and
/// the earliest counts; with an equal or later one it writes nothing: a
/// deadline never moves later. On a key that already holds a
/// recommendation it does nothing. When the deadline has already passed,
/// the expectation is written with its expiry at once, so the transaction
/// that received the trigger can still commit.
pub fn expect_until(
  desk: Desk(o, tx),
  tx: tx,
  key key: String,
  trigger trigger: Trigger,
  about subject: Subject,
  valid_until deadline: Timestamp,
) -> Result(Nil, Refusal) {
  expect_with(
    desk,
    tx,
    key,
    trigger,
    subject,
    Some(whole_milliseconds(deadline)),
  )
}

fn expect_with(
  desk: Desk(o, tx),
  tx: tx,
  key: String,
  trigger: Trigger,
  subject: Subject,
  deadline: Option(Timestamp),
) -> Result(Nil, Refusal) {
  use #(entries, now) <- result.try(fetch(desk, tx, key))
  let expected =
    entry.Expected(
      point: desk.point.name,
      trigger:,
      subject:,
      valid_until: deadline,
    )
  case occurrence.fold(key, entries) {
    Ok(found) -> mine(desk, found) |> result.replace(Nil)
    Error(occurrence.NoRecommendation) -> Error(not_a_record())
    Error(occurrence.NotYet(pending)) -> {
      use Nil <- result.try(still_open(pending, now))
      let earlier = case deadline, pending.valid_until {
        Some(new), Some(old) -> timestamp.compare(new, old) == order.Lt
        Some(_), None -> True
        None, _ -> False
      }
      case pending.expected && !earlier {
        True -> Ok(Nil)
        False ->
          write_pending(desk, tx, key, entries, Some(pending), expected, now)
          |> result.replace(Nil)
      }
    }
    Error(occurrence.NoEntries) ->
      write_pending(desk, tx, key, entries, None, expected, now)
      |> result.replace(Nil)
  }
}

/// A record that has not begun may still be expected or attempted: it has
/// not ended, and its own deadline has not passed by the store clock.
fn still_open(
  pending: occurrence.Pending,
  now: Timestamp,
) -> Result(Nil, Refusal) {
  case pending.ended, occurrence.pending_has_lapsed(pending, now) {
    Some(cause), _ -> Error(ended_before(pending, cause))
    None, True -> Error(deadline_passed_before(pending))
    None, False -> Ok(Nil)
  }
}

fn ended_before(
  pending: occurrence.Pending,
  cause: vocabulary.ExpiryCause,
) -> Refusal {
  case cause {
    Superseded(event:) -> SupersededBefore(event:)
    vocabulary.DeadlinePassed -> deadline_passed_before(pending)
  }
}

fn deadline_passed_before(pending: occurrence.Pending) -> Refusal {
  // `fold` reads a record that ended by a deadline it never had as
  // unreadable, so a pending record here always has one.
  DeadlinePassedBefore(deadline: option.unwrap(
    pending.valid_until,
    timestamp.unix_epoch,
  ))
}

/// Append one entry to a record that has not begun, with its head. When
/// the entry leaves the record lapsed (an expectation whose deadline has
/// already passed), its expiry is appended with it. The record's wake-up
/// follows its deadline, and its settlement notice is admitted when it
/// ends now.
fn write_pending(
  desk: Desk(o, tx),
  tx: tx,
  key: String,
  entries: List(Entry(o)),
  before: Option(occurrence.Pending),
  event: Event(o),
  now: Timestamp,
) -> Result(occurrence.Pending, Refusal) {
  let added = pending_entries(entries, [event], now)
  let added = case occurrence.fold(key, list.append(entries, added)) {
    Error(occurrence.NotYet(pending)) ->
      case occurrence.pending_has_lapsed(pending, now) {
        True ->
          pending_entries(
            entries,
            [event, entry.Expired(vocabulary.DeadlinePassed)],
            now,
          )
        False -> added
      }
    _ -> added
  }
  case occurrence.fold(key, list.append(entries, added)) {
    Error(occurrence.NotYet(pending)) -> {
      use stored <- result.try(encode(added, desk.point.output))
      let was = option.map(before, occurrence.pending_wake_times)
      let wakes = occurrence.pending_wake_times(pending)
      let ends =
        pending.ended != None && option.then(before, fn(b) { b.ended }) == None
      {
        use Nil <- result.try(desk.port.append(
          tx,
          key,
          occurrence.pending_head(pending),
          stored,
        ))
        use Nil <- result.try(case option.unwrap(was, []) == wakes {
          True -> Ok(Nil)
          False -> desk.port.schedule(tx, desk.point.name, key, wakes)
        })
        case ends {
          True -> desk.port.settled(tx, desk.point.name, key)
          False -> Ok(Nil)
        }
      }
      |> result.map_error(StoreFailed)
      |> result.replace(pending)
    }
    _ -> Error(not_a_record())
  }
}

fn pending_entries(
  entries: List(Entry(o)),
  events: List(Event(o)),
  now: Timestamp,
) -> List(Entry(o)) {
  let first = list.length(entries) + 1
  list.index_map(events, fn(event, index) {
    entry.Entry(seq: first + index, at: now, event:)
  })
}

/// Record that a recommender failed under `key` before anything was
/// recommended. Call it in a transaction of its own, after the one the
/// attempt ran in rolled back, so the record shows that the trigger was
/// tried and why it failed. Returns every failed attempt so far, from
/// which a caller decides on another try (see `model.retryable`). When
/// the key already holds a recommendation, nothing is written. When a
/// newer event superseded the key before it was recommended, nothing is
/// written and the result is `Error(SupersededBefore(event))`: do not try
/// again. When the key's own deadline (`expect_until`) has passed by the
/// store clock, nothing is written and the result is
/// `Error(DeadlinePassedBefore(deadline))`: do not try again either.
///
/// Each call records one attempt, so repeating a call records the attempt
/// again: two attempts that failed alike look the same, and the desk
/// cannot tell a second attempt from a repeated call. After an
/// `Unavailable` outcome, read the record first (`read` returns
/// `NotRecommended(attempts)`) and call again only if the attempt is not
/// there.
///
/// The record lives under whatever `key` you give, before any occurrence
/// exists, so give the key `recommend_once` will use for the same trigger:
/// then the attempts and the recommendation that follows share one record.
/// A failure that carries evidence (`model.with_evidence`) is recorded with
/// it.
pub fn record_failure(
  desk: Desk(o, tx),
  tx: tx,
  key key: String,
  trigger trigger: Trigger,
  about subject: Subject,
  failure failure: Failure,
) -> Result(List(Attempt), Refusal) {
  record_failure_with(
    desk,
    tx,
    key:,
    trigger:,
    about: subject,
    failure:,
    evidence: [],
  )
}

/// `record_failure`, pointing at evidence the application stored about
/// the attempt, such as a provider exchange that did not decode. The
/// evidence a failure carries itself (`model.with_evidence`) is added.
pub fn record_failure_with(
  desk: Desk(o, tx),
  tx: tx,
  key key: String,
  trigger trigger: Trigger,
  about subject: Subject,
  failure failure: Failure,
  evidence evidence: List(Ref),
) -> Result(List(Attempt), Refusal) {
  use #(entries, now) <- result.try(fetch(desk, tx, key))
  let attempt =
    entry.AttemptFailed(
      point: desk.point.name,
      trigger:,
      subject:,
      failure: model.without_evidence(failure),
      evidence: list.append(evidence, model.evidence_of(failure)),
    )
  case occurrence.fold(key, entries) {
    Ok(found) -> mine(desk, found) |> result.map(fn(found) { found.attempts })
    Error(occurrence.NoRecommendation) -> Error(not_a_record())
    Error(occurrence.NotYet(pending)) -> {
      use Nil <- result.try(still_open(pending, now))
      write_pending(desk, tx, key, entries, Some(pending), attempt, now)
      |> result.map(fn(pending) { pending.attempts })
    }
    Error(occurrence.NoEntries) ->
      write_pending(desk, tx, key, entries, None, attempt, now)
      |> result.map(fn(pending) { pending.attempts })
  }
}

/// Begin an occurrence under `id` with the proposal, after what the record
/// already holds (`prior`, a record not begun when `pending` is given).
/// The recommendation carries the effective deadline. When the
/// occurrence's own deadline (the record's or the proposal's) has passed,
/// the occurrence is recorded expired and no policy runs; a record not
/// begun that lapsed and was not yet expired is expired first, so a late
/// recommendation always follows the expiry.
fn begin(
  desk: Desk(o, tx),
  tx: tx,
  id: String,
  proposal: Proposal(o),
  bundle: Option(Bundle),
  prior: List(Entry(o)),
  pending: Option(occurrence.Pending),
  now: Timestamp,
) -> Result(Occurrence(o), Refusal) {
  let faults =
    fact_faults(desk.point, proposal.recommendation.signals, from: fn(source) {
      case source {
        FromSignal(..) -> True
        FromOutput(..) | FromAnswer(..) -> False
      }
    })
  use Nil <- result.try(check(faults == [], InvalidFacts(faults)))
  use Nil <- result.try(admits_member(desk, tx, id, bundle))
  use Nil <- result.try(case bundle, pending {
    Some(bundle), Some(occurrence.Pending(ended: Some(_), ..)) ->
      Error(BadBundle(
        bundle: vocabulary.bundle_key(bundle),
        fault: EndedBefore(id),
      ))
    _, _ -> Ok(Nil)
  })
  // The deadline the occurrence was given itself, on its expectation or
  // its proposal; the point's validity bounds it further.
  let own =
    occurrence.earliest(
      option.values([
        option.then(pending, fn(pending) { pending.valid_until }),
        proposal.valid_until,
      ]),
    )
  let deadline =
    occurrence.earliest(
      option.values([
        option.map(desk.point.validity, timestamp.add(now, _)),
        own,
      ]),
    )
  // Only the occurrence's own deadline can have passed before it is
  // recommended; a point's validity, counted from now, is applied by the
  // policy and the wake-ups as it always was.
  let own_passed = case own {
    Some(at) -> timestamp.compare(now, at) != order.Lt
    None -> False
  }
  let lapsed_first = case pending {
    Some(pending) -> occurrence.pending_has_lapsed(pending, now)
    None -> False
  }
  let expiry = case lapsed_first {
    True -> [
      entry.Entry(
        seq: list.length(prior) + 1,
        at: now,
        event: entry.Expired(vocabulary.DeadlinePassed),
      ),
    ]
    False -> []
  }
  let prior_written = list.append(prior, expiry)
  let first =
    entry.Entry(
      seq: list.length(prior_written) + 1,
      at: now,
      event: entry.Recommended(
        point: desk.point.name,
        trigger: proposal.trigger,
        parent: proposal.parent,
        subject: proposal.subject,
        requester: case proposal.requester, proposal.recommendation.by {
          Some(requester), _ -> Some(requester)
          None, Person(subject:) -> Some(subject)
          None, _ -> None
        },
        context: proposal.context,
        recommendation: proposal.recommendation,
        valid_until: deadline,
        bundle:,
      ),
    )
  case occurrence.fold(id, list.append(prior_written, [first])) {
    Ok(recommended) -> {
      let draft =
        Draft(
          occurrence: recommended,
          saved: list.length(prior),
          now:,
          // What the record not begun had pending, so saving replaces it.
          wakes: option.map(pending, occurrence.pending_wake_times)
            |> option.unwrap([]),
          // A record that ended by its deadline already admitted its notice.
          settled: option.then(pending, fn(pending) { pending.ended }) != None,
        )
      case recommended.status, own_passed {
        // Expired before it began: kept on the record, nothing more runs.
        occurrence.Expired(_), _ -> save(desk, tx, draft)
        // Its own deadline has passed already: expired at once, no policy.
        _, True ->
          add(draft, entry.Expired(vocabulary.DeadlinePassed))
          |> save(desk, tx, _)
        _, False -> settle(desk, tx, draft)
      }
    }
    Error(_) -> Error(not_a_record())
  }
}

// -- Cards --------------------------------------------------------------------------

/// The only way to a verdict: an occurrence as it was shown to one
/// validator. Only `open` and `resume` construct one. Its output type ties
/// it to points of that output type at compile time; two points with one
/// output type are told apart at run time, where a desk refuses another
/// point's occurrence with `UnknownOccurrence`.
pub opaque type Card(output) {
  Card(
    occurrence: Occurrence(output),
    validator: Validator,
    seen: Int,
    allowed: Verdicts,
  )
}

/// What a card is known by outside this process: the occurrence and the
/// entry that showed it. A page or another system keeps this and nothing
/// else, and gets the card back with `resume`.
pub type Ticket {
  Ticket(occurrence: String, seen: Int)
}

/// Show an occurrence to a validator, and record the showing. Only an
/// occurrence a verdict can be given on opens: one waiting for verdicts,
/// to a holder of a set it waits for (`NotEligible` otherwise), or one
/// released and sampled, for its review. Any other is refused with what
/// a card would run into: `AlreadyDecided(by)` when someone's verdict
/// settled it, `NotSampled` when the policy released it unsampled, and
/// `NotAwaiting` otherwise (waiting for a consulted point, expired,
/// withdrawn, refused, or its validity has passed). A queue page read
/// before the lock learns it here.
///
/// The showing records every input (a context reference or one of the
/// model's reads) whose `latest` revision differs from the one the model
/// had. Drift says only that the content differs now: it cannot tell a
/// change in the world from one the release itself caused (a read of
/// "does the patient exist" differs once the release created them).
pub fn open(
  desk: Desk(o, tx),
  tx: tx,
  occurrence id: String,
  by validator: Validator,
  latest latest: fn(Ref) -> String,
) -> Result(Card(o), Refusal) {
  use draft <- result.try(load(desk, tx, id))
  let current = draft.occurrence
  use Nil <- result.try(live(draft))
  use Nil <- result.try(may_look(desk, current, validator))
  let allowed = desk.point.verdicts
  use Nil <- result.try(check(is_showing(current), nothing_to_do(current)))
  case showing(current, by: validator, latest:) {
    // The same showing, so the record does not grow with every view.
    Some(Ticket(seen:, ..)) ->
      Ok(Card(occurrence: current, validator:, seen:, allowed:))
    None -> {
      let drift = drifted(current, latest)
      let draft =
        add(draft, entry.Opened(by: validator.subject, drifted: drift))
      let seen = list.length(draft.occurrence.entries)
      save(desk, tx, draft)
      |> result.map(Card(occurrence: _, validator:, seen:, allowed:))
    }
  }
}

/// The card's ticket.
pub fn ticket(card: Card(o)) -> Ticket {
  Ticket(occurrence: card.occurrence.id, seen: card.seen)
}

/// The validator's showing that `open` returns again instead of recording
/// a new one, or `None` when `open` would record a new showing.
///
/// The rule: the validator's latest showing is the same showing while
/// nothing but showings (to anyone) was recorded after it, and every
/// input (a context reference or one of the model's reads) drifted to the
/// same `latest` revision it drifted to then. Any other entry after it, or
/// a change in drift, makes the next `open` a new showing. `open` applies
/// this function, so the answer is the one it gives.
///
/// It reads only the occurrence it is given, so an occurrence read without
/// a lock can be out of date. A ticket from it is checked under the lock
/// by `resume` (`NeverShown`, `OutputChanged`, `NotAwaiting`). It says
/// nothing about whether `open` would admit the validator.
pub fn showing(
  occurrence current: Occurrence(o),
  by validator: Validator,
  latest latest: fn(Ref) -> String,
) -> Option(Ticket) {
  let drift = drifted(current, latest)
  let shown =
    list.filter_map(current.entries, fn(entry) {
      case entry.event {
        entry.Opened(by:, drifted:) if by == validator.subject ->
          Ok(#(entry.seq, drifted))
        _ -> Error(Nil)
      }
    })
    |> list.last
  case shown {
    Ok(#(seen, recorded)) if recorded == drift ->
      case
        list.all(current.entries, fn(entry) {
          case entry.event {
            entry.Opened(..) -> True
            _ -> entry.seq <= seen
          }
        })
      {
        True -> Some(Ticket(occurrence: current.id, seen:))
        False -> None
      }
    _ -> None
  }
}

/// The card again, in a later request, from its ticket. It is the same
/// showing, so nothing is recorded. A ticket that names no showing of
/// this occurrence to this validator is refused with `NeverShown`; one
/// shown before the output was corrected by someone else, with
/// `OutputChanged`; one whose occurrence's validity has passed, with
/// `NotAwaiting`.
pub fn resume(
  desk: Desk(o, tx),
  tx: tx,
  ticket: Ticket,
  by validator: Validator,
) -> Result(Card(o), Refusal) {
  use draft <- result.try(load(desk, tx, ticket.occurrence))
  let current = draft.occurrence
  use Nil <- result.try(check(
    was_shown(current, validator, ticket.seen),
    NeverShown,
  ))
  use Nil <- result.try(live(draft))
  use Nil <- result.try(check(
    !is_stale(current, validator, ticket.seen),
    OutputChanged,
  ))
  // Admitted as `decide` would admit them. An approver may resume their
  // card, so that the same verdict sent again on it stands.
  use Nil <- result.try(case current.status {
    occurrence.Awaiting(eligible:) ->
      check(
        occurrence.admits(current, eligible, validator.subject, validator.holds),
        NotEligible,
      )
    _ -> Ok(Nil)
  })
  Ok(Card(
    occurrence: current,
    validator:,
    seen: ticket.seen,
    allowed: desk.point.verdicts,
  ))
}

/// The occurrence as the card shows it, with every entry recorded up to
/// the card's last action.
pub fn shown(card: Card(o)) -> Occurrence(o) {
  card.occurrence
}

/// Who holds the card.
pub fn holder(card: Card(o)) -> Validator {
  card.validator
}

/// The verdicts the card's point allows.
pub fn allowed(card: Card(o)) -> Verdicts {
  card.allowed
}

/// The validator opened more than the card showed. `result` is the
/// captured evidence of what that read returned (see `model.capture`).
pub fn expand(
  desk: Desk(o, tx),
  tx: tx,
  card: Card(o),
  read read: String,
  result captured: Ref,
) -> Result(Card(o), Refusal) {
  act(
    desk,
    tx,
    card,
    entry.Expanded(by: card.validator.subject, read:, result: captured),
  )
}

/// The validator enters what they know from outside the card.
pub fn note(
  desk: Desk(o, tx),
  tx: tx,
  card: Card(o),
  note: String,
) -> Result(Card(o), Refusal) {
  act(desk, tx, card, entry.Noted(by: card.validator.subject, note:))
}

fn act(
  desk: Desk(o, tx),
  tx: tx,
  card: Card(o),
  event: Event(o),
) -> Result(Card(o), Refusal) {
  use draft <- result.try(load(desk, tx, card.occurrence.id))
  use Nil <- result.try(check(is_showing(draft.occurrence), NotAwaiting))
  use Nil <- result.try(live(draft))
  add(draft, event)
  |> save(desk, tx, _)
  |> result.map(fn(occurrence) { Card(..card, occurrence:) })
}

/// Why a card for this occurrence would be of no use: someone's verdict
/// settled it, it waits for something other than verdicts, or it was
/// released without being sampled for review.
fn nothing_to_do(current: Occurrence(o)) -> Refusal {
  case settled_by_verdict(current), current.status {
    Ok(by), _ -> AlreadyDecided(by:)
    Error(Nil), occurrence.Released(..) -> NotSampled
    Error(Nil), _ -> NotAwaiting
  }
}

/// Who settled the occurrence with a verdict: the validator whose verdict
/// accepted it (it is accepted, held or released by them) or rejected it.
/// `Error(Nil)` when no verdict settled it, for one when it expired after a
/// partial approval.
fn settled_by_verdict(current: Occurrence(o)) -> Result(String, Nil) {
  case current.status {
    occurrence.Accepted(by: occurrence.ByValidator(subject:), ..)
    | occurrence.Held(by: occurrence.ByValidator(subject:), ..)
    | occurrence.Released(by: occurrence.ByValidator(subject:), ..) ->
      Ok(subject)
    occurrence.Rejected(_) ->
      list.last(occurrence.verdicts(current))
      |> result.map(fn(given) { given.0 })
    _ -> Error(Nil)
  }
}

/// Waiting for a verdict, or released and waiting for its sampled review.
fn is_showing(current: Occurrence(o)) -> Bool {
  case current.status {
    occurrence.Awaiting(_) -> True
    occurrence.Released(..) -> current.sampled
    _ -> False
  }
}

fn drifted(current: Occurrence(o), latest: fn(Ref) -> String) -> List(Ref) {
  list.append(current.context.refs, current.recommendation.reads)
  |> list.filter_map(fn(ref) {
    case latest(ref) {
      revision if revision == ref.revision -> Error(Nil)
      revision -> Ok(Ref(..ref, revision:))
    }
  })
}

/// Whether `validator` may review a sampled release: not whoever decided
/// it, asked for it, recommended it as their own act or reviewed it, and,
/// when the point names reviewers, a holder of that set.
fn may_review(
  desk: Desk(o, tx),
  current: Occurrence(o),
  validator: Validator,
) -> Bool {
  let who = validator.subject
  let excluded =
    current.requester == Some(who)
    || current.recommendation.by == Person(who)
    || list.any(occurrence.verdicts(current), fn(given) { given.0 == who })
    || list.any(occurrence.reviews(current), fn(given) { given.0 == who })
    || case desk.point.reviewers {
      Some(set) -> !list.contains(validator.holds, set)
      None -> False
    }
  !excluded
}

/// A waiting occurrence is shown only to holders of a set it waits for,
/// and one waiting for its review only to the point's reviewers.
fn may_look(
  desk: Desk(o, tx),
  current: Occurrence(o),
  validator: Validator,
) -> Result(Nil, Refusal) {
  case current.status, desk.point.reviewers {
    // The same rule `decide` applies: admitted, and not already an
    // approver of the output that stands.
    occurrence.Awaiting(eligible:), _ ->
      check(is_eligible(eligible, validator, current), NotEligible)
    // The same rule `review` applies to a sampled release.
    occurrence.Released(..), _ if current.sampled ->
      check(may_review(desk, current, validator), NotEligible)
    _, _ -> Ok(Nil)
  }
}

/// Refused with `NotAwaiting` once the validity of an undecided
/// occurrence has passed, whether or not its wake-up was delivered.
fn live(draft: Draft(o)) -> Result(Nil, Refusal) {
  check(!occurrence.has_lapsed(draft.occurrence, draft.now), NotAwaiting)
}

/// A showing of the occurrence to this validator is recorded at `seen`.
fn was_shown(current: Occurrence(o), validator: Validator, seen: Int) -> Bool {
  list.any(current.entries, fn(entry) {
    case entry.seq == seen, entry.event {
      True, entry.Opened(by:, ..) -> by == validator.subject
      _, _ -> False
    }
  })
}

/// Someone corrected the output after the card was shown, on another
/// showing: the card shows an output that no longer stands.
fn is_stale(current: Occurrence(o), validator: Validator, seen: Int) -> Bool {
  list.any(current.entries, fn(entry) {
    case entry.event {
      entry.Decided(by:, verdict: Correct(..), seen: given_on, ..) ->
        entry.seq > seen && { by != validator.subject || given_on != seen }
      _ -> False
    }
  })
}

// -- Verdicts -------------------------------------------------------------------------

/// The verdict an occurrence waits for. An accepted output is held when
/// the point has a hold, and released otherwise, in this transaction: the
/// guard and the gated tool run here. A refusal at release is
/// `Error(ToolRefused(reason, rollback))`: roll the transaction back, then
/// keep the attempt with `record_refusal(rollback)`.
///
/// The card must be a recorded showing to its holder (`NeverShown`), shown
/// after the last correction by anyone else (`OutputChanged`), and the
/// validity must not have passed (`NotAwaiting`), whether or not the
/// wake-up that expires it was delivered.
///
/// The same verdict sent again on the same card returns the occurrence and
/// runs nothing. Under `Several`, a validator gives one verdict per output
/// that stands: after approving, they may not reject or correct the same
/// output (`NotEligible`); after someone else corrects it, they decide
/// again on the new output.
pub fn decide(
  desk: Desk(o, tx),
  tx: tx,
  card: Card(o),
  verdict: Verdict(o),
) -> Result(Occurrence(o), Refusal) {
  use draft <- result.try(load(desk, tx, card.occurrence.id))
  let validator = card.validator
  let waiting = draft.occurrence
  let given_here =
    list.any(waiting.entries, fn(entry) {
      case entry.event {
        entry.Decided(by:, verdict: given, seen:, ..) ->
          by == validator.subject && given == verdict && seen == card.seen
        _ -> False
      }
    })
  // The same verdict on the same card, sent again, stands: once the
  // occurrence has moved on, or while that approval still counts.
  let stands =
    given_here
    && {
      !occurrence.is_undecided(waiting.status)
      || list.contains(occurrence.standing(waiting).1, validator.subject)
    }
  case stands, waiting.status {
    True, _ -> Ok(waiting)
    False, occurrence.Awaiting(eligible:) -> {
      use Nil <- result.try(check(
        was_shown(waiting, validator, card.seen),
        NeverShown,
      ))
      use Nil <- result.try(live(draft))
      use Nil <- result.try(check(
        !is_stale(waiting, validator, card.seen),
        OutputChanged,
      ))
      use Nil <- result.try(check(
        is_eligible(eligible, validator, waiting),
        NotEligible,
      ))
      use Nil <- result.try(allowed_verdict(
        desk.point,
        waiting,
        validator,
        verdict,
      ))
      let draft =
        add(
          draft,
          entry.Decided(
            by: validator.subject,
            verdict:,
            seen: card.seen,
            holds: validator.holds,
          ),
        )
      case draft.occurrence.status {
        occurrence.Accepted(..) ->
          accept(desk, tx, draft, None, Some(#(validator, card.seen, verdict)))
          |> result.try(save(desk, tx, _))
        // Rejected, or more approvals are needed.
        _ -> save(desk, tx, draft)
      }
    }
    False, _ ->
      Error(case settled_by_verdict(waiting) {
        Ok(by) -> AlreadyDecided(by:)
        Error(Nil) -> NotAwaiting
      })
  }
}

/// Keep on the record a verdict whose release was refused. Call it in a
/// transaction of its own, after `decide` returned
/// `ToolRefused(reason, rollback)` and its transaction rolled back. It
/// changes no status. Only the desk makes a `Rollback`, so nothing else can
/// be recorded this way. It is safe to repeat: the token names one refused
/// verdict (its validator, the verdict and the showing it was given on),
/// and a second call with the same token appends nothing and returns the
/// occurrence.
pub fn record_refusal(
  desk: Desk(o, tx),
  tx: tx,
  rollback: Rollback,
) -> Result(Occurrence(o), Refusal) {
  use Nil <- result.try(check(
    rollback.point == desk.point.name,
    UnknownOccurrence,
  ))
  use draft <- result.try(load(desk, tx, rollback.occurrence))
  use verdict <- result.try(
    value.parse(rollback.verdict, value.unlimited())
    |> result.replace_error("the refused verdict does not parse")
    |> result.try(wire.decode_verdict(_, desk.point.output))
    |> result.map_error(Unreadable),
  )
  let refused =
    entry.VerdictRefused(
      by: rollback.by,
      verdict:,
      seen: rollback.seen,
      reason: rollback.reason,
    )
  case list.any(draft.occurrence.entries, fn(e) { e.event == refused }) {
    True -> Ok(draft.occurrence)
    False -> add(draft, refused) |> save(desk, tx, _)
  }
}

/// A verdict after the fact, on a sampled and released occurrence, given
/// on a recorded showing (`open` records one). It changes no outcome and
/// counts toward agreement. Each reviewer reviews once; whoever decided
/// the occurrence, asked for it, or recommended it as their own act may
/// not review it; and when the point names reviewers (`reviewed_by`), only
/// holders of that set may (`NotEligible`).
pub fn review(
  desk: Desk(o, tx),
  tx: tx,
  card: Card(o),
  verdict: Verdict(o),
) -> Result(Occurrence(o), Refusal) {
  use draft <- result.try(load(desk, tx, card.occurrence.id))
  case draft.occurrence.sampled, draft.occurrence.status {
    True, occurrence.Released(..) -> {
      let current = draft.occurrence
      use Nil <- result.try(check(
        was_shown(current, card.validator, card.seen),
        NeverShown,
      ))
      use Nil <- result.try(check(
        may_review(desk, current, card.validator),
        NotEligible,
      ))
      use Nil <- result.try(allowed_verdict(
        desk.point,
        current,
        card.validator,
        verdict,
      ))
      add(draft, entry.Reviewed(by: card.validator.subject, verdict:))
      |> save(desk, tx, _)
    }
    _, _ -> Error(NotSampled)
  }
}

/// The decider takes a held output back before its hold ends. The decider
/// is the validator whose verdict accepted it, or the person whose own act
/// the policy let proceed. Once the hold has ended by the store's clock it
/// is refused with `NotHeld`, whether or not the wake-up that releases it
/// was delivered.
pub fn withdraw(
  desk: Desk(o, tx),
  tx: tx,
  occurrence id: String,
  by who: String,
) -> Result(Occurrence(o), Refusal) {
  withdraw_held(desk, tx, id, who, False)
}

/// `withdraw` by a validator: the decider, or a holder of the set the
/// point names with `withdrawn_by`. Refused with `NotTheDecider` for anyone
/// else, and with `NotHeld` once the hold has ended.
pub fn withdraw_as(
  desk: Desk(o, tx),
  tx: tx,
  occurrence id: String,
  by validator: Validator,
) -> Result(Occurrence(o), Refusal) {
  let entitled = case desk.point.withdrawers {
    Some(set) -> list.contains(validator.holds, set)
    None -> False
  }
  withdraw_held(desk, tx, id, validator.subject, entitled)
}

fn withdraw_held(
  desk: Desk(o, tx),
  tx: tx,
  id: String,
  who: String,
  entitled: Bool,
) -> Result(Occurrence(o), Refusal) {
  use draft <- result.try(load(desk, tx, id))
  case draft.occurrence.status {
    occurrence.Held(by: decider, until:, ..) -> {
      use Nil <- result.try(check(
        timestamp.compare(draft.now, until) == order.Lt,
        NotHeld,
      ))
      let is_decider = case decider, draft.occurrence.recommendation.by {
        occurrence.ByValidator(subject:), _ -> subject == who
        occurrence.ByPolicy(_), Person(subject:) -> subject == who
        occurrence.ByPolicy(_), _ -> False
      }
      use Nil <- result.try(check(entitled || is_decider, NotTheDecider))
      add(draft, entry.Withdrawn(by: who)) |> save(desk, tx, _)
    }
    _ -> Error(NotHeld)
  }
}

// -- The world and the system --------------------------------------------------------

/// What `happened` did.
pub type Supersession(output) {
  Supersession(
    /// The occurrences it expired: undecided or held ones, which had a
    /// recommendation.
    expired: List(Occurrence(output)),
    /// The keys of records it ended before they began: expected, or
    /// holding only failed attempts. Their `recommend_once` will be
    /// refused with `SupersededBefore`, except for a record whose own
    /// deadline had already passed: it expired as `DeadlinePassed`, and a
    /// later recommendation is recorded expired.
    not_begun: List(String),
    /// The occurrences about the subject that could not be read, with why.
    /// The others were still superseded.
    unreadable: List(#(String, Refusal)),
  )
}

/// A world event happened to a subject. Every record of this point about
/// that subject that has released nothing expires as superseded, when the
/// point declares the event with `superseded_by`:
///
/// - a record that has not begun (`expect`ed, or holding only failed
///   attempts): its `recommend_once` is then refused, so the work in
///   flight for an older trigger never shows or releases anything; one
///   whose own deadline (`expect_until`) had already passed expires as
///   `DeadlinePassed` instead, and its wake-up is cancelled;
/// - an undecided occurrence; one whose validity had already passed
///   expires as `DeadlinePassed`, which is what ended it;
/// - a held occurrence: its hold's wake-up is cancelled and its output is
///   never released.
///
/// A released occurrence is untouched. A record that cannot be read is
/// reported and does not stop the others. Each superseded record admits
/// one settlement notice.
///
/// **The subject lock.** For an event the point declares, `happened` first
/// loads `subject_lock(point, subject)` through the port, which locks that
/// id for the rest of the transaction, and only then reads `waiting`. So
/// two `happened` about one subject of one point run one after the other,
/// and the second sees every record the first committed, including the key
/// its transaction `expect`ed: two triggers about one subject admitted at
/// the same moment cannot both miss each other. A transaction that calls
/// only `expect`, `recommend` or `recommend_once`, without `happened`,
/// takes no subject lock and is ordered by nothing here. An event the
/// point does not declare takes no lock. A store error while waiting for
/// the lock is `StoreFailed` (`Contended` after a long wait), so the
/// delivery is tried again.
///
/// Locks are taken in one order: the subject lock, then the records in the
/// order `waiting` returns. In a transaction that also expects a key, call
/// `happened` before `expect`: the other order could deadlock with a
/// transaction that follows this one, and would supersede the key just
/// expected.
///
/// **The superseding window.** A worker that recommends from an older
/// trigger and commits after `happened` would create an occurrence nothing
/// supersedes. Call `happened` and then `expect` with that trigger's key in
/// the transaction that received it, and a later `happened` supersedes it
/// before it begins; the window stays open only for a key that was not
/// expected first.
pub fn happened(
  desk: Desk(o, tx),
  tx: tx,
  event: String,
  about subject: Subject,
) -> Result(Supersession(o), Refusal) {
  let none = Supersession(expired: [], not_begun: [], unreadable: [])
  case list.contains(desk.point.superseded_by, event) {
    False -> Ok(none)
    True -> {
      // The subject lock first, then the records in `waiting`'s order.
      use _ <- result.try(
        desk.port.load(tx, subject_lock(point: desk.point.name, subject:))
        |> result.map_error(StoreFailed),
      )
      use ids <- result.try(
        desk.port.waiting(tx, desk.point.name, subject)
        |> result.map_error(StoreFailed),
      )
      use done <- result.map(
        list.try_fold(ids, none, fn(done, id) {
          case supersede(desk, tx, id, event) {
            Error(StoreFailed(error)) -> Error(StoreFailed(error))
            Error(refusal) ->
              Ok(
                Supersession(..done, unreadable: [
                  #(id, refusal),
                  ..done.unreadable
                ]),
              )
            Ok(NothingSuperseded) -> Ok(done)
            Ok(SupersededOccurrence(expired)) ->
              Ok(Supersession(..done, expired: [expired, ..done.expired]))
            Ok(SupersededRecord) ->
              Ok(Supersession(..done, not_begun: [id, ..done.not_begun]))
          }
        }),
      )
      Supersession(
        expired: list.reverse(done.expired),
        not_begun: list.reverse(done.not_begun),
        unreadable: list.reverse(done.unreadable),
      )
    }
  }
}

/// The prefix of every subject lock id (`subject_lock`). It is reserved:
/// do not use it for keys of your own.
pub const subject_lock_prefix = "decisions.subject-lock:"

/// The id `happened` loads, purely as a lock, before it reads which
/// records of `point` about `subject` are waiting: `subject_lock_prefix`
/// followed by the lowercase hex SHA-256 of the point name, the subject's
/// kind and the subject's id, each written as its byte length, a colon and
/// the text. The length prefixes keep the parts apart, so `("a", "b:c")`
/// and `("a:b", "c")` give different ids, and the id is 87 bytes however
/// long the parts are. No entry is ever stored under it.
///
/// A key of your own that equalled it would still be harmless: `happened`
/// ignores what the load returns and only waits on the lock, so such a
/// record would merely make `happened` about that subject wait for its
/// transactions too. Matching 64 hex digits of a SHA-256 takes a choice,
/// not an accident; the reserved prefix rules out the choice.
pub fn subject_lock(point point: String, subject subject: Subject) -> String {
  let part = fn(text) { int.to_string(string.byte_size(text)) <> ":" <> text }
  let body = part(point) <> part(subject.kind) <> part(subject.id)
  subject_lock_prefix
  <> crypto.hash(crypto.Sha256, bit_array.from_string(body))
  |> bit_array.base16_encode
  |> string.lowercase
}

type Superseding(o) {
  NothingSuperseded
  SupersededOccurrence(Occurrence(o))
  SupersededRecord
}

fn supersede(
  desk: Desk(o, tx),
  tx: tx,
  id: String,
  event: String,
) -> Result(Superseding(o), Refusal) {
  use #(entries, now) <- result.try(
    fetch(desk, tx, id) |> result.map_error(by_id),
  )
  let folded = occurrence.fold(id, entries)
  case folded {
    Error(occurrence.NotYet(occurrence.Pending(ended: None, ..) as pending)) -> {
      // A record whose own deadline had already passed ended by it.
      let cause = case occurrence.pending_has_lapsed(pending, now) {
        True -> vocabulary.DeadlinePassed
        False -> Superseded(event:)
      }
      write_pending(
        desk,
        tx,
        id,
        entries,
        Some(pending),
        entry.Expired(cause),
        now,
      )
      |> result.replace(SupersededRecord)
    }
    Error(occurrence.NotYet(_)) -> Ok(NothingSuperseded)
    _ -> {
      use draft <- result.try(drafted(desk, entries, now, folded))
      case is_supersedable(draft.occurrence.status) {
        False -> Ok(NothingSuperseded)
        True -> {
          let cause = case occurrence.has_lapsed(draft.occurrence, draft.now) {
            True -> vocabulary.DeadlinePassed
            False -> Superseded(event:)
          }
          add(draft, entry.Expired(cause))
          |> save(desk, tx, _)
          |> result.map(SupersededOccurrence)
        }
      }
    }
  }
}

/// The consulted decision point `from` settled: its final output arrives
/// as facts, and the policy current now is read again with them (so a
/// version published while the consulted point worked applies).
///
/// Refused with `NotConsulting` unless the occurrence waits for exactly
/// that point, with `InvalidFacts` when a fact is not declared by this
/// point (`signal`) or has another type, and with `NotAwaiting` once the
/// validity has passed.
pub fn inform(
  desk: Desk(o, tx),
  tx: tx,
  occurrence id: String,
  from from: String,
  facts facts: Facts,
) -> Result(Occurrence(o), Refusal) {
  use draft <- result.try(load(desk, tx, id))
  use Nil <- result.try(live(draft))
  case draft.occurrence.status {
    occurrence.Recommended(consulting: Some(point)) if point == from -> {
      let faults =
        fact_faults(desk.point, facts, from: fn(source) {
          case source {
            FromAnswer(point:, ..) -> point == from
            FromOutput(..) | FromSignal(..) -> False
          }
        })
      use Nil <- result.try(check(faults == [], InvalidFacts(faults)))
      settle(desk, tx, add(draft, entry.Informed(from:, facts:)))
    }
    _ -> Error(NotConsulting)
  }
}

/// What a wake-up found.
///
/// It may gain variants in a minor release; keep a `_` branch where a new
/// one needs no decision of yours.
pub type Woken(output) {
  /// Something was due and the occurrence moved.
  Woken(occurrence: Occurrence(output))
  /// Nothing is due before `until`. The wake-up arrived early, for one
  /// because the job queue's clock is ahead of the store's: deliver it
  /// again at `until`.
  NotDue(until: Timestamp)
  /// Nothing is pending: the occurrence settled, or it waits for no time.
  /// A wake-up delivered again is harmless.
  NothingDue
  /// A record that had not begun reached its own deadline (`expect_until`)
  /// and expired with `DeadlinePassed`; this is the record now.
  LapsedBefore(pending: occurrence.Pending)
}

/// A wake-up for an occurrence: a hold ended, the validity passed, or
/// waiting changed what the policy says; or for a record not begun whose
/// own deadline (`expect_until`) passed, which then expires
/// (`LapsedBefore`). A release checks the guard, the
/// release check and the tool again against the world as it is now; a
/// `Refuse` ends the occurrence `Refused`, an `Unsure` fails the wake-up
/// with `ToolUnsure` and records nothing, so it is delivered again.
///
/// Of the policy's later answers whose time has passed, it applies, in
/// order, the first that proceeds, consults a point not yet consulted, or
/// asks for what the approvals given so far already meet, and otherwise
/// the last. So a wake-up delivered late reaches the outcome one delivered
/// on time would have. Each is applied as the first answer was: one that
/// consults asks the consulted point, one that asks for what the standing
/// approvals meet accepts. A wake-up that finds
/// nothing due writes nothing and names the next time something is due,
/// always in the future, or `NothingDue`.
pub fn wake(
  desk: Desk(o, tx),
  tx: tx,
  occurrence id: String,
) -> Result(Woken(o), Refusal) {
  use #(entries, now) <- result.try(
    fetch(desk, tx, id) |> result.map_error(by_id),
  )
  case occurrence.fold(id, entries) {
    Error(occurrence.NotYet(pending)) if pending.point == desk.point.name ->
      wake_pending(desk, tx, id, entries, pending, now)
    folded -> {
      use draft <- result.try(drafted(desk, entries, now, folded))
      wake_occurrence(desk, tx, draft)
    }
  }
}

/// A record not begun is due only at its own deadline.
fn wake_pending(
  desk: Desk(o, tx),
  tx: tx,
  id: String,
  entries: List(Entry(o)),
  pending: occurrence.Pending,
  now: Timestamp,
) -> Result(Woken(o), Refusal) {
  case occurrence.pending_has_lapsed(pending, now), pending.ended {
    True, _ ->
      write_pending(
        desk,
        tx,
        id,
        entries,
        Some(pending),
        entry.Expired(vocabulary.DeadlinePassed),
        now,
      )
      |> result.map(LapsedBefore)
    False, None ->
      case pending.valid_until {
        Some(until) -> Ok(NotDue(until))
        None -> Ok(NothingDue)
      }
    False, Some(_) -> Ok(NothingDue)
  }
}

fn wake_occurrence(
  desk: Desk(o, tx),
  tx: tx,
  draft: Draft(o),
) -> Result(Woken(o), Refusal) {
  let now = draft.now
  let waiting = draft.occurrence
  let is_due = fn(at) { timestamp.compare(now, at) != order.Lt }
  let moved = fn(saved: Result(Occurrence(o), Refusal)) {
    result.map(saved, Woken)
  }
  let next = fn() {
    case list.find(occurrence.wake_times(waiting), fn(at) { !is_due(at) }) {
      Ok(at) -> Ok(NotDue(at))
      Error(Nil) -> Ok(NothingDue)
    }
  }
  case waiting.status {
    occurrence.Held(until:, ..) ->
      case is_due(until) {
        True ->
          release(desk, tx, draft, None)
          |> result.try(save(desk, tx, _))
          |> moved
        False -> Ok(NotDue(until))
      }
    occurrence.Recommended(_) | occurrence.Awaiting(_) ->
      case occurrence.has_lapsed(waiting, now) {
        True ->
          add(draft, entry.Expired(vocabulary.DeadlinePassed))
          |> save(desk, tx, _)
          |> moved
        False -> {
          let waited = waited_minutes(waiting, now)
          let #(passed, _) =
            list.partition(waiting.later, fn(step) { step.after <= waited })
          case first_decisive(waiting, passed), waiting.status {
            Ok(step), occurrence.Awaiting(eligible:) -> {
              let version = option.unwrap(waiting.policy_version, 0)
              let rest =
                list.filter(waiting.later, fn(later) {
                  later.after > step.after
                })
              let outcome = case step.outcome {
                // A point is consulted once: the step keeps the occurrence
                // waiting as it is.
                policy.Consult(point:) ->
                  case was_consulted(waiting, point) {
                    True -> policy.Ask(eligible)
                    False -> step.outcome
                  }
                outcome -> outcome
              }
              act_on(desk, tx, draft, version, outcome, rest) |> moved
            }
            _, _ -> next()
          }
        }
      }
    _ -> Ok(NothingDue)
  }
}

/// Undecided, or accepted and held: nothing has been released.
fn is_supersedable(status: occurrence.Status(o)) -> Bool {
  occurrence.is_undecided(status)
  || case status {
    occurrence.Held(..) -> True
    _ -> False
  }
}

/// Of the steps whose time has passed, in order, the first that proceeds,
/// consults a point not yet consulted, or asks for what the approvals
/// given so far already meet; when none does, the last. So a wake-up
/// delivered late reaches the outcome one delivered on time would have.
fn first_decisive(
  waiting: Occurrence(o),
  passed: List(policy.Step),
) -> Result(policy.Step, Nil) {
  list.find(passed, fn(step) {
    case step.outcome {
      policy.Proceed(..) -> True
      policy.Consult(point:) -> !was_consulted(waiting, point)
      policy.Ask(eligible) -> occurrence.is_met(waiting, eligible)
    }
  })
  |> result.lazy_or(fn() { list.last(passed) })
}

/// The desk's `wake` with its output type erased, so one job handler can
/// serve every point by name: `#(point name, handler)`. The handler
/// returns `None` when the job is done, and `Some(until)` when it arrived
/// early and must be delivered again at `until`.
pub fn waker(
  desk: Desk(o, tx),
) -> #(String, fn(tx, String) -> Result(Option(Timestamp), Refusal)) {
  #(desk.point.name, fn(tx, id) {
    wake(desk, tx, id)
    |> result.map(fn(woken) {
      case woken {
        NotDue(until:) -> Some(until)
        Woken(_) | NothingDue | LapsedBefore(_) -> None
      }
    })
  })
}

/// What became of the release outside the database: performed with a
/// receipt, not performed, or not yet known. Report again when a lookup
/// settles an uncertain outcome; the latest report is the one that counts.
pub fn report(
  desk: Desk(o, tx),
  tx: tx,
  occurrence id: String,
  effect effect: Effect,
) -> Result(Occurrence(o), Refusal) {
  use draft <- result.try(load(desk, tx, id))
  case draft.occurrence.status {
    occurrence.Released(..) ->
      add(draft, entry.Effected(effect:)) |> save(desk, tx, _)
    _ -> Error(NotReleased)
  }
}

/// What proved true later, about an occurrence that settled (released,
/// rejected, expired, withdrawn or refused). It is appended and changes no
/// verdict and no output. An occurrence that has not settled is refused
/// with `NotSettled`: there is nothing final yet to judge. Each call
/// appends one assessment; repeating it records the finding again.
pub fn assess(
  desk: Desk(o, tx),
  tx: tx,
  occurrence id: String,
  finding assessment: Assessment(o),
) -> Result(Occurrence(o), Refusal) {
  use draft <- result.try(load(desk, tx, id))
  use Nil <- result.try(check(
    occurrence.is_settled(draft.occurrence.status),
    NotSettled,
  ))
  add(draft, entry.Assessed(assessment:)) |> save(desk, tx, _)
}

/// What a key's record holds: an occurrence, or a record that has not
/// begun (expected, holding failed attempts, or superseded or lapsed at
/// its own deadline before it began).
pub type Record(output) {
  Begun(occurrence: Occurrence(output))
  NotBegun(pending: occurrence.Pending)
}

/// The record under a key, whether or not it has begun. It writes
/// nothing. `UnknownOccurrence` when the key holds nothing of this point.
pub fn read_record(
  desk: Desk(o, tx),
  tx: tx,
  key key: String,
) -> Result(Record(o), Refusal) {
  use #(entries, _) <- result.try(
    fetch(desk, tx, key) |> result.map_error(by_id),
  )
  case occurrence.fold(key, entries) {
    Ok(found) -> mine(desk, found) |> result.map(Begun)
    Error(occurrence.NotYet(pending)) -> Ok(NotBegun(pending))
    Error(occurrence.NoEntries) -> Error(UnknownOccurrence)
    Error(occurrence.NoRecommendation) -> Error(not_a_record())
  }
}

/// The occurrence as the record holds it now. It writes nothing.
pub fn read(
  desk: Desk(o, tx),
  tx: tx,
  occurrence id: String,
) -> Result(Occurrence(o), Refusal) {
  load(desk, tx, id) |> result.map(fn(draft) { draft.occurrence })
}

// -- Inside ----------------------------------------------------------------------------

/// An occurrence with entries not yet appended, the time the verb runs at,
/// and what the store held before: its pending wake-ups and whether it had
/// settled.
type Draft(o) {
  Draft(
    occurrence: Occurrence(o),
    saved: Int,
    now: Timestamp,
    wakes: List(Timestamp),
    settled: Bool,
  )
}

/// Load and lock the record, decode it, then read the clock: the clock is
/// read after the lock, and never earlier than the last entry.
fn fetch(
  desk: Desk(o, tx),
  tx: tx,
  id: String,
) -> Result(#(List(Entry(o)), Timestamp), Refusal) {
  use stored <- result.try(
    desk.port.load(tx, id) |> result.map_error(StoreFailed),
  )
  use Nil <- result.try(case stored {
    [first, ..] ->
      case entry.point_of(first) {
        Ok(point) if point != desk.point.name -> Error(KeyTaken(point:))
        _ -> Ok(Nil)
      }
    [] -> Ok(Nil)
  })
  use entries <- result.try(
    list.try_map(stored, entry.from_stored(_, desk.point.output))
    |> result.map_error(Unreadable),
  )
  use clock <- result.try(clock(desk, tx))
  let now = case list.last(entries) {
    Ok(last) ->
      case timestamp.compare(clock, last.at) {
        order.Lt -> last.at
        _ -> clock
      }
    Error(Nil) -> clock
  }
  Ok(#(entries, now))
}

/// The store's clock in whole milliseconds, the resolution of every stored
/// time. The desk reduces it here, so an adapter with a finer clock cannot
/// store a time a wake-up or a head would not match exactly.
fn clock(desk: Desk(o, tx), tx: tx) -> Result(Timestamp, Refusal) {
  desk.port.now(tx)
  |> result.map(whole_milliseconds)
  |> result.map_error(StoreFailed)
}

/// A time in whole milliseconds, rounded down: the resolution of every
/// time the desk stores, schedules or puts on a head.
fn whole_milliseconds(at: Timestamp) -> Timestamp {
  at |> wire.milliseconds |> wire.from_milliseconds
}

fn load(desk: Desk(o, tx), tx: tx, id: String) -> Result(Draft(o), Refusal) {
  use #(entries, now) <- result.try(
    fetch(desk, tx, id) |> result.map_error(by_id),
  )
  drafted(desk, entries, now, occurrence.fold(id, entries))
}

/// By id, another point's occurrence is simply not this desk's.
fn by_id(refusal: Refusal) -> Refusal {
  case refusal {
    KeyTaken(_) -> UnknownOccurrence
    _ -> refusal
  }
}

/// The draft of entries already fetched and folded, so a verb that read
/// them for another reason does not read them through the port again.
fn drafted(
  desk: Desk(o, tx),
  entries: List(Entry(o)),
  now: Timestamp,
  folded: Result(Occurrence(o), occurrence.NotBegun),
) -> Result(Draft(o), Refusal) {
  case folded {
    Ok(found) -> {
      use found <- result.map(mine(desk, found))
      Draft(
        occurrence: found,
        saved: list.length(entries),
        now:,
        wakes: occurrence.wake_times(found),
        settled: occurrence.is_settled(found.status),
      )
    }
    Error(occurrence.NoEntries) -> Error(UnknownOccurrence)
    Error(occurrence.NotYet(pending)) ->
      case pending.point == desk.point.name {
        False -> Error(UnknownOccurrence)
        True -> {
          use Nil <- result.try(still_open(pending, now))
          Error(NotRecommended(attempts: pending.attempts))
        }
      }
    Error(occurrence.NoRecommendation) -> Error(not_a_record())
  }
}

/// An occurrence of another point is not this desk's, even when the two
/// points' outputs share a codec.
fn mine(
  desk: Desk(o, tx),
  found: Occurrence(o),
) -> Result(Occurrence(o), Refusal) {
  case found.point == desk.point.name {
    True -> Ok(found)
    False -> Error(UnknownOccurrence)
  }
}

fn not_a_record() -> Refusal {
  Unreadable("the entries do not begin with a recommendation")
}

fn add(draft: Draft(o), event: Event(o)) -> Draft(o) {
  let seq = list.length(draft.occurrence.entries) + 1
  Draft(
    ..draft,
    occurrence: occurrence.apply(
      draft.occurrence,
      entry.Entry(seq:, at: draft.now, event:),
    ),
  )
}

fn encode(
  entries: List(Entry(o)),
  output: Codec(o),
) -> Result(List(store.Stored), Refusal) {
  list.try_map(entries, entry.to_stored(_, output))
  |> result.map_error(Unencodable)
}

/// Append what is new, replace the wake-ups when they changed, and admit
/// the settlement notice when the occurrence settled now.
fn save(
  desk: Desk(o, tx),
  tx: tx,
  draft: Draft(o),
) -> Result(Occurrence(o), Refusal) {
  let current = draft.occurrence
  let fresh = list.drop(current.entries, draft.saved)
  use stored <- result.try(encode(fresh, desk.point.output))
  let port = desk.port
  let wakes = occurrence.wake_times(current)
  let settled = occurrence.is_settled(current.status)
  {
    use Nil <- result.try(case stored {
      [] -> Ok(Nil)
      _ -> port.append(tx, current.id, occurrence.head(current), stored)
    })
    use Nil <- result.try(case wakes == draft.wakes {
      True -> Ok(Nil)
      False -> port.schedule(tx, desk.point.name, current.id, wakes)
    })
    case settled && !draft.settled {
      True -> port.settled(tx, desk.point.name, current.id)
      False -> Ok(Nil)
    }
  }
  |> result.map_error(StoreFailed)
  |> result.replace(current)
}

fn waited_minutes(current: Occurrence(o), now: Timestamp) -> Int {
  let #(seconds, _) =
    timestamp.difference(occurrence.recommended_at(current), now)
    |> duration.to_seconds_and_nanoseconds
  seconds / 60
}

/// Read the policy over everything it may read, and act on its answer.
fn settle(
  desk: Desk(o, tx),
  tx: tx,
  draft: Draft(o),
) -> Result(Occurrence(o), Refusal) {
  let current = draft.occurrence
  use published <- result.try(desk.policy(tx) |> result.map_error(NoPolicy))
  use Nil <- result.try(
    publishable(desk.point, published) |> result.map_error(Unpublishable),
  )
  let facts =
    policy_facts(desk.point, current.recommendation, informed: current.informed)
  let #(outcome, later) =
    policy.timeline(
      published,
      current.recommendation.by,
      facts,
      waited: waited_minutes(current, draft.now),
    )
  // A policy that would consult the same point twice asks its default.
  let #(outcome, later) = case outcome {
    policy.Consult(point:) ->
      case was_consulted(current, point) {
        True -> #(policy.Ask(policy.otherwise(published)), [])
        False -> #(outcome, [])
      }
    _ -> #(outcome, later)
  }
  act_on(desk, tx, draft, policy.version(published), outcome, later)
}

/// Act on one answer of the policy, the first or a later one: record it
/// with the version that gave it, then release or hold when it proceeds,
/// wait when it asks, and ask the consulted point when it consults. A
/// consulting answer drops the later steps: when the consulted point
/// answers, the policy is read again.
fn act_on(
  desk: Desk(o, tx),
  tx: tx,
  draft: Draft(o),
  version: Int,
  outcome: policy.Outcome,
  later: List(policy.Step),
) -> Result(Occurrence(o), Refusal) {
  let id = draft.occurrence.id
  let applied = fn(sampled, later) {
    add(draft, entry.PolicyApplied(version:, outcome:, sampled:, later:))
  }
  case outcome {
    policy.Proceed(sample:, hold:) ->
      applied(is_sampled(sample, id), [])
      |> accept(desk, tx, _, hold, None)
      |> result.try(save(desk, tx, _))
    policy.Ask(_) -> {
      let draft = applied(False, later)
      case draft.occurrence.status {
        // The approvals given so far already meet what it now asks.
        occurrence.Accepted(..) ->
          accept(desk, tx, draft, None, None) |> result.try(save(desk, tx, _))
        _ -> save(desk, tx, draft)
      }
    }
    policy.Consult(point:) -> {
      // The consulted point may inform this occurrence in this same
      // transaction, so the entries are appended before it is asked.
      use saved <- result.try(save(desk, tx, applied(False, [])))
      use Nil <- result.try(
        desk.consult(
          tx,
          Consultation(
            point:,
            occurrence: saved.id,
            subject: saved.subject,
            context: saved.context,
            recommendation: saved.recommendation,
          ),
        )
        |> result.map_error(ConsultFailed(point:, reason: _)),
      )
      read(desk, tx, saved.id)
    }
  }
}

fn was_consulted(current: Occurrence(o), point: String) -> Bool {
  list.any(current.entries, fn(entry) {
    case entry.event {
      entry.PolicyApplied(outcome: policy.Consult(point: consulted), ..) ->
        consulted == point
      _ -> False
    }
  })
}

/// An accepted output is held when the point has a hold, and released
/// otherwise.
/// `policy_hold` is the hold of the `Proceed` that accepted it, which
/// takes the place of the point's `with_hold` for that acceptance.
fn accept(
  desk: Desk(o, tx),
  tx: tx,
  draft: Draft(o),
  policy_hold: Option(Duration),
  on_refusal: Option(#(Validator, Int, Verdict(o))),
) -> Result(Draft(o), Refusal) {
  let hold = case policy_hold {
    Some(hold) -> Some(hold)
    None -> desk.point.hold
  }
  case hold {
    Some(hold) ->
      Ok(add(draft, entry.Held(until: timestamp.add(draft.now, hold))))
    None -> release(desk, tx, draft, on_refusal)
  }
}

/// Check the guard against the current world, hand the executor the
/// released output, and append the release, all in the caller's
/// transaction and the guard and executor inside a savepoint.
/// `on_refusal` is the verdict that accepted it, when a validator is
/// present: a refusal then fails the call so its transaction rolls back.
/// With nobody waiting (`None`), a refusal ends the occurrence `Refused`.
fn release(
  desk: Desk(o, tx),
  tx: tx,
  draft: Draft(o),
  on_refusal: Option(#(Validator, Int, Verdict(o))),
) -> Result(Draft(o), Refusal) {
  let current = draft.occurrence
  case current.status {
    occurrence.Accepted(final:, by:) | occurrence.Held(final:, by:, ..) -> {
      let tool = desk.tool(final)
      let key = "release:" <> current.id
      use ran <- result.try(
        desk.port.atomically(tx, fn(tx) {
          use relied <- result.try(tool.guard(tx, current.subject))
          use checked <- result.try(desk.check(
            tx,
            ToRelease(
              output: final,
              subject: current.subject,
              context: current.context,
              key:,
            ),
          ))
          // Built for this release attempt only, after the guard and the
          // check allowed it, and handed to the executor alone.
          let released =
            Released(
              occurrence: current.id,
              key:,
              subject: current.subject,
              parent: current.parent,
              by:,
              output: final,
              context: current.context,
            )
          tool.execute(tx, released)
          |> result.replace(list.append(relied, checked))
        })
        |> result.map_error(StoreFailed),
      )
      case ran, on_refusal {
        Ok(relied), _ ->
          Ok(add(draft, entry.Released(key:, tool: tool.name, relied:)))
        Error(Unsure(reason:)), _ -> Error(ToolUnsure(reason:))
        Error(vocabulary.Contended(detail:)), _ ->
          Error(StoreFailed(store.Contended(detail:)))
        Error(Refuse(reason:)), Some(#(validator, seen, verdict)) -> {
          use encoded <- result.try(
            wire.verdict(verdict, desk.point.output)
            |> result.map_error(Unencodable),
          )
          Error(ToolRefused(
            reason:,
            rollback: Rollback(
              point: desk.point.name,
              occurrence: current.id,
              by: validator.subject,
              seen:,
              verdict: value.to_string(encoded),
              reason:,
            ),
          ))
        }
        Error(Refuse(reason:)), None -> Ok(add(draft, entry.Refused(reason:)))
      }
    }
    _ -> Ok(draft)
  }
}

/// Admitted by the eligibility, and not already an approver of the output
/// that stands: each validator gives one verdict per standing output.
fn is_eligible(
  eligible: Eligible,
  validator: Validator,
  current: Occurrence(o),
) -> Bool {
  occurrence.admits(current, eligible, validator.subject, validator.holds)
  && !list.contains(occurrence.standing(current).1, validator.subject)
}

fn allowed_verdict(
  point: Point(o),
  current: Occurrence(o),
  validator: Validator,
  verdict: Verdict(o),
) -> Result(Nil, Refusal) {
  let noted =
    list.any(occurrence.notes(current), fn(note) { note.0 == validator.subject })
  case verdict, point.verdicts {
    Approve, _ -> Ok(Nil)
    Correct(..), ApproveOrReject -> Error(VerdictNotAllowed)
    Reject(reason:), _ | Correct(reason:, ..), _ ->
      case string.trim(reason.category) {
        "" -> Error(ReasonRequired)
        category if category == missing_context && !noted -> Error(NoteRequired)
        _ -> Ok(Nil)
      }
  }
}

fn is_sampled(sample: Sample, id: String) -> Bool {
  policy.is_sampled(sample, id)
}

fn check(holds: Bool, otherwise: Refusal) -> Result(Nil, Refusal) {
  case holds {
    True -> Ok(Nil)
    False -> Error(otherwise)
  }
}
