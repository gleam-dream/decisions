//// One test per correction an independent review asked for (C1 to C15),
//// each the reviewer's probe scenario turned around: it fails without the
//// correction.

import decisions.{type Desk, Gated}
import decisions/entry
import decisions/fact
import decisions/learning
import decisions/memory.{type Memory}
import decisions/model
import decisions/occurrence
import decisions/policy.{
  AnyoneHolding, Ask, Consult, Never, PerCent, Proceed, Several,
  SomeoneElseHolding, When,
}
import decisions/store
import decisions/testing
import decisions/view
import decisions/vocabulary.{
  type Ref, Approve, ApproveRejectOrCorrect, Correct, Manifest, Person, Reason,
  Recommendation, Ref, Reject, RuleFired, Rules, Subject, Text, Trigger,
  Validator,
}
import decisions/wire
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import support/policies
import support/world

const ana = Validator("ana", ["finance"])

const bia = Validator("bia", ["finance"])

const caio = Validator("caio", ["finance"])

fn effects(db: Memory) -> List(String) {
  world.all(db, "effects")
}

fn tool() {
  Gated(
    name: "probe_tool",
    guard: fn(_, _) { Ok([]) },
    execute: fn(tx, released) {
      world.push(tx, "effects", decisions.output(released))
      Ok(Nil)
    },
  )
}

fn desk_with(point, p) -> Desk(String, Memory) {
  decisions.desk(
    point,
    drives: fn(_) { tool() },
    under: fn(_) { Ok(p) },
    over: memory.port(),
  )
}

fn base_point() {
  decisions.point("probe.point", wire.text())
  |> decisions.allowing(ApproveRejectOrCorrect)
}

fn proposal(output: String) {
  decisions.proposal(
    trigger: Trigger("t", output),
    about: Subject("company", "x"),
    context: Manifest(refs: [Ref("m", "1", "1")], renderer: "r"),
    recommending: Recommendation(
      output:,
      by: Rules("r", "1"),
      explanation: RuleFired("r"),
      signals: [],
      reads: [],
    ),
  )
}

fn fresh() -> Memory {
  let db = memory.new()
  memory.set_clock(db, world.t0())
  db
}

fn same(ref: Ref) -> String {
  ref.revision
}

fn at(db: Memory, minutes: Int) -> Nil {
  memory.set_clock(db, timestamp.add(world.t0(), duration.minutes(minutes)))
}

fn four_eyes() {
  desk_with(
    base_point(),
    policies.checked(1, [], Several(2, AnyoneHolding("finance"))),
  )
}

fn open(db, desk, id, who) {
  memory.transaction(db, decisions.open(desk, _, id, by: who, latest: same))
}

fn decide(db, desk, card, verdict) {
  memory.transaction(db, decisions.decide(desk, _, card, verdict))
}

/// C1. A card shown before someone else's correction cannot approve the
/// corrected output, fresh or through its ticket; the view shows the
/// output that stands and who approved it.
pub fn c1_a_stale_card_cannot_approve_a_correction_test() {
  let db = fresh()
  let desk = four_eyes()
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(desk, _, proposal("100")))
  let assert Ok(ana_card) = open(db, desk, w.id, ana)
  let ticket = decisions.ticket(ana_card)
  let assert Ok(bia_card) = open(db, desk, w.id, bia)
  let assert Ok(_) =
    decide(db, desk, bia_card, Correct("999", Reason("amount", None)))
  assert decide(db, desk, ana_card, Approve) == Error(decisions.OutputChanged)
  assert memory.transaction(db, fn(tx) {
      decisions.resume(desk, tx, ticket, by: ana) |> result.replace(Nil)
    })
    == Error(decisions.OutputChanged)
  assert effects(db) == []

  // Bia's own card is not stale: her correction, sent again, stands.
  let assert Ok(again) =
    decide(db, desk, bia_card, Correct("999", Reason("amount", None)))
  let assert occurrence.Awaiting(_) = again.status

  // A fresh card shows the output that stands and who approved it.
  let assert Ok(caio_card) = open(db, desk, w.id, caio)
  let shown = view.of(caio_card, content: fn(_) { Ok("x") })
  assert shown.recommendation.output == "100"
  assert shown.standing == "999"
  assert shown.approvals
    == view.Approvals(by: ["bia"], alternatives: [
      view.Alternative(sets: ["finance"], have: 1, need: 2),
    ])
  let assert Ok(document) = view.to_json(shown, wire.text())
  let document = json.to_string(document)
  assert string.contains(document, "\"standing_output\":\"999\"")
  assert string.contains(document, "\"by\":[\"bia\"]")
  let assert Ok(done) = decide(db, desk, caio_card, Approve)
  let assert occurrence.Released(final: "999", ..) = done.status
}

/// C2. A later answer that consults asks the consulted point, and a
/// wake-up never names a time already past.
pub fn c2_a_consulting_step_asks_and_wake_never_loops_test() {
  let db = fresh()
  let asked = fn(tx, consultation: decisions.Consultation(String)) {
    world.push(tx, "consulted", consultation.point)
    Ok(Nil)
  }
  let p =
    policies.checked(
      1,
      [
        When(policy.waited(60), Proceed(Never, None)),
        When(policy.waited(30), Consult("risk")),
      ],
      AnyoneHolding("finance"),
    )
  let desk = desk_with(base_point(), p) |> decisions.consulting(asked)
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(desk, _, proposal("100")))
  at(db, 31)
  let assert Ok(decisions.Woken(c)) =
    memory.transaction(db, decisions.wake(desk, _, w.id))
  let assert occurrence.Recommended(consulting: Some("risk")) = c.status
  assert world.all(db, "consulted") == ["risk"]
  // Consulting drops the later steps: nothing is due until the answer.
  at(db, 61)
  assert memory.transaction(db, decisions.wake(desk, _, w.id))
    == Ok(decisions.NothingDue)
  let #(_, handler) = decisions.waker(desk)
  assert memory.transaction(db, handler(_, w.id)) == Ok(None)
  world.invariants_hold(world.World(..world.new(), db:), [
    testing.audit_record(desk),
  ])
}

/// C3. Once the hold has ended by the store's clock, the decider can no
/// longer withdraw, whether or not the wake-up was delivered.
pub fn c3_withdraw_after_the_hold_ended_is_refused_test() {
  let db = fresh()
  let desk =
    desk_with(
      base_point() |> decisions.with_hold(duration.minutes(5)),
      policies.checked(1, [], AnyoneHolding("finance")),
    )
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(desk, _, proposal("100")))
  let assert Ok(card) = open(db, desk, w.id, ana)
  let assert Ok(_) = decide(db, desk, card, Approve)
  at(db, 60)
  assert memory.transaction(db, decisions.withdraw(desk, _, w.id, by: "ana"))
    == Error(decisions.NotHeld)
  let assert Ok(decisions.Woken(released)) =
    memory.transaction(db, decisions.wake(desk, _, w.id))
  let assert occurrence.Released(..) = released.status
  assert effects(db) == ["100"]
}

/// C4. After the validity passed, no verb shows or writes on the
/// occurrence, delivered wake-up or not.
pub fn c4_nothing_is_shown_or_written_after_the_deadline_test() {
  let db = fresh()
  let desk =
    desk_with(
      base_point() |> decisions.valid_for(duration.hours(1)),
      policies.checked(1, [], AnyoneHolding("finance")),
    )
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(desk, _, proposal("100")))
  let assert Ok(card) = open(db, desk, w.id, ana)
  let ticket = decisions.ticket(card)
  let before = memory.entries(db, w.id)
  at(db, 90)
  assert open(db, desk, w.id, bia) |> result.replace(Nil)
    == Error(decisions.NotAwaiting)
  assert memory.transaction(db, decisions.note(desk, _, card, "late note"))
    |> result.replace(Nil)
    == Error(decisions.NotAwaiting)
  assert memory.transaction(db, decisions.expand(
      desk,
      _,
      card,
      read: "x",
      result: Ref("x", "1", "1"),
    ))
    |> result.replace(Nil)
    == Error(decisions.NotAwaiting)
  assert memory.transaction(db, fn(tx) {
      decisions.resume(desk, tx, ticket, by: ana) |> result.replace(Nil)
    })
    == Error(decisions.NotAwaiting)
  assert memory.entries(db, w.id) == before
}

/// C5. A refusal is recorded only from the token the desk made, with the
/// validator, the verdict and the showing it was given on.
pub fn c5_a_refusal_is_recorded_only_from_its_token_test() {
  let db = fresh()
  let refusing =
    decisions.desk(
      base_point(),
      drives: fn(_) {
        Gated(..tool(), execute: fn(_, _) {
          Error(decisions.Refuse("the ledger is closed"))
        })
      },
      under: fn(_) { Ok(policies.checked(1, [], AnyoneHolding("finance"))) },
      over: memory.port(),
    )
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(refusing, _, proposal("100")))
  let assert Ok(card) = open(db, refusing, w.id, ana)
  let assert Error(decisions.ToolRefused(
    reason: "the ledger is closed",
    rollback:,
  )) = decide(db, refusing, card, Approve)
  // Another point's desk does not accept it.
  let other =
    desk_with(
      decisions.point("probe.other", wire.text()),
      policies.checked(
        1,
        [policy.When(policy.Always, Proceed(Never, None))],
        policy.AnyoneHolding("nobody"),
      ),
    )
  assert memory.transaction(db, decisions.record_refusal(other, _, rollback))
    |> result.replace(Nil)
    == Error(decisions.UnknownOccurrence)
  let assert Ok(kept) =
    memory.transaction(db, decisions.record_refusal(refusing, _, rollback))
  assert occurrence.refusals(kept)
    == [#("ana", Approve, "the ledger is closed")]
  let assert Ok(last) = list.last(kept.entries)
  let assert entry.VerdictRefused(seen:, ..) = last.event
  assert seen == decisions.ticket(card).seen
  let assert occurrence.Awaiting(_) = kept.status
  world.invariants_hold(world.World(..world.new(), db:), [
    testing.audit_record(refusing),
  ])
}

/// C6. A card opened while the occurrence waited for a consulted point was
/// never shown as a card to decide on; `inform` takes the answer only from
/// the consulted point, with declared facts of the declared type.
pub fn c6_only_a_recorded_showing_decides_and_only_the_consulted_point_answers_test() {
  let db = fresh()
  let risk = fact.text("risk")
  let p =
    policies.checked(
      1,
      [
        When(policy.known(risk), Ask(AnyoneHolding("finance"))),
        policy.When(policy.Always, Consult("risk")),
      ],
      policy.AnyoneHolding("nobody"),
    )
  let desk =
    desk_with(base_point() |> decisions.answer(risk, from: "risk"), p)
    |> decisions.consulting(fn(_, _) { Ok(Nil) })
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(desk, _, proposal("100")))
  // A card cannot even be opened while it waits for the consulted point.
  assert open(db, desk, w.id, ana) |> result.replace(Nil)
    == Error(decisions.NotAwaiting)
  let inform = fn(from, facts) {
    memory.transaction(db, decisions.inform(
      desk,
      _,
      occurrence: w.id,
      from:,
      facts:,
    ))
  }
  assert inform("not-risk", [fact.set(risk, "low")]) |> result.replace(Nil)
    == Error(decisions.NotConsulting)
  assert inform("risk", [#("risk", vocabulary.Number(1.0))])
    |> result.replace(Nil)
    == Error(
      decisions.InvalidFacts([
        policy.WrongKind(
          fact: "risk",
          declared: fact.TextFact,
          used: fact.NumberFact,
        ),
      ]),
    )
  assert inform("risk", [#("mood", Text("calm"))]) |> result.replace(Nil)
    == Error(decisions.InvalidFacts([policy.UndeclaredFact("mood")]))
  let assert Ok(asked) = inform("risk", [fact.set(risk, "low")])
  let assert occurrence.Awaiting(_) = asked.status
  let assert Ok(card) = open(db, desk, w.id, ana)
  let assert Ok(done) = decide(db, desk, card, Approve)
  let assert occurrence.Released(..) = done.status
}

/// C7. Under `SomeoneElseHolding`, neither the person who asked nor a
/// person recommending their own act may approve.
pub fn c7_four_eyes_cannot_be_bypassed_with_asked_by_test() {
  let db = fresh()
  let desk =
    desk_with(
      base_point(),
      policies.checked(1, [], SomeoneElseHolding("finance")),
    )
  let own =
    decisions.proposal(
      trigger: Trigger("t", "own"),
      about: Subject("company", "x"),
      context: Manifest([], "r"),
      recommending: Recommendation(
        "100",
        Person("caio"),
        vocabulary.OwnAct,
        [],
        [],
      ),
    )
    |> decisions.asked_by("bia")
  let assert Ok(w) = memory.transaction(db, decisions.recommend(desk, _, own))
  // `open` applies the rule `decide` applies, so neither gets a card.
  assert open(db, desk, w.id, caio) |> result.replace(Nil)
    == Error(decisions.NotEligible)
  assert open(db, desk, w.id, bia) |> result.replace(Nil)
    == Error(decisions.NotEligible)
  let assert Ok(ana_card) = open(db, desk, w.id, ana)
  let assert Ok(done) = decide(db, desk, ana_card, Approve)
  let assert occurrence.Released(..) = done.status
}

/// C8. Every verb reads the clock after the port's `load` returns.
pub fn c8_the_clock_is_read_after_the_lock_test() {
  let db = fresh()
  let base = memory.port()
  let logged =
    store.Port(
      ..base,
      load: fn(tx, id) {
        world.push(tx, "calls", "load")
        base.load(tx, id)
      },
      now: fn(tx) {
        world.push(tx, "calls", "now")
        base.now(tx)
      },
    )
  let desk =
    decisions.desk(
      base_point(),
      drives: fn(_) { tool() },
      under: fn(_) { Ok(policies.checked(1, [], AnyoneHolding("finance"))) },
      over: logged,
    )
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend_once(
      desk,
      _,
      key: "probe-1",
      proposal: proposal("100"),
    ))
  let first = fn() {
    world.all(db, "calls")
    |> list.filter(fn(call) { call == "load" || call == "now" })
  }
  let assert ["load", "now", ..] = first()
  let verbs = [
    fn(tx) {
      decisions.open(desk, tx, w.id, by: ana, latest: same)
      |> result.replace(Nil)
    },
    fn(tx) { decisions.wake(desk, tx, w.id) |> result.replace(Nil) },
    fn(tx) { decisions.read(desk, tx, w.id) |> result.replace(Nil) },
  ]
  list.each(verbs, fn(verb) {
    memory.put(db, "calls", "[]")
    let assert Ok(Nil) = memory.transaction(db, verb)
    let assert ["load", "now", ..] = first()
  })
}

/// C10. The checker sees a dropped policy-step wake-up and a head that
/// disagrees with its record.
pub fn c10_the_checker_sees_missing_wake_ups_and_a_wrong_head_test() {
  let db = fresh()
  let p =
    policies.checked(
      1,
      [When(policy.waited(60), Proceed(Never, None))],
      AnyoneHolding("finance"),
    )
  let desk = desk_with(base_point(), p)
  let assert Ok(_) =
    memory.transaction(db, decisions.recommend(desk, _, proposal("100")))
  let assert Ok(_) =
    testing.check(db, memory.inspection(), [testing.audit_record(desk)])
  memory.set_clock(db, timestamp.add(world.t0(), duration.hours(2)))
  let _ = memory.take_due(db)
  let assert Error([testing.Violation(invariant: "I5", ..)]) =
    testing.check(db, memory.inspection(), [testing.audit_record(desk)])

  let db = fresh()
  let base = memory.port()
  let wrong =
    store.Port(..base, append: fn(tx, id, head, entries) {
      base.append(tx, id, store.Head(..head, due: Some(world.t0())), entries)
    })
  let skewed =
    decisions.desk(
      base_point(),
      drives: fn(_) { tool() },
      under: fn(_) { Ok(p) },
      over: wrong,
    )
  let assert Ok(_) =
    memory.transaction(db, decisions.recommend(skewed, _, proposal("100")))
  let assert Error([testing.Violation(invariant: "I8", ..)]) =
    testing.check(db, memory.inspection(), [testing.audit_record(desk)])
}

/// C11. Each judged occurrence counts once toward agreement, against what
/// the recommender proposed: an approval after a correction is not
/// agreement, and two approvals are one judgement.
pub fn c11_each_occurrence_is_judged_once_test() {
  let db = fresh()
  let desk = four_eyes()
  let assert Ok(a) =
    memory.transaction(db, decisions.recommend(desk, _, proposal("100")))
  let assert Ok(c1) = open(db, desk, a.id, ana)
  let assert Ok(_) =
    decide(db, desk, c1, Correct("999", Reason("amount", None)))
  let assert Ok(c2) = open(db, desk, a.id, bia)
  let assert Ok(corrected) = decide(db, desk, c2, Approve)
  let assert Ok(b) =
    memory.transaction(db, decisions.recommend(desk, _, proposal("200")))
  let assert Ok(c3) = open(db, desk, b.id, ana)
  let assert Ok(_) = decide(db, desk, c3, Approve)
  let assert Ok(c4) = open(db, desk, b.id, bia)
  let assert Ok(approved) = decide(db, desk, c4, Approve)
  let tally = learning.total(learning.tally([corrected, approved]))
  assert #(tally.agreed, tally.judged) == #(1, 2)
}

/// C12. One review per reviewer, never by whoever decided, asked or
/// recommended it, and only by the point's reviewers when it names them.
pub fn c12_reviews_have_an_eligibility_test() {
  let db = fresh()
  let point = base_point() |> decisions.reviewed_by("audit")
  let desk =
    desk_with(
      point,
      policies.checked(
        1,
        [policy.When(policy.Always, Proceed(PerCent(100), None))],
        policy.AnyoneHolding("nobody"),
      ),
    )
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(
      desk,
      _,
      proposal("100") |> decisions.asked_by("bia"),
    ))
  let assert True = w.sampled
  let auditor = Validator("rui", ["audit"])
  assert open(db, desk, w.id, Validator("mallory", [])) |> result.replace(Nil)
    == Error(decisions.NotEligible)
  let review = fn(who, verdict) {
    memory.transaction(db, fn(tx) {
      use card <- result.try(decisions.open(
        desk,
        tx,
        w.id,
        by: who,
        latest: same,
      ))
      decisions.review(desk, tx, card, verdict)
    })
  }
  assert review(Validator("bia", ["audit"]), Approve) |> result.replace(Nil)
    == Error(decisions.NotEligible)
  let assert Ok(reviewed) = review(auditor, Approve)
  assert occurrence.reviews(reviewed) == [#("rui", Approve)]
  assert review(auditor, Reject(Reason("again", None))) |> result.replace(Nil)
    == Error(decisions.NotEligible)
}

/// C13. A consulted point's answer applies the policy current then, and
/// the entry records that version.
pub fn c13_inform_applies_and_records_the_current_version_test() {
  let db = fresh()
  let risk = fact.text("risk")
  let version = fn(n) {
    policies.checked(
      n,
      [
        When(policy.known(risk), Ask(AnyoneHolding("finance"))),
        policy.When(policy.Always, Consult("risk")),
      ],
      policy.AnyoneHolding("nobody"),
    )
  }
  let point = base_point() |> decisions.answer(risk, from: "risk")
  let first =
    desk_with(point, version(1)) |> decisions.consulting(fn(_, _) { Ok(Nil) })
  let second = desk_with(point, version(2))
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(first, _, proposal("100")))
  let assert Ok(asked) =
    memory.transaction(
      db,
      decisions.inform(second, _, occurrence: w.id, from: "risk", facts: [
        fact.set(risk, "low"),
      ]),
    )
  assert asked.policy_version == Some(2)
  assert list.map(occurrence.policy_answers(asked), fn(pair) {
      case pair.1 {
        Consult(_) -> "consult"
        _ -> "ask"
      }
    })
    == ["consult", "ask"]
}

/// C14. A failed consult handler, a key another point holds, the tool on
/// the release, and the reads of a cascade.
pub fn c14_interface_corrections_test() {
  let db = fresh()
  let failing =
    desk_with(
      base_point(),
      policies.checked(
        1,
        [policy.When(policy.Always, Consult("risk"))],
        policy.AnyoneHolding("nobody"),
      ),
    )
    |> decisions.consulting(fn(_, _) { Error("the queue is down") })
  assert memory.transaction(db, decisions.recommend(failing, _, proposal("1")))
    |> result.replace(Nil)
    == Error(decisions.ConsultFailed(point: "risk", reason: "the queue is down"))

  let a =
    desk_with(base_point(), policies.checked(1, [], AnyoneHolding("finance")))
  let b =
    desk_with(
      decisions.point("probe.other", wire.text()),
      policies.checked(1, [], AnyoneHolding("finance")),
    )
  let assert Ok(_) =
    memory.transaction(db, decisions.recommend_once(
      a,
      _,
      key: "k",
      proposal: proposal("1"),
    ))
  assert memory.transaction(db, decisions.recommend_once(
      b,
      _,
      key: "k",
      proposal: proposal("2"),
    ))
    |> result.replace(Nil)
    == Error(decisions.KeyTaken("probe.point"))
  assert memory.transaction(db, decisions.read(b, _, occurrence: "k"))
    |> result.replace(Nil)
    == Error(decisions.UnknownOccurrence)

  let released =
    desk_with(
      base_point(),
      policies.checked(
        1,
        [policy.When(policy.Always, Proceed(Never, None))],
        policy.AnyoneHolding("nobody"),
      ),
    )
  let assert Ok(done) =
    memory.transaction(db, decisions.recommend(released, _, proposal("1")))
  let assert Ok(last) = list.last(done.entries)
  let assert entry.Released(tool: "probe_tool", ..) = last.event

  // A stage that read and then abstained leaves no read on the record.
  let sources =
    model.Sources(
      resolve: fn(_) { Error(model.Declined("none")) },
      read: fn(name, argument) {
        Ok(model.Captured(Ref(name, argument, "1"), "body"))
      },
    )
  let abstains = fn(_, sources: model.Sources) {
    let _ = sources.read("balance", "abstained")
    Ok(None)
  }
  let answers = fn(_, sources: model.Sources) {
    use read <- result.map(sources.read("balance", "answered"))
    Some(Recommendation("1", Rules("r", "1"), RuleFired("r"), [], [read.ref]))
  }
  let assert Ok(recommended) =
    model.run(model.cascade([abstains, answers]), Manifest([], "r"), sources)
  assert list.map(recommended.reads, fn(ref) { ref.id }) == ["answered"]

  // A typed reader whose reads are observed, with an agent loop that
  // reports what it received.
  let reader = fn(_, sources: model.Sources) {
    sources.read("profile", "ana") |> result.map(fn(c) { c.body })
  }
  let agent =
    model.over_reporting(reader, fn(_profile) {
      Ok(
        Recommendation("1", Rules("r", "1"), RuleFired("r"), [], [
          Ref("balance", "kept", "1"),
        ]),
      )
    })
  let assert Ok(reported) = model.run(agent, Manifest([], "r"), sources)
  assert list.map(reported.reads, fn(ref) { ref.id }) == ["ana", "kept"]

  // Under `Several`, a validator who approved may not then reject the same
  // output.
  let desk = four_eyes()
  let assert Ok(w) =
    memory.transaction(db, decisions.recommend(desk, _, proposal("100")))
  let assert Ok(card) = open(db, desk, w.id, ana)
  let assert Ok(_) = decide(db, desk, card, Approve)
  assert decide(db, desk, card, Reject(Reason("x", None)))
    == Error(decisions.NotEligible)
}

/// C15. `PerCent(0)` survives storage; superseding after the deadline says
/// the deadline ended it; a held occurrence is not superseded.
pub fn c15_documented_behaviour_holds_test() {
  let p =
    policies.checked(
      1,
      [policy.When(policy.Always, Proceed(PerCent(0), None))],
      policy.AnyoneHolding("nobody"),
    )
  assert json.parse(json.to_string(policy.to_json(p)), policy.decoder())
    == Ok(p)
  assert json.parse(
      json.to_string(
        policy.to_json(policies.checked(
          1,
          [policy.When(policy.Always, Proceed(Never, None))],
          policy.AnyoneHolding("nobody"),
        )),
      ),
      policy.decoder(),
    )
    == Ok(policies.checked(
      1,
      [policy.When(policy.Always, Proceed(Never, None))],
      policy.AnyoneHolding("nobody"),
    ))

  let db = fresh()
  let point =
    base_point()
    |> decisions.valid_for(duration.hours(1))
    |> decisions.superseded_by("new")
  let desk = desk_with(point, policies.checked(1, [], AnyoneHolding("finance")))
  let assert Ok(_) =
    memory.transaction(db, decisions.recommend(desk, _, proposal("100")))
  at(db, 600)
  let assert Ok(decisions.Supersession(expired: [e], ..)) =
    memory.transaction(db, decisions.happened(
      desk,
      _,
      "new",
      about: Subject("company", "x"),
    ))
  assert e.status == occurrence.Expired(vocabulary.DeadlinePassed)

  let db = fresh()
  let holding =
    desk_with(
      base_point()
        |> decisions.with_hold(duration.minutes(5))
        |> decisions.superseded_by("new"),
      policies.checked(
        1,
        [policy.When(policy.Always, Proceed(Never, None))],
        policy.AnyoneHolding("nobody"),
      ),
    )
  let assert Ok(held) =
    memory.transaction(db, decisions.recommend(holding, _, proposal("100")))
  let assert occurrence.Held(..) = held.status
  // A held occurrence has released nothing, so a newer event supersedes it.
  let assert Ok(decisions.Supersession(
    expired: [superseded],
    not_begun: [],
    unreadable: [],
  )) =
    memory.transaction(db, decisions.happened(
      holding,
      _,
      "new",
      about: Subject("company", "x"),
    ))
  assert superseded.status == occurrence.Expired(vocabulary.Superseded("new"))
}
