//// A policy is versioned data that holds every condition for proceeding
//// without a person. It reads nothing but the recommender and named facts:
//// the output's facts, the recommender's signals, what consulted points
//// returned, and the time waited.
////
//// Because it is data, a policy can be stored as a row, published by a
//// write, compared with `==`, exported with `to_json` and read back with
//// `decoder`. `check` (or `decisions.publishable`, which supplies a
//// point's declared facts) refuses a policy that reads a fact the point
//// never declares or compares a fact of the wrong type.
////
//// ```gleam
//// import decisions/fact
//// import decisions/policy.{
////   AnyoneHolding, Ask, Never, OwnAct, Policy, Proceed, When,
//// }
////
//// let amount = fact.number("amount")
//// let refunds =
////   Policy(
////     version: 2,
////     rules: [
////       When(OwnAct, Proceed(Never)),
////       When(policy.below(amount, 100.0), Proceed(Never)),
////     ],
////     otherwise: Ask(AnyoneHolding("finance")),
////   )
//// ```
////
//// The first rule whose condition holds decides; `otherwise` decides when
//// none does. A condition over an absent fact is unknown, stays unknown
//// under `Not`, and never matches, so what is unknown never proceeds.
////
//// Open questions, recorded here because a policy cannot yet say them:
////
//// - A condition cannot read who recommended, beyond `OwnAct`. An
////   application that needs "this model version" repeats it as a signal.
//// - Eligibility cannot say "two approvals, at least one by a senior".
////   `Either` and `Several` combine alternatives and counts; an `All`
////   over alternatives (each satisfied by the same approvals) would be a
////   small addition to `decisions/occurrence.is_met`, and is not built.
////
//// `Outcome`, `Eligible` and `Condition` may gain variants in a minor
//// release. Code that matches them should keep a `_` branch.
////
//// Target-independent: builds for Erlang and JavaScript.

import decisions/fact.{type Key, type Kind}
import decisions/vocabulary.{
  type Fact, type Facts, type Recommender, Number, Person,
}
import decisions/wire
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}

/// One version of a point's policy.
pub type Policy {
  Policy(version: Int, rules: List(Rule), otherwise: Outcome)
}

/// "When this condition holds, this is the outcome."
pub type Rule {
  When(condition: Condition, then: Outcome)
}

/// What the policy says about a recommendation.
pub type Outcome {
  /// Proceed without a person. `sample` picks which released occurrences
  /// wait for a review after the fact.
  Proceed(sample: Sample)
  /// Wait for a verdict from whoever `eligible` admits.
  Ask(eligible: Eligible)
  /// Ask the decision point named `point` first. Its final output returns
  /// as facts through `decisions.inform`, and the policy current at that
  /// moment is read again with them. A policy that would consult the same
  /// point twice falls to `otherwise`. A later answer (a `Step`) that
  /// consults asks the point the same way; consulting drops the remaining
  /// steps.
  Consult(point: String)
}

/// Which proceeding occurrences are reviewed after the fact. Sampling is a
/// function of the occurrence's id, so a replay samples alike.
pub type Sample {
  /// No released occurrence is sampled. Stored as `"sample": null`.
  Never
  /// About this many in a hundred are sampled; `PerCent(0)` samples none
  /// and stays distinct from `Never` in storage, so a policy read back is
  /// `==` to the one written.
  PerCent(Int)
}

/// Who may give the verdict an occurrence waits for.
pub type Eligible {
  /// Any holder of the decision set.
  AnyoneHolding(set: String)
  /// A holder of the set other than whoever asked, and other than a person
  /// recommending it as their own act.
  SomeoneElseHolding(set: String)
  /// Whoever is eligible under any of these. It is satisfied when any one
  /// alternative is satisfied by the approvals given so far. It must have
  /// at least one alternative (`EmptyEither`).
  Either(List(Eligible))
  /// `count` different validators, each admitted by `of`, approving the
  /// output that stands. A correction replaces that output, and approvals
  /// of the earlier output stop counting. `of` may hold `Either`, but no
  /// `Several` at any depth: `check` refuses that with `NestedSeveral`,
  /// because approvals are counted once, by the outer count.
  Several(count: Int, of: Eligible)
}

/// A condition over the recommender and named facts.
pub type Condition {
  /// The recommender is a person acting on their own authority.
  OwnAct
  /// The number fact is below `limit`. Build it with `below`.
  Below(fact: String, limit: Float)
  /// The number fact is at least `limit`. Build it with `at_least`.
  AtLeast(fact: String, limit: Float)
  /// The fact equals `value`. Build it with `is`.
  Is(fact: String, value: Fact)
  /// The fact is present, such as a consulted point's answer.
  Known(fact: String)
  /// Every condition holds.
  All(List(Condition))
  /// At least one condition holds.
  AnyOf(List(Condition))
  /// The condition does not hold. Unknown stays unknown.
  Not(Condition)
}

/// A later answer of the same policy: after waiting `after` whole minutes,
/// it says `outcome`.
pub type Step {
  Step(after: Int, outcome: Outcome)
}

/// Why a policy cannot be published for a point.
pub type Fault {
  /// The policy reads a fact the point never declares. It would never
  /// match and would silently ask.
  UndeclaredFact(fact: String)
  /// The policy compares a fact as one type and the point declares
  /// another.
  WrongKind(fact: String, declared: Kind, used: Kind)
  /// `Several` asks for fewer than one approval.
  TooFewApprovals(count: Int)
  /// `PerCent` is outside 0 to 100.
  SampleOutOfRange(per_cent: Int)
  /// A `Several` inside another `Several`, directly or through `Either`.
  /// Approvals are counted once, by the outer count, so an inner count
  /// would be silently ignored.
  NestedSeveral
  /// An `Either` with no alternative: the occurrence would wait in no
  /// queue, for nobody.
  EmptyEither
}

// -- Conditions over typed keys -----------------------------------------------------

/// The number is below `limit`.
pub fn below(key: Key(Float), limit: Float) -> Condition {
  Below(fact: fact.name(key), limit:)
}

/// The number is at least `limit`.
pub fn at_least(key: Key(Float), limit: Float) -> Condition {
  AtLeast(fact: fact.name(key), limit:)
}

/// The fact equals `value`.
pub fn is(key: Key(a), value: a) -> Condition {
  Is(fact: fact.name(key), value: fact.wrap(key, value))
}

/// The fact is present.
pub fn known(key: Key(a)) -> Condition {
  Known(fact: fact.name(key))
}

/// "Unanswered for at least this many minutes": a condition over
/// `decisions/fact.waited_minutes`.
pub fn waited(minutes: Int) -> Condition {
  at_least(fact.waited_minutes(), int.to_float(minutes))
}

// -- Reading the policy ---------------------------------------------------------------

/// What the policy says for this recommender and these facts.
pub fn evaluate(policy: Policy, by: Recommender, facts: Facts) -> Outcome {
  let matching =
    list.find(policy.rules, fn(rule) {
      holds(rule.condition, by, facts) == Some(True)
    })
  case matching {
    Ok(When(then: outcome, ..)) -> outcome
    Error(Nil) -> policy.otherwise
  }
}

/// What the policy says after `waited` minutes, and each later answer it
/// will give as the occurrence goes on waiting with nothing else changing.
/// The desk computes this when it applies the policy and keeps it on the
/// record, so while an occurrence waits it keeps the version it was given:
/// a wake-up applies the steps without reading the policy again. Steps
/// that have passed are applied in order up to the first that proceeds,
/// consults, or asks for what the standing approvals meet (see
/// `decisions.wake`), so a late wake-up skips no step that would have
/// accepted. A
/// consulted point's answer is the one moment the policy is read again,
/// and then the version current at that moment applies. Every
/// `PolicyApplied` entry records the version that gave its answer.
pub fn timeline(
  policy: Policy,
  by: Recommender,
  facts: Facts,
  waited waited: Int,
) -> #(Outcome, List(Step)) {
  let waited_name = fact.name(fact.waited_minutes())
  let at = fn(minutes: Int) {
    evaluate(policy, by, [
      #(waited_name, Number(int.to_float(minutes))),
      ..list.filter(facts, fn(named) { named.0 != waited_name })
    ])
  }
  let now = at(waited)
  let #(_, steps) =
    thresholds(policy)
    |> list.filter(fn(minutes) { minutes > waited })
    |> list.fold(#(now, []), fn(so_far, minutes) {
      case at(minutes) {
        outcome if outcome == so_far.0 -> so_far
        outcome -> #(outcome, [Step(after: minutes, outcome:), ..so_far.1])
      }
    })
  #(now, list.reverse(steps))
}

/// The fewest approvals that can satisfy an eligibility: for `Either`, the
/// fewest of its alternatives. Whether given approvals satisfy it depends
/// on who gave them; `decisions/occurrence.is_met` decides that.
pub fn approvals(eligible: Eligible) -> Int {
  case eligible {
    Several(count:, ..) -> count
    AnyoneHolding(_) | SomeoneElseHolding(_) -> 1
    Either(of) ->
      list.fold(of, -1, fn(fewest, alternative) {
        let needed = approvals(alternative)
        case fewest < 0 || needed < fewest {
          True -> needed
          False -> fewest
        }
      })
      |> int.max(0)
  }
}

/// Whether an occurrence with this id is sampled. It is a function of the
/// id, so the same occurrence is always sampled or never, and a replay
/// samples alike. The id is hashed with SHA-256, so the share is uniform
/// whatever the ids look like, sequential keys included.
pub fn is_sampled(sample: Sample, id: String) -> Bool {
  case sample {
    Never -> False
    PerCent(share) ->
      case crypto.hash(crypto.Sha256, bit_array.from_string(id)) {
        <<word:size(32), _:bits>> -> word % 100 < share
        _ -> False
      }
  }
}

/// The decision sets whose queues an eligibility puts an occurrence in.
pub fn sets(eligible: Eligible) -> List(String) {
  case eligible {
    AnyoneHolding(set:) | SomeoneElseHolding(set:) -> [set]
    Either(of) -> list.flat_map(of, sets) |> list.unique
    Several(of:, ..) -> sets(of)
  }
}

/// Every fact the policy reads, each once.
pub fn reads(policy: Policy) -> List(String) {
  conditions(policy)
  |> list.flat_map(uses)
  |> list.map(fn(used) { used.0 })
  |> list.unique
}

/// Refuse a policy that reads a fact not in `declared`, compares a fact as
/// the wrong type, asks for fewer than one approval, or samples outside 0
/// to 100 per cent. Every fault is listed. `waited_minutes` is always
/// declared.
pub fn check(
  policy: Policy,
  declared declared: List(#(String, Kind)),
) -> Result(Nil, List(Fault)) {
  let declared = [
    #(fact.name(fact.waited_minutes()), fact.NumberFact),
    ..declared
  ]
  let fact_faults =
    conditions(policy)
    |> list.flat_map(uses)
    |> list.unique
    |> list.filter_map(fn(used) {
      let #(name, kind) = used
      case list.key_find(declared, name), kind {
        Error(Nil), _ -> Ok(UndeclaredFact(name))
        Ok(_), None -> Error(Nil)
        Ok(found), Some(kind) if found == kind -> Error(Nil)
        Ok(found), Some(kind) ->
          Ok(WrongKind(fact: name, declared: found, used: kind))
      }
    })
    |> list.unique
  let outcome_faults =
    [policy.otherwise, ..list.map(policy.rules, fn(rule) { rule.then })]
    |> list.flat_map(outcome_faults)
  case list.append(fact_faults, outcome_faults) {
    [] -> Ok(Nil)
    faults -> Error(faults)
  }
}

/// A fault as one line of text, for an operator.
pub fn describe(fault: Fault) -> String {
  case fault {
    UndeclaredFact(fact:) -> "reads the undeclared fact \"" <> fact <> "\""
    WrongKind(fact:, declared:, used:) ->
      "compares \""
      <> fact
      <> "\" as "
      <> kind_name(used)
      <> " but the point declares it as "
      <> kind_name(declared)
    TooFewApprovals(count:) ->
      "asks for " <> int.to_string(count) <> " approvals"
    SampleOutOfRange(per_cent:) ->
      "samples " <> int.to_string(per_cent) <> " per cent"
    NestedSeveral -> "counts approvals with a Several inside another Several"
    EmptyEither -> "asks an Either with no alternative"
  }
}

fn kind_name(kind: Kind) -> String {
  case kind {
    fact.NumberFact -> "a number"
    fact.TextFact -> "a text"
    fact.FlagFact -> "a flag"
  }
}

fn outcome_faults(outcome: Outcome) -> List(Fault) {
  case outcome {
    Proceed(PerCent(share)) if share < 0 || share > 100 -> [
      SampleOutOfRange(share),
    ]
    Proceed(_) | Consult(_) -> []
    Ask(eligible) -> eligible_faults(eligible)
  }
}

fn eligible_faults(eligible: Eligible) -> List(Fault) {
  faults_within(eligible, False)
}

fn faults_within(eligible: Eligible, inside_several: Bool) -> List(Fault) {
  case eligible {
    AnyoneHolding(_) | SomeoneElseHolding(_) -> []
    Either([]) -> [EmptyEither]
    Either(of) -> list.flat_map(of, faults_within(_, inside_several))
    Several(count:, of:) ->
      list.flatten([
        case count < 1 {
          True -> [TooFewApprovals(count)]
          False -> []
        },
        case inside_several {
          True -> [NestedSeveral]
          False -> []
        },
        faults_within(of, True),
      ])
  }
}

fn conditions(policy: Policy) -> List(Condition) {
  list.map(policy.rules, fn(rule) { rule.condition })
}

/// Each fact a condition reads, with the type it compares it as, when the
/// condition fixes one.
fn uses(condition: Condition) -> List(#(String, Option(Kind))) {
  case condition {
    OwnAct -> []
    Below(fact: name, ..) | AtLeast(fact: name, ..) -> [
      #(name, Some(fact.NumberFact)),
    ]
    Is(fact: name, value:) -> [#(name, Some(fact.kind_of(value)))]
    Known(fact: name) -> [#(name, None)]
    All(of) | AnyOf(of) -> list.flat_map(of, uses)
    Not(inner) -> uses(inner)
  }
}

/// Every number of minutes at which a rule about waiting changes its mind.
fn thresholds(policy: Policy) -> List(Int) {
  conditions(policy)
  |> list.flat_map(limits)
  |> list.unique
  |> list.sort(int.compare)
}

fn limits(condition: Condition) -> List(Int) {
  let waited_name = fact.name(fact.waited_minutes())
  case condition {
    Below(fact: name, limit:)
      | AtLeast(fact: name, limit:)
      if name == waited_name
    -> [float.round(float.ceiling(limit))]
    All(of) | AnyOf(of) -> list.flat_map(of, limits)
    Not(inner) -> limits(inner)
    OwnAct | Below(..) | AtLeast(..) | Is(..) | Known(..) -> []
  }
}

/// `None` when a fact the condition reads is absent.
fn holds(condition: Condition, by: Recommender, facts: Facts) -> Option(Bool) {
  case condition {
    OwnAct ->
      case by {
        Person(_) -> Some(True)
        _ -> Some(False)
      }
    Below(fact: name, limit:) ->
      number(facts, name) |> option.map(fn(n) { n <. limit })
    AtLeast(fact: name, limit:) ->
      number(facts, name) |> option.map(fn(n) { n >=. limit })
    Is(fact: name, value:) ->
      list.key_find(facts, name)
      |> option.from_result
      |> option.map(fn(found) { found == value })
    Known(fact: name) -> Some(list.key_find(facts, name) != Error(Nil))
    Not(inner) -> holds(inner, by, facts) |> option.map(fn(held) { !held })
    All(of) -> {
      let results = list.map(of, holds(_, by, facts))
      case list.contains(results, Some(False)), list.contains(results, None) {
        True, _ -> Some(False)
        False, True -> None
        False, False -> Some(True)
      }
    }
    AnyOf(of) -> {
      let results = list.map(of, holds(_, by, facts))
      case list.contains(results, Some(True)), list.contains(results, None) {
        True, _ -> Some(True)
        False, True -> None
        False, False -> Some(False)
      }
    }
  }
}

fn number(facts: Facts, name: String) -> Option(Float) {
  case list.key_find(facts, name) {
    Ok(Number(value)) -> Some(value)
    _ -> None
  }
}

// -- As data --------------------------------------------------------------------

/// The policy as JSON, for storing and exporting.
pub fn to_json(policy: Policy) -> Json {
  json.object([
    #("version", json.int(policy.version)),
    #(
      "rules",
      json.array(policy.rules, fn(rule) {
        json.object([
          #("when", condition_to_json(rule.condition)),
          #("then", outcome_to_json(rule.then)),
        ])
      }),
    ),
    #("otherwise", outcome_to_json(policy.otherwise)),
  ])
}

/// Decodes a policy written by `to_json`.
pub fn decoder() -> Decoder(Policy) {
  use version <- decode.field("version", decode.int)
  use rules <- decode.field(
    "rules",
    decode.list({
      use when <- decode.field("when", condition_decoder())
      use then <- decode.field("then", outcome_decoder())
      decode.success(When(condition: when, then:))
    }),
  )
  use otherwise <- decode.field("otherwise", outcome_decoder())
  decode.success(Policy(version:, rules:, otherwise:))
}

/// An outcome as JSON.
pub fn outcome_to_json(outcome: Outcome) -> Json {
  case outcome {
    Proceed(sample: Never) -> wire.tagged("proceed", [#("sample", json.null())])
    Proceed(sample: PerCent(share)) ->
      wire.tagged("proceed", [#("sample", json.int(share))])
    Ask(eligible:) ->
      wire.tagged("ask", [#("eligible", eligible_to_json(eligible))])
    Consult(point:) -> wire.tagged("consult", [#("point", json.string(point))])
  }
}

/// Decodes an outcome written by `outcome_to_json`.
pub fn outcome_decoder() -> Decoder(Outcome) {
  use tag <- decode.field("t", decode.string)
  case tag {
    "proceed" -> {
      use share <- decode.field("sample", decode.optional(decode.int))
      case share {
        None -> decode.success(Proceed(Never))
        Some(share) -> decode.success(Proceed(PerCent(share)))
      }
    }
    "ask" -> {
      use eligible <- decode.field("eligible", eligible_decoder())
      decode.success(Ask(eligible))
    }
    "consult" -> {
      use point <- decode.field("point", decode.string)
      decode.success(Consult(point:))
    }
    _ -> decode.failure(Proceed(Never), "Outcome")
  }
}

/// An eligibility as JSON.
pub fn eligible_to_json(eligible: Eligible) -> Json {
  case eligible {
    AnyoneHolding(set:) -> wire.tagged("anyone", [#("set", json.string(set))])
    SomeoneElseHolding(set:) ->
      wire.tagged("someone_else", [#("set", json.string(set))])
    Either(of) ->
      wire.tagged("either", [#("of", json.array(of, eligible_to_json))])
    Several(count:, of:) ->
      wire.tagged("several", [
        #("count", json.int(count)),
        #("of", eligible_to_json(of)),
      ])
  }
}

/// Decodes an eligibility written by `eligible_to_json`.
pub fn eligible_decoder() -> Decoder(Eligible) {
  use <- decode.recursive
  use tag <- decode.field("t", decode.string)
  case tag {
    "anyone" -> {
      use set <- decode.field("set", decode.string)
      decode.success(AnyoneHolding(set))
    }
    "someone_else" -> {
      use set <- decode.field("set", decode.string)
      decode.success(SomeoneElseHolding(set))
    }
    "either" -> {
      use of <- decode.field("of", decode.list(eligible_decoder()))
      decode.success(Either(of))
    }
    "several" -> {
      use count <- decode.field("count", decode.int)
      use of <- decode.field("of", eligible_decoder())
      decode.success(Several(count:, of:))
    }
    _ -> decode.failure(AnyoneHolding(""), "Eligible")
  }
}

/// A step as JSON.
pub fn step_to_json(step: Step) -> Json {
  json.object([
    #("after", json.int(step.after)),
    #("outcome", outcome_to_json(step.outcome)),
  ])
}

/// Decodes a step written by `step_to_json`.
pub fn step_decoder() -> Decoder(Step) {
  use after <- decode.field("after", decode.int)
  use outcome <- decode.field("outcome", outcome_decoder())
  decode.success(Step(after:, outcome:))
}

fn condition_to_json(condition: Condition) -> Json {
  case condition {
    OwnAct -> wire.tagged("own_act", [])
    Below(fact: name, limit:) ->
      wire.tagged("below", [
        #("fact", json.string(name)),
        #("limit", json.float(limit)),
      ])
    AtLeast(fact: name, limit:) ->
      wire.tagged("at_least", [
        #("fact", json.string(name)),
        #("limit", json.float(limit)),
      ])
    Is(fact: name, value:) ->
      wire.tagged("is", [
        #("fact", json.string(name)),
        #("value", wire.fact(value)),
      ])
    Known(fact: name) -> wire.tagged("known", [#("fact", json.string(name))])
    All(of) -> wire.tagged("all", [#("of", json.array(of, condition_to_json))])
    AnyOf(of) ->
      wire.tagged("any", [#("of", json.array(of, condition_to_json))])
    Not(inner) -> wire.tagged("not", [#("of", condition_to_json(inner))])
  }
}

fn condition_decoder() -> Decoder(Condition) {
  use <- decode.recursive
  use tag <- decode.field("t", decode.string)
  case tag {
    "own_act" -> decode.success(OwnAct)
    "below" -> {
      use name <- decode.field("fact", decode.string)
      use limit <- decode.field("limit", wire.number_decoder())
      decode.success(Below(fact: name, limit:))
    }
    "at_least" -> {
      use name <- decode.field("fact", decode.string)
      use limit <- decode.field("limit", wire.number_decoder())
      decode.success(AtLeast(fact: name, limit:))
    }
    "is" -> {
      use name <- decode.field("fact", decode.string)
      use value <- decode.field("value", wire.fact_decoder())
      decode.success(Is(fact: name, value:))
    }
    "known" -> {
      use name <- decode.field("fact", decode.string)
      decode.success(Known(fact: name))
    }
    "all" -> {
      use of <- decode.field("of", decode.list(condition_decoder()))
      decode.success(All(of))
    }
    "any" -> {
      use of <- decode.field("of", decode.list(condition_decoder()))
      decode.success(AnyOf(of))
    }
    "not" -> {
      use of <- decode.field("of", condition_decoder())
      decode.success(Not(of))
    }
    _ -> decode.failure(OwnAct, "Condition")
  }
}
