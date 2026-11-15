//// Replaying recorded decisions against a new model. Each recorded
//// occurrence is exported as a self-contained example; a candidate runs on
//// the examples alone, with no network and no gated tool, and is scored
//// against what people decided.

// snips-start: replay
import decisions
import decisions/learning.{type Replay, Archive}
import decisions/memory.{type Memory}
import decisions/model.{type Model}
import decisions/occurrence.{type Occurrence}
import decisions/vocabulary.{
  type Manifest, type Ref, Approve, Correct, Manifest, Reason, Recommendation,
  Ref, RuleFired, Rules, Trigger,
}
import decisions_usage/clinic.{type Refund, Refund}
import decisions_usage/first_point
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/time/timestamp

/// A rule that refunds the whole fee whose statement line it reads.
pub fn whole_fee(version: String) -> Model(Refund) {
  model.new(fn(context: Manifest, sources: model.Sources) {
    use line <- result.try(
      list.first(context.refs)
      |> result.replace_error(model.Declined("no statement line")),
    )
    use text <- result.try(sources.resolve(line))
    let cents = int.parse(text) |> result.unwrap(0)
    let cents = case version {
      // Version 2 refunds half of anything above R$100.
      "2" if cents > 10_000 -> cents / 2
      _ -> cents
    }
    Ok(
      Recommendation(
        output: Refund(fee: line.id, cents:),
        by: Rules(name: "whole-fee", version:),
        explanation: RuleFired("refund-the-line"),
        signals: [],
        reads: [],
      ),
    )
  })
}

/// Export what was decided, then score a candidate on it.
pub fn score(
  recorded: List(Occurrence(Refund)),
  candidate: Model(Refund),
  lines: model.Resolver,
) -> Result(Replay, learning.ExportError) {
  let archive =
    Archive(
      render: fn(_) { Ok("refund-1") },
      reads: fn(_) { [] },
      content: lines,
    )
  let now = timestamp.from_unix_seconds(4_000_000_000)
  use examples <- result.map(
    list.try_map(recorded, learning.example(_, as_of: now, from: archive)),
  )
  learning.replay(examples, candidate, same: fn(a, b) { a == b })
}

// snips-end: replay

/// The whole topic: Bia approved two small refunds and halved a large one.
/// Version 1 agrees on two of three; version 2 on all three.
pub fn run() -> #(Replay, Replay) {
  let store = memory.new()
  let line = fn(fee: String, cents: Int) {
    memory.put(store, "line:" <> fee, int.to_string(cents))
  }
  let lines = fn(ref: Ref) {
    memory.get(store, "line:" <> ref.id)
    |> result.replace_error(model.NotRecorded(ref.kind, ref.id))
  }
  line("fee-a", 4000)
  line("fee-b", 7000)
  line("fee-c", 30_000)
  let decide = fn(fee: String, halve: Bool) -> Occurrence(Refund) {
    let context = Manifest(refs: [Ref("line", fee, "1")], renderer: "refund-1")
    let sources =
      model.Sources(resolve: fn(ref) { lines(ref) }, read: fn(name, argument) {
        Error(model.NotRecorded(name, argument))
      })
    let assert Ok(recommendation) = model.run(whole_fee("1"), context, sources)
    let assert Ok(decided) =
      memory.transaction(store, fn(tx: Memory) {
        use waiting <- result.try(decisions.recommend(
          first_point.desk(),
          tx,
          decisions.proposal(
            trigger: Trigger("line", fee),
            about: clinic.clinica_x,
            context:,
            recommending: recommendation,
          ),
        ))
        use card <- result.try(
          decisions.open(
            first_point.desk(),
            tx,
            occurrence: waiting.id,
            by: clinic.bia,
            latest: fn(r) { r.revision },
          ),
        )
        decisions.decide(first_point.desk(), tx, card, case halve {
          True ->
            Correct(
              Refund(fee:, cents: recommendation.output.cents / 2),
              Reason("too_much", None),
            )
          False -> Approve
        })
      })
    decided
  }
  let recorded = [
    decide("fee-a", False),
    decide("fee-b", False),
    decide("fee-c", True),
  ]
  let assert Ok(first) = score(recorded, whole_fee("1"), lines)
  let assert Ok(second) = score(recorded, whole_fee("2"), lines)
  #(first, second)
}
