//// Use case 9: a hermetic loop. Every input is recorded, the export is
//// labelled with what was known then, and replay needs no network.

import decisions
import decisions/learning.{type Archive, Archive, Read}
import decisions/memory
import decisions/model.{type Model, type Sources}
import decisions/occurrence
import decisions/vocabulary.{
  type Manifest, type Ref, Agent, Assessment, Correct, Manifest, ParentRun,
  Reason, Recommendation, Ref, RunAction, Trigger, Wrong,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import support/invoice.{type Invoice, Invoice}
import support/world.{type World}

const cnpj = "12.345.678/0001-90"

const standing = "REGULAR desde 2024"

/// The government portal. It counts every call, and can be taken down.
fn portal(w: World) -> fn(String, String) -> Result(String, String) {
  fn(name, argument) {
    world.commit(w.outside, world.bump(_, "portal.calls"))
    case name, argument, world.commit(w.outside, memory.get(_, "portal.down")) {
      _, _, Ok(_) -> Error("no network")
      "tax_standing", number, _ if number == cnpj -> Ok(standing)
      _, _, _ -> Error("the portal has no " <> name <> " for " <> argument)
    }
  }
}

/// Immutable platform data a context may reference.
fn platform(w: World) -> fn(Ref) -> Result(String, String) {
  fn(ref: Ref) {
    case ref.kind {
      "message" -> Ok("Emite a nota de 800 para a Clínica X.")
      _ -> world.commit(w.db, memory.evidence().get(_, ref))
    }
  }
}

fn context() -> Manifest {
  Manifest(refs: [Ref("message", "m9", "1")], renderer: "invoice-1")
}

/// The accounting agent, as a model: it checks the taker's tax standing
/// before it recommends. `number` is the tax id it looks up.
fn accounting(number: String) -> Model(Invoice) {
  model.new(fn(_context: Manifest, sources: Sources) {
    use found <- result.try(sources.read("tax_standing", number))
    let service_code = case string.starts_with(found.body, "REGULAR") {
      True -> "4.03"
      False -> "17.01"
    }
    Ok(
      Recommendation(
        reads: [],
        output: Invoice(taker: "clinica-x", cents: 80_000, service_code:),
        by: Agent(kind: "accounting", version: "3"),
        explanation: RunAction(run: "run-9", action: "a2"),
        signals: [],
      ),
    )
  })
}

fn archive(w: World) -> Archive {
  Archive(
    render: fn(context) {
      case context.renderer {
        "invoice-1" -> Ok("Recommend the invoice this customer asked for.")
        other -> Error("no renderer " <> other)
      }
    },
    reads: world.reads(w),
    content: fn(ref: Ref) {
      platform(w)(ref)
      |> result.map_error(model.ReadFailed(ref.kind, ref.id, _))
    },
  )
}

pub fn every_input_is_recorded_and_the_occurrence_replays_without_a_network_test() {
  let w = world.new()

  // Inside run-9 the agent reads the portal through a capturing source.
  let assert Ok(recommendation) =
    model.run(
      accounting(cnpj),
      context(),
      world.capturing(w, "run-9", platform(w), portal(w)),
    )
  let assert Ok(recommended) =
    world.in_tx(w, fn(tx) {
      decisions.recommend(
        invoice.desk(),
        tx,
        decisions.proposal(
          trigger: Trigger(kind: "run", id: "run-9"),
          about: world.clinica,
          context: context(),
          recommending: recommendation,
        )
          |> decisions.hanging_from(ParentRun("run-9")),
      )
    })

  // The response is immutable evidence, named on the recommendation and
  // retained in its run. The portal was called once.
  let assert [Read(name: "tax_standing", argument:, result: evidence)] =
    world.reads(w)(recommended.recommendation.explanation)
  assert argument == cnpj
  assert recommended.recommendation.reads == [evidence]
  assert world.commit(w.db, memory.evidence().get(_, evidence)) == Ok(standing)
  assert world.count(w.outside, "portal.calls") == 1

  // Felipe opens the card and expands the company's representations.
  let desk = invoice.desk()
  let assert Ok(card) =
    world.in_tx(w, fn(tx) {
      let assert Ok(card) = world.open(desk, tx, recommended.id, world.felipe)
      let assert Ok(captured) =
        model.capture(
          memory.evidence(),
          tx,
          source: "representations",
          request: "clinica-x",
          fetch: fn() { Ok("Ana representa a Clínica X (lastreada).") },
        )
      decisions.expand(
        desk,
        tx,
        card,
        read: "representations",
        result: captured.ref,
      )
    })
  assert list.map(occurrence.expansions(decisions.shown(card)), fn(e) { e.0 })
    == ["representations"]

  // He knows something the card does not show. A correction for missing
  // context is refused until he enters it.
  let correction =
    Correct(
      Invoice(taker: "clinica-x", cents: 80_000, service_code: "17.01"),
      Reason(decisions.missing_context, None),
    )
  assert world.in_tx(w, decisions.decide(desk, _, card, correction))
    == Error(decisions.NoteRequired)
  let assert Ok(released) =
    world.in_tx(w, fn(tx) {
      let assert Ok(card) =
        decisions.note(
          desk,
          tx,
          card,
          "A empresa mudou de regime tributário na semana passada.",
        )
      decisions.decide(desk, tx, card, correction)
    })
  let assert occurrence.Released(..) = released.status

  // Thirty days later the municipality's outcome is assessed.
  world.at(w, duration.hours(30 * 24))
  let assert Ok(assessed) =
    world.in_tx(w, decisions.assess(
      desk,
      _,
      occurrence: recommended.id,
      finding: Assessment(
        finding: Wrong(None),
        evidence: Ref("nfse", "rejection-1", "1"),
        source: "municipality",
        known_at: memory.now(w.db),
      ),
    ))

  // The export carries every input, labelled with what was known then.
  let day = fn(n) { timestamp.add(world.t0(), duration.hours(n * 24)) }
  let assert Ok(early) =
    learning.example(assessed, as_of: day(10), from: archive(w))
  let assert Ok(late) =
    learning.example(assessed, as_of: day(31), from: archive(w))
  assert early.context
    == [#(Ref("message", "m9", "1"), "Emite a nota de 800 para a Clínica X.")]
  assert list.map(early.reads, fn(read) { read.1 }) == [standing]
  assert early.expansions
    == [#("representations", "Ana representa a Clínica X (lastreada).")]
  assert occurrence.notes(early.known)
    == [#("felipe", "A empresa mudou de regime tributário na semana passada.")]
  let assert Some(#("felipe", Correct(..))) = occurrence.verdict(early.known)
  assert occurrence.assessments(early.known) == []
  assert list.length(occurrence.assessments(late.known)) == 1
  let assert Ok(document) = learning.example_to_json(late, invoice.codec())
  assert string.contains(document, "decision-example.v1")
  assert string.contains(document, standing)

  // Before the recommendation, there is nothing to export.
  assert learning.example(assessed, as_of: day(-1), from: archive(w))
    == Error(learning.NotYetRecommended)

  // Replay with no network: the portal now fails on any call.
  world.commit(w.outside, memory.put(_, "portal.down", "yes"))
  let same = fn(a: Invoice, b: Invoice) { a == b }
  let answered = learning.replay([late], accounting(cnpj), same:)
  assert answered.unanswered == []
  assert answered.tally.judged == 1

  // A candidate that makes a different read gets a reported miss, as a
  // value a caller can match.
  let missed = learning.replay([late], accounting("99.999.999/0001-99"), same:)
  assert missed.unanswered
    == [
      #(
        recommended.id,
        model.NotRecorded(read: "tax_standing", argument: "99.999.999/0001-99"),
      ),
    ]
  assert world.count(w.outside, "portal.calls") == 1
}
