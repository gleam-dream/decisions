//// Condition E: the same context, to a person or to another system.

import decisions.{type Desk, type Point, Gated}
import decisions/entry
import decisions/learning.{Archive}
import decisions/memory.{type Memory}
import decisions/model.{
  type Failure, type Model, type Reader, type Sources, NotRecorded,
}
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Ask, Policy}
import decisions/view.{Item}
import decisions/vocabulary.{
  type Manifest, type Ref, ApproveRejectOrCorrect, Correct, Manifest, ModelCall,
  Reason, Receipt, Recommendation, Ref, Trigger,
}
import decisions/wire
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import support/world.{type World}

/// What the accountant needs to pick a service code.
type Brief {
  Brief(request: String, standing: String)
}

/// F3. The one function that reads the context. The model, the card, the
/// export and a replay all get their `Brief` from it.
fn reader() -> Reader(Brief) {
  fn(manifest: Manifest, sources: Sources) {
    case manifest.refs {
      [message, ..] -> {
        use request <- result.try(sources.resolve(message))
        use standing <- result.try(sources.read("tax_standing", "clinica-x"))
        Ok(Brief(request:, standing: standing.body))
      }
      [] -> Error(model.Declined("the context names no message"))
    }
  }
}

fn accountant() -> Model(String) {
  model.over(reader(), fn(brief: Brief) {
    Ok(
      Recommendation(
        output: case string.starts_with(brief.standing, "REGULAR") {
          True -> "4.03"
          False -> "17.01"
        },
        by: ModelCall("accounting", "3"),
        explanation: Receipt(Ref("llm_call", "call-1", "1")),
        signals: [],
        reads: [],
      ),
    )
  })
}

fn point() -> Point(String) {
  decisions.point("billing.service_code", wire.text())
  |> decisions.allowing(ApproveRejectOrCorrect)
}

fn desk() -> Desk(String, Memory) {
  decisions.desk(
    point(),
    drives: fn(_) {
      Gated(name: "set_code", guard: fn(_, _) { Ok([]) }, execute: fn(tx, r) {
        Ok(world.push(tx, "codes", decisions.output(r)))
      })
    },
    under: fn(_) {
      Ok(Policy(version: 1, rules: [], otherwise: Ask(AnyoneHolding("finance"))))
    },
    over: memory.port(),
  )
}

/// A message is immutable under its revision.
fn message(w: World, ref: Ref) -> Result(String, String) {
  memory.get(w.outside, "message:" <> ref.id <> "@" <> ref.revision)
  |> result.replace_error("no such message revision")
}

fn tax_api(w: World) -> fn(String, String) -> Result(String, String) {
  fn(_name, number) {
    memory.get(w.outside, "tax:" <> number)
    |> result.replace_error("the tax API did not answer")
  }
}

/// Everything recorded, by reference: the content as it was read.
fn content(w: World) -> fn(Ref) -> Result(String, Failure) {
  fn(ref: Ref) {
    case ref.kind {
      "message" -> message(w, ref)
      _ -> memory.evidence().get(w.db, ref)
    }
    |> result.map_error(model.ReadFailed(ref.kind, ref.id, _))
  }
}

fn recommended(w: World) -> occurrence.Occurrence(String) {
  memory.put(w.outside, "message:m9@1", "Emite a nota de 800.")
  memory.put(w.outside, "tax:clinica-x", "REGULAR since 2019")
  let context = Manifest(refs: [Ref("message", "m9", "1")], renderer: "code-1")
  let assert Ok(recommendation) =
    model.run(
      accountant(),
      context,
      world.capturing(w, "run-e", message(w, _), tax_api(w)),
    )
  // The read the model made is on its recommendation, observed by `run`.
  let assert [Ref(kind: "tax_standing", id: "clinica-x", ..)] =
    recommendation.reads
  let assert Ok(waiting) =
    world.in_tx(w, decisions.recommend_once(
      desk(),
      _,
      key: "code-1",
      proposal: decisions.proposal(
        trigger: Trigger(kind: "message", id: "m9"),
        about: world.clinica,
        context:,
        recommending: recommendation,
      ),
    ))
  waiting
}

/// The world moves on after the model has read it.
fn world_changes(w: World) -> Nil {
  memory.put(w.outside, "message:m9@2", "Emite a nota de 900.")
  memory.put(w.outside, "tax:clinica-x", "IRREGULAR since last week")
}

/// The latest revision of each input: the message has a second revision,
/// and the tax standing reads differently now.
fn latest(ref: Ref) -> String {
  case ref.kind {
    "message" -> "2"
    "tax_standing" -> model.digest("IRREGULAR since last week")
    _ -> ref.revision
  }
}

/// E1 and F3.
pub fn the_card_shows_what_the_model_read_after_the_world_has_changed_test() {
  let w = world.new()
  let waiting = recommended(w)
  world_changes(w)

  let assert Ok(card) =
    world.in_tx(w, decisions.open(
      desk(),
      _,
      occurrence: waiting.id,
      by: world.bia,
      latest:,
    ))

  // The typed context is the value the model's reader returned, built by
  // the same function from the record.
  assert view.context(
      decisions.shown(card),
      with: reader(),
      content: content(w),
    )
    == Ok(Brief(request: "Emite a nota de 800.", standing: "REGULAR since 2019"))

  // The document shows each input as read, and flags each one that
  // changed: the context reference and the model's read.
  let shown = view.of(card, content: content(w))
  let assert [
    Item(
      ref: Ref("message", "m9", "1"),
      content: Ok("Emite a nota de 800."),
      now: Some(Ref("message", "m9", "2")),
    ),
  ] = shown.pushed
  let assert [
    Item(
      ref: Ref(kind: "tax_standing", ..),
      content: Ok("REGULAR since 2019"),
      now: Some(Ref(kind: "tax_standing", ..)),
    ),
  ] = shown.pulled
  assert content(w)(Ref("message", "m9", "2")) == Ok("Emite a nota de 900.")

  // A card cannot show more than the model had. A reader that asks for a
  // read the model never made is told so.
  let greedy = fn(manifest: Manifest, sources: Sources) {
    use brief <- result.try(reader()(manifest, sources))
    use score <- result.try(sources.read("credit_score", "clinica-x"))
    Ok(#(brief, score.body))
  }
  assert view.context(decisions.shown(card), with: greedy, content: content(w))
    == Error(NotRecorded(read: "credit_score", argument: "clinica-x"))
}

/// E2. The card as a document, read by a client that has none of the
/// point's code.
pub fn the_card_crosses_a_boundary_as_json_test() {
  let w = world.new()
  let waiting = recommended(w)
  world_changes(w)
  let assert Ok(card) =
    world.in_tx(w, decisions.open(
      desk(),
      _,
      occurrence: waiting.id,
      by: world.bia,
      latest:,
    ))
  let assert Ok(document) =
    view.of(card, content: content(w)) |> view.to_json(wire.text())
  let document = json.to_string(document)

  let assert Ok(read) =
    json.parse(document, {
      use format <- decode.field("format", decode.string)
      use waiting_for <- decode.field("waiting_for", decode.list(decode.string))
      use recommended <- decode.subfield(
        ["recommendation", "output"],
        decode.string,
      )
      use verdicts <- decode.field("verdicts", decode.list(decode.string))
      use inputs <- decode.field(
        "context",
        decode.list({
          use text <- decode.field("content", decode.string)
          use changed <- decode.field(
            "changed_to",
            decode.optional(decode.at(["revision"], decode.string)),
          )
          decode.success(#(text, changed))
        }),
      )
      use model_read <- decode.field(
        "model_read",
        decode.list(decode.at(["content"], decode.string)),
      )
      use schema <- decode.subfield(["output_schema", "type"], decode.string)
      decode.success(#(
        format,
        waiting_for,
        recommended,
        verdicts,
        inputs,
        model_read,
        schema,
      ))
    })
  assert read
    == #(
      "decision-card.v1",
      ["finance"],
      "4.03",
      ["approve", "reject", "correct"],
      [#("Emite a nota de 800.", Some("2"))],
      ["REGULAR since 2019"],
      "string",
    )
}

/// E3 and E4. What the validator did is on the record, and so is the view
/// her verdict was given on.
pub fn what_the_validator_opened_and_saw_is_on_the_record_test() {
  let w = world.new()
  let waiting = recommended(w)
  world_changes(w)

  // First request: Bia opens the card. It shows the drift.
  let assert Ok(card) =
    world.in_tx(w, decisions.open(
      desk(),
      _,
      occurrence: waiting.id,
      by: world.bia,
      latest:,
    ))
  let ticket = decisions.ticket(card)

  // Second request: she looks the tax standing up again. The answer is
  // captured as evidence before she sees it, and then she adds a note.
  world.at(w, duration.minutes(3))
  let assert Ok(_) =
    world.in_tx(w, fn(tx) {
      let assert Ok(card) = decisions.resume(desk(), tx, ticket, by: world.bia)
      let assert Ok(looked) =
        model.capture(
          memory.evidence(),
          tx,
          source: "tax_standing",
          request: "clinica-x",
          fetch: fn() { tax_api(w)("tax_standing", "clinica-x") },
        )
      assert looked.body == "IRREGULAR since last week"
      use card <- result.try(decisions.expand(
        desk(),
        tx,
        card,
        read: "tax_standing",
        result: looked.ref,
      ))
      decisions.note(desk(), tx, card, "the standing changed last week")
    })

  // Third request: the verdict, on the ticket of the first.
  world.at(w, duration.minutes(5))
  let assert Ok(decided) =
    world.in_tx(w, fn(tx) {
      let assert Ok(card) = decisions.resume(desk(), tx, ticket, by: world.bia)
      decisions.decide(
        desk(),
        tx,
        card,
        Correct("17.01", Reason(decisions.missing_context, None)),
      )
    })
  assert world.all(w.db, "codes") == ["17.01"]

  // E4. The verdict names the showing it was given on, and that showing
  // records which inputs had already changed.
  assert occurrence.seen(decided) == [#("bia", ticket.seen)]
  let assert Ok(showing) =
    list.find(decided.entries, fn(entry) { entry.seq == ticket.seen })
  let assert entry.Opened(by: "bia", drifted: [Ref("message", "m9", "2"), _]) =
    showing.event
  // Another validator cannot use her ticket.
  assert world.in_tx(w, fn(tx) {
      decisions.resume(desk(), tx, ticket, by: world.felipe)
      |> result.replace(Nil)
    })
    == Error(decisions.NeverShown)

  // E3. Replay the same model twice: on what the model had, and on what
  // Bia had. Only the second agrees with her.
  let archive =
    Archive(
      render: fn(_) { Ok("code") },
      reads: fn(_) { [] },
      content: content(w),
    )
  let far = timestamp.add(world.t0(), duration.hours(1))
  let assert Ok(example) = learning.example(decided, as_of: far, from: archive)
  let same = fn(a: String, b: String) { a == b }
  let as_the_model_saw = learning.replay([example], accountant(), same:)
  assert #(as_the_model_saw.tally.agreed, as_the_model_saw.tally.judged)
    == #(0, 1)
  let as_bia_saw =
    learning.replay([learning.widened(example)], accountant(), same:)
  assert #(as_bia_saw.tally.agreed, as_bia_saw.tally.judged) == #(1, 1)
  // Every entry has its kind and its time.
  assert list.map(decided.entries, fn(e) { entry.kind(e.event) })
    == [
      "recommended", "policy_applied", "opened", "expanded", "noted", "decided",
      "released",
    ]
}
