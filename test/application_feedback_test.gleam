//// What three applications built on the library showed the core must do
//// (items A to P of the coordinator's list).

import decisions.{type Desk, Gated}
import decisions/fact
import decisions/learning
import decisions/memory.{type Memory}
import decisions/model
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Either, Never, Proceed, Several, When}
import decisions/store
import decisions/testing
import decisions/view
import decisions/vocabulary.{
  type Ref, Agent, Approve, ApproveRejectOrCorrect, Correct, Manifest, Reason,
  Recommendation, Ref, RuleFired, Subject, Trigger, Validator,
}
import decisions/wire
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration
import gleam/time/timestamp
import json/blueprint/codec as blueprint
import support/policies
import support/world

const felipe = Validator("felipe", ["finance"])

const bia = Validator("bia", ["finance"])

const dora = Validator("dora", ["head_of_finance"])

fn tool() {
  Gated(name: "pay", guard: fn(_, _) { Ok([]) }, execute: fn(tx, released) {
    world.push(tx, "paid", decisions.output(released))
    Ok(Nil)
  })
}

fn desk(point, p) -> Desk(String, Memory) {
  decisions.desk(
    point,
    drives: fn(_) { tool() },
    under: fn(_) { Ok(p) },
    over: memory.port(),
  )
}

fn base_point() {
  decisions.point("app.payout", wire.text())
  |> decisions.allowing(ApproveRejectOrCorrect)
}

fn proposal(output: String, by) {
  decisions.proposal(
    trigger: Trigger("t", output),
    about: Subject("company", "clinica-x"),
    context: Manifest([Ref("request", output, "1")], "r"),
    recommending: Recommendation(output, by, RuleFired("r"), [], []),
  )
}

fn recommend(db: Memory, desk, output: String) {
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(
      desk,
      _,
      proposal(output, Agent("treasury", "2")),
    ))
  w
}

fn decide(db: Memory, desk, id: String, who, verdict) {
  memory.transaction(db, world.open_and_decide(desk, _, id, who, verdict))
}

fn same(ref: Ref) -> String {
  ref.revision
}

// -- A. `Either` around `Several` --------------------------------------------------

fn finance_or_head() {
  policies.checked(
    1,
    [],
    Either([
      Several(2, AnyoneHolding("finance")),
      AnyoneHolding("head_of_finance"),
    ]),
  )
}

pub fn a_one_finance_approval_is_not_enough_two_are_test() {
  let db = world.new().db
  let d = desk(base_point(), finance_or_head())
  let w = recommend(db, d, "12000")
  let assert Ok(after_one) = decide(db, d, w.id, felipe, Approve)
  let assert occurrence.Awaiting(_) = after_one.status
  assert world.all(db, "paid") == []
  // The head still sees the card; Felipe does not.
  assert memory.queue_for(db, felipe) == []
  assert memory.queue_for(db, dora) == [w.id]
  let assert Ok(after_two) = decide(db, d, w.id, bia, Approve)
  let assert occurrence.Released(..) = after_two.status
  assert world.all(db, "paid") == ["12000"]
  let assert Ok(_) =
    testing.check(db, memory.inspection(), [testing.audit_record(d)])
}

pub fn a_one_head_approval_is_enough_test() {
  let db = world.new().db
  let d = desk(base_point(), finance_or_head())
  let w = recommend(db, d, "12000")
  let assert Ok(done) = decide(db, d, w.id, dora, Approve)
  let assert occurrence.Released(..) = done.status
}

pub fn a_a_correction_voids_earlier_approvals_test() {
  let db = world.new().db
  let d = desk(base_point(), finance_or_head())
  let w = recommend(db, d, "12000")
  let assert Ok(_) = decide(db, d, w.id, felipe, Approve)
  // Bia corrects: her correction is one approval of the new amount, and
  // Felipe's approval of the old one no longer counts.
  let assert Ok(corrected) =
    decide(db, d, w.id, bia, Correct("11000", Reason("amount", None)))
  let assert occurrence.Awaiting(_) = corrected.status
  assert occurrence.standing(corrected) == #("11000", ["bia"])
  let assert Ok(done) = decide(db, d, w.id, felipe, Approve)
  let assert occurrence.Released(final: "11000", ..) = done.status
}

// -- B and C. An undo window on what the policy let proceed ----------------------------

pub fn b_finance_may_withdraw_what_the_policy_let_proceed_test() {
  let db = world.new().db
  let d =
    desk(
      base_point()
        |> decisions.signal(fact_small())
        |> decisions.withdrawn_by("finance"),
      policies.checked(
        1,
        [
          When(
            policy.known(fact_small()),
            Proceed(Never, Some(duration.minutes(30))),
          ),
        ],
        AnyoneHolding("finance"),
      ),
    )
  let assert Ok(held) =
    memory.transaction(db, decisions.recommend(d, _, small("80")))
  let assert occurrence.Held(by: occurrence.ByPolicy(1), ..) = held.status
  // Nobody decided it, so `withdraw` by name finds no decider.
  assert memory.transaction(db, decisions.withdraw(
      d,
      _,
      occurrence: held.id,
      by: "bia",
    ))
    |> result.replace(Nil)
    == Error(decisions.NotTheDecider)
  // Someone outside finance may not use the window.
  assert memory.transaction(db, decisions.withdraw_as(
      d,
      _,
      occurrence: held.id,
      by: Validator("caio", ["support"]),
    ))
    |> result.replace(Nil)
    == Error(decisions.NotTheDecider)
  let assert Ok(withdrawn) =
    memory.transaction(db, decisions.withdraw_as(
      d,
      _,
      occurrence: held.id,
      by: bia,
    ))
  assert withdrawn.status == occurrence.Withdrawn(by: "bia")
  assert world.all(db, "paid") == []
}

pub fn b_without_withdrawn_by_only_the_decider_may_test() {
  let db = world.new().db
  let d =
    desk(
      base_point() |> decisions.with_hold(duration.minutes(30)),
      policies.checked(1, [], AnyoneHolding("finance")),
    )
  let w = recommend(db, d, "80")
  let assert Ok(held) = decide(db, d, w.id, felipe, Approve)
  let assert occurrence.Held(..) = held.status
  assert memory.transaction(db, decisions.withdraw_as(
      d,
      _,
      occurrence: w.id,
      by: bia,
    ))
    |> result.replace(Nil)
    == Error(decisions.NotTheDecider)
  let assert Ok(_) =
    memory.transaction(db, decisions.withdraw_as(
      d,
      _,
      occurrence: w.id,
      by: felipe,
    ))
}

pub fn c_a_proceed_hold_takes_the_place_of_the_points_hold_test() {
  let db = world.new().db
  let d =
    desk(
      base_point()
        |> decisions.signal(fact_small())
        |> decisions.with_hold(duration.minutes(5)),
      policies.checked(
        1,
        [
          When(
            policy.known(fact_small()),
            Proceed(Never, Some(duration.minutes(30))),
          ),
        ],
        AnyoneHolding("finance"),
      ),
    )
  // The policy's own hold wins for what it lets proceed ...
  let assert Ok(by_policy) =
    memory.transaction(db, decisions.recommend(d, _, small("80")))
  let assert occurrence.Held(until:, ..) = by_policy.status
  assert until == timestamp.add(world.t0(), duration.minutes(30))
  // ... and the point's hold applies to what a person accepted.
  let w = recommend(db, d, "900")
  let assert Ok(by_person) = decide(db, d, w.id, felipe, Approve)
  let assert occurrence.Held(until: person_until, ..) = by_person.status
  assert person_until == timestamp.add(world.t0(), duration.minutes(5))
}

fn fact_small() {
  fact.flag("small")
}

fn small(output: String) {
  decisions.proposal(
    trigger: Trigger("t", output),
    about: Subject("company", "clinica-x"),
    context: Manifest([], "r"),
    recommending: Recommendation(
      output,
      Agent("treasury", "2"),
      RuleFired("r"),
      [fact.set(fact_small(), True)],
      [],
    ),
  )
}

// -- D. One type for a handler's failure ----------------------------------------------

pub fn d_a_handler_failure_says_what_a_runtime_does_test() {
  assert decisions.handling(decisions.ApplicationFailed("the CRM timed out"))
    == decisions.Backoff
  // Every refusal, by its disposition.
  let refusals = [
    decisions.StoreFailed(store.Contended("x")),
    decisions.StoreFailed(store.Unavailable("x")),
    decisions.StoreFailed(store.Conflict("x")),
    decisions.NoPolicy("x"),
    decisions.ConsultFailed("risk", "x"),
    decisions.Unreadable("x"),
    decisions.UnknownOccurrence,
    decisions.NotRecommended([]),
    decisions.NotAwaiting,
    decisions.AlreadyDecided("bia"),
    decisions.NotEligible,
    decisions.VerdictNotAllowed,
    decisions.ReasonRequired,
    decisions.NoteRequired,
    decisions.NeverShown,
    decisions.OutputChanged,
    decisions.NotHeld,
    decisions.NotTheDecider,
    decisions.NotReleased,
    decisions.NotSampled,
    decisions.NotSettled,
    decisions.NotConsulting,
    decisions.InvalidFacts([]),
    decisions.KeyTaken("other"),
    decisions.Unpublishable([]),
    decisions.Unencodable("x"),
    decisions.ToolUnsure("x"),
  ]
  let expected = fn(refusal) {
    case decisions.disposition(refusal) {
      decisions.Transient -> decisions.Redeliver
      decisions.Retry -> decisions.Backoff
      decisions.Poisoned -> decisions.SetAside
      decisions.Final -> decisions.Drop
    }
  }
  list.each(refusals, fn(refusal) {
    assert decisions.handling(decisions.DeskRefused(refusal))
      == expected(refusal)
  })
  assert decisions.handling(decisions.DeskRefused(decisions.Unreadable("x")))
    == decisions.SetAside
  assert decisions.handling(
      decisions.DeskRefused(decisions.StoreFailed(store.Contended("deadlock"))),
    )
    == decisions.Redeliver
  assert decisions.handling(decisions.DeskRefused(decisions.NotAwaiting))
    == decisions.Drop
  // `ToolRefused` needs the desk's token: take one from a refused verdict.
  let db = world.new().db
  let refusing =
    decisions.desk(
      base_point(),
      drives: fn(_) {
        Gated(..tool(), execute: fn(_, _) { Error(decisions.Refuse("closed")) })
      },
      under: fn(_) { Ok(policies.checked(1, [], AnyoneHolding("finance"))) },
      over: memory.port(),
    )
  let w = recommend(db, refusing, "x")
  let assert Error(tool_refused) = decide(db, refusing, w.id, felipe, Approve)
  let assert decisions.ToolRefused(..) = tool_refused
  assert decisions.handling(decisions.DeskRefused(tool_refused))
    == decisions.Drop
}

// -- E. A provider that failed, with evidence -----------------------------------------

pub fn e_a_provider_failure_is_recorded_with_its_evidence_test() {
  let db = world.new().db
  let d = desk(base_point(), policies.checked(1, [], AnyoneHolding("finance")))
  let failure = model.ProviderFailed(provider: "anthropic", reason: "HTTP 529")
  assert model.retryable(failure)
  let exchange = Ref("llm_exchange", "call-9", "a1b2")
  let assert Ok([attempt]) =
    memory.transaction(
      db,
      decisions.record_failure_with(
        d,
        _,
        key: "app.payout:req-9",
        trigger: Trigger("request", "req-9"),
        about: Subject("company", "clinica-x"),
        failure:,
        evidence: [exchange],
      ),
    )
  assert attempt.failure == failure
  assert attempt.evidence == [exchange]
  // Read back from the store, the evidence is still there.
  let assert Error(decisions.NotRecommended([read_back])) =
    memory.transaction(db, decisions.read(d, _, occurrence: "app.payout:req-9"))
  assert read_back.evidence == [exchange]
}

// -- F. A typed card document ---------------------------------------------------------

pub fn f_the_card_document_has_a_codec_and_a_schema_test() {
  let db = world.new().db
  let d =
    desk(
      base_point(),
      policies.checked(1, [], Several(2, AnyoneHolding("finance"))),
    )
  let w = recommend(db, d, "12000")
  let assert Ok(_) =
    decide(db, d, w.id, felipe, Correct("11000", Reason("amount", None)))
  let assert Ok(card) =
    memory.transaction(db, decisions.open(
      d,
      _,
      occurrence: w.id,
      by: bia,
      latest: same,
    ))
  let shown = view.of(card, content: fn(ref: Ref) { Ok("request " <> ref.id) })
  let card_codec = view.codec(wire.text())
  // The schema exists, and `to_json` is what the codec encodes.
  let assert Ok(_) = blueprint.schema(card_codec)
  let assert Ok(document) = view.to_json(shown, wire.text())
  let text = json.to_string(document)
  assert blueprint.encode_json(card_codec, shown) == Ok(text)
  // A client decodes it typed, and gets the same view back.
  assert blueprint.decode_json(card_codec, text) == Ok(shown)
  assert shown.standing == "11000"
}

// -- G. What really happened ------------------------------------------------------------

pub fn g_the_account_and_who_decided_over_every_status_test() {
  let db = world.new().db
  let d =
    desk(
      base_point()
        |> decisions.with_hold(duration.minutes(5))
        |> decisions.valid_for(duration.hours(1)),
      policies.checked(1, [], AnyoneHolding("finance")),
    )
  let refusing =
    decisions.desk(
      decisions.point("app.refusing", wire.text())
        |> decisions.allowing(ApproveRejectOrCorrect),
      drives: fn(_) {
        Gated(..tool(), execute: fn(_, _) {
          Error(decisions.Refuse("account closed"))
        })
      },
      under: fn(_) {
        Ok(policies.checked(
          1,
          [policy.When(policy.Always, Proceed(Never, None))],
          policy.AnyoneHolding("nobody"),
        ))
      },
      over: memory.port(),
    )
  // Waiting.
  let waiting = recommend(db, d, "a")
  assert occurrence.account(waiting) == occurrence.Undecided
  assert occurrence.decided_by(waiting) == None
  // Held, then released with an effect that is still uncertain, then known.
  let held = recommend(db, d, "b")
  let assert Ok(held) = decide(db, d, held.id, felipe, Approve)
  assert occurrence.account(held) == occurrence.Undecided
  assert occurrence.decided_by(held) == Some(occurrence.APerson("felipe"))
  // Rejected.
  let rejected = recommend(db, d, "c")
  let assert Ok(rejected) =
    decide(
      db,
      d,
      rejected.id,
      bia,
      vocabulary.Reject(Reason("duplicate", None)),
    )
  assert occurrence.account(rejected)
    == occurrence.TurnedDown(by: "bia", reason: Reason("duplicate", None))
  assert occurrence.decided_by(rejected) == Some(occurrence.APerson("bia"))
  // Withdrawn.
  let withdrawn = recommend(db, d, "d")
  let assert Ok(_) = decide(db, d, withdrawn.id, felipe, Approve)
  let assert Ok(withdrawn) =
    memory.transaction(db, decisions.withdraw(
      d,
      _,
      occurrence: withdrawn.id,
      by: "felipe",
    ))
  assert occurrence.account(withdrawn) == occurrence.TakenBack(by: "felipe")
  assert occurrence.decided_by(withdrawn) == Some(occurrence.APerson("felipe"))
  // Refused by the tool, after the policy let it proceed.
  let assert Ok(refused) =
    memory.transaction(db, decisions.recommend(
      refusing,
      _,
      proposal("e", Agent("treasury", "2")),
    ))
  assert occurrence.account(refused)
    == occurrence.Blocked(reason: "account closed")
  assert occurrence.decided_by(refused) == Some(occurrence.ThePolicy(1))
  // Released, with the effect not known, then known.
  memory.set_clock(db, timestamp.add(memory.now(db), duration.minutes(5)))
  let assert Ok(decisions.Woken(released)) =
    memory.transaction(db, decisions.wake(d, _, occurrence: held.id))
  assert occurrence.account(released)
    == occurrence.Done(final: "b", key: "release:" <> held.id, effect: None)
  let assert Ok(uncertain) =
    memory.transaction(db, decisions.report(
      d,
      _,
      occurrence: held.id,
      effect: vocabulary.Uncertain("timeout"),
    ))
  assert occurrence.account(uncertain)
    == occurrence.Done(final: "b", key: "release:" <> held.id, effect: None)
  let receipt = vocabulary.Performed(Ref("bank", "tx-1", "1"))
  let assert Ok(known) =
    memory.transaction(db, decisions.report(
      d,
      _,
      occurrence: held.id,
      effect: receipt,
    ))
  assert occurrence.account(known)
    == occurrence.Done(
      final: "b",
      key: "release:" <> held.id,
      effect: Some(receipt),
    )
  // Expired.
  memory.set_clock(db, timestamp.add(memory.now(db), duration.hours(2)))
  let assert Ok(decisions.Woken(expired)) =
    memory.transaction(db, decisions.wake(d, _, occurrence: waiting.id))
  assert occurrence.account(expired)
    == occurrence.Lapsed(vocabulary.DeadlinePassed)
  assert occurrence.decided_by(expired) == None
}

// -- I. Evidence a release relied on, with the output in hand -----------------------------

pub fn i_a_release_check_records_its_evidence_test() {
  let db = world.new().db
  let balance = Ref("balance", "clinica-x", "r7")
  let d =
    desk(
      base_point(),
      policies.checked(
        1,
        [policy.When(policy.Always, Proceed(Never, None))],
        policy.AnyoneHolding("nobody"),
      ),
    )
    |> decisions.checking(with: fn(_tx, release: decisions.ToRelease(String)) {
      case release.output {
        "too much" -> Error(decisions.Refuse("the balance does not cover it"))
        _ -> Ok([balance])
      }
    })
  let assert Ok(paid) =
    memory.transaction(db, decisions.recommend(
      d,
      _,
      proposal("80", Agent("treasury", "2")),
    ))
  assert occurrence.relied(paid) == [balance]
  let assert Ok(refused) =
    memory.transaction(db, decisions.recommend(
      d,
      _,
      proposal("too much", Agent("treasury", "2")),
    ))
  assert refused.status == occurrence.Refused("the balance does not cover it")
  assert world.all(db, "paid") == ["80"]
}

// -- K. Uniform sampling --------------------------------------------------------------

fn sampled_share(ids: List(String), per_cent: Int) -> Int {
  list.count(ids, policy.is_sampled(policy.PerCent(per_cent), _))
}

pub fn k_sampling_is_uniform_over_sequential_and_random_keys_test() {
  let sequential =
    list.map(world.numbers(1, 10_000), fn(n) {
      "moderation:post-" <> int.to_string(n) <> "@1"
    })
  let random_looking =
    list.map(world.numbers(1, 10_000), fn(n) { model.digest(int.to_string(n)) })
  // Within four standard deviations of the share on 10 000 occurrences:
  // ±40 at 1 %, ±56 at 2 %, ±120 at 10 %, ±200 at 50 %.
  list.each([1, 2, 10, 50], fn(per_cent) {
    list.each([sequential, random_looking], fn(ids) {
      let got = sampled_share(ids, per_cent)
      let expected = per_cent * 100
      let tolerance = case per_cent {
        1 -> 40
        2 -> 56
        10 -> 120
        _ -> 200
      }
      case got > expected - tolerance && got < expected + tolerance {
        True -> Nil
        False ->
          panic as {
            int.to_string(got)
            <> " sampled for "
            <> int.to_string(per_cent)
            <> " %"
          }
      }
    })
  })
  // The desk samples by the same rule.
  let db = world.new().db
  let d =
    desk(
      base_point(),
      policies.checked(
        1,
        [policy.When(policy.Always, Proceed(policy.PerCent(50), None))],
        policy.AnyoneHolding("nobody"),
      ),
    )
  list.each(list.take(sequential, 40), fn(id) {
    let assert Ok(made) =
      memory.transaction(db, decisions.recommend_once(
        d,
        _,
        key: id,
        proposal: proposal(id, Agent("m", "1")),
      ))
    assert made.sampled == policy.is_sampled(policy.PerCent(50), id)
  })
}

// -- L. `open` says why a card would be of no use ------------------------------------------

pub fn l_open_refuses_a_card_nobody_can_use_test() {
  let db = world.new().db
  let d = desk(base_point(), policies.checked(1, [], AnyoneHolding("finance")))
  let w = recommend(db, d, "a")
  let assert Ok(_) = decide(db, d, w.id, felipe, Approve)
  assert memory.transaction(db, decisions.open(
      d,
      _,
      occurrence: w.id,
      by: bia,
      latest: same,
    ))
    |> result.replace(Nil)
    == Error(decisions.AlreadyDecided("felipe"))
  let proceeding =
    desk(
      base_point(),
      policies.checked(
        1,
        [policy.When(policy.Always, Proceed(Never, None))],
        policy.AnyoneHolding("nobody"),
      ),
    )
  let p = recommend(db, proceeding, "b")
  assert memory.transaction(db, decisions.open(
      proceeding,
      _,
      occurrence: p.id,
      by: bia,
      latest: same,
    ))
    |> result.replace(Nil)
    == Error(decisions.NotSampled)
}

// -- M. The superseding window and the recipe that closes it --------------------------------

fn superseded_desk() {
  desk(
    base_point() |> decisions.superseded_by("newer_message"),
    policies.checked(1, [], AnyoneHolding("finance")),
  )
}

pub fn m_a_key_never_expected_still_escapes_superseding_test() {
  let db = world.new().db
  let d = superseded_desk()
  // m2 arrives and supersedes what waits: nothing yet.
  let assert Ok(decisions.Supersession(expired: [], ..)) =
    memory.transaction(db, decisions.happened(
      d,
      _,
      "newer_message",
      about: Subject("company", "clinica-x"),
    ))
  // The worker for m1 commits after it: its occurrence escapes.
  let late = recommend(db, d, "reply to m1")
  let assert occurrence.Awaiting(_) = late.status
}

pub fn m_an_expected_key_closes_the_window_test() {
  let db = world.new().db
  let d = superseded_desk()
  let subject = Subject("company", "clinica-x")
  // Trigger m1 is received: the record expects a recommendation for it.
  let receive = fn(trigger: String) {
    memory.transaction(db, fn(tx) {
      use _ <- result.try(decisions.happened(
        d,
        tx,
        "newer_message",
        about: subject,
      ))
      decisions.expect(
        d,
        tx,
        key: "reply:" <> trigger,
        trigger: Trigger("message", trigger),
        about: subject,
      )
    })
  }
  let worker_commits = fn(trigger: String) {
    memory.transaction(db, decisions.recommend_once(
      d,
      _,
      key: "reply:" <> trigger,
      proposal: proposal("reply to " <> trigger, Agent("reply", "7")),
    ))
  }
  let assert Ok(Nil) = receive("m1")
  let assert Ok(Nil) = receive("m2")
  assert worker_commits("m1") |> result.replace(Nil)
    == Error(decisions.SupersededBefore("newer_message"))
  let assert Ok(current) = worker_commits("m2")
  let assert occurrence.Awaiting(_) = current.status
  assert memory.queue(db, "finance") == [current.id]
}

// -- N. Helpers applications wrote themselves -------------------------------------------------

pub fn n_a_model_as_a_stage_and_a_revision_now_test() {
  let declines = model.new(fn(_, _) { Error(model.Declined("not sure")) })
  let answers =
    model.new(fn(_, _) {
      Ok(Recommendation("b", Agent("m", "1"), RuleFired("r"), [], []))
    })
  let sources = model.recorded([], [])
  let assert Ok(recommended) =
    model.run(
      model.cascade([model.stage(declines), model.stage(answers)]),
      Manifest([], "r"),
      sources,
    )
  assert recommended.output == "b"
  // The revision a capture gives is what `digest` gives the same content.
  let db = world.new().db
  let assert Ok(captured) =
    model.capture(
      memory.evidence(),
      db,
      source: "balance",
      request: "x",
      fetch: fn() { Ok("80.00") },
    )
  assert captured.ref.revision == model.digest("80.00")
}

pub fn n_what_a_candidate_policy_would_do_with_an_example_test() {
  let db = world.new().db
  let amount = fact.number("amount")
  let point =
    base_point()
    |> decisions.fact(amount, fn(output: String) {
      case int.parse(output) {
        Ok(n) -> int.to_float(n)
        Error(Nil) -> 0.0
      }
    })
  let d = desk(point, policies.checked(1, [], AnyoneHolding("finance")))
  let w = recommend(db, d, "80")
  let assert Ok(done) = decide(db, d, w.id, felipe, Approve)
  let assert Ok(example) =
    learning.example(
      done,
      as_of: memory.now(db),
      from: learning.Archive(
        render: fn(_) { Ok("r") },
        reads: fn(_) { [] },
        content: fn(_) { Ok("x") },
      ),
    )
  let candidate =
    policies.checked(
      2,
      [When(policy.below(amount, 100.0), Proceed(Never, None))],
      AnyoneHolding("finance"),
    )
  assert learning.answer_under(example, policy: candidate, point:)
    == Proceed(Never, None)
}

// -- O. The release sees the occurrence's context -------------------------------------------

pub fn o_a_release_check_reads_the_context_test() {
  let db = world.new().db
  let d =
    desk(
      base_point(),
      policies.checked(
        1,
        [policy.When(policy.Always, Proceed(Never, None))],
        policy.AnyoneHolding("nobody"),
      ),
    )
    |> decisions.checking(with: fn(_, release: decisions.ToRelease(String)) {
      case release.context.refs {
        [Ref(kind: "request", revision: "1", ..)] -> Ok([])
        _ -> Error(decisions.Refuse("the request changed revision"))
      }
    })
  let assert Ok(paid) =
    memory.transaction(db, decisions.recommend(
      d,
      _,
      proposal("80", Agent("treasury", "2")),
    ))
  let assert occurrence.Released(..) = paid.status
}
