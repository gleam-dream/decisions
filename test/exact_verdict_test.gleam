//// A client's verdict text is read strictly and within bounds, and an exact
//// number in an output stays exact from the client to the gated tool.

import decisions.{Gated}
import decisions/memory
import decisions/occurrence
import decisions/policy.{AnyoneHolding}
import decisions/view
import decisions/vocabulary.{
  Correct, Manifest, Recommendation, RunAnswer, Subject, Trigger, Validator,
}
import decisions/wire
import gleam/order
import gleam/result
import gleam/string
import json/blueprint/codec
import json/blueprint/number.{type Number}

const exact = "12345678901234567.89"

fn amount(text: String) -> Number {
  let assert Ok(parsed) = number.parse(text, number.default_limits())
  parsed
}

pub fn a_verdict_with_a_key_given_twice_is_refused_test() {
  let text =
    "{\"t\":\"reject\",\"reason\":{\"category\":\"x\"},\"t\":\"approve\"}"
  let assert Error(_) = view.verdict(text, wire.text())
}

pub fn a_verdict_larger_than_the_default_limit_is_refused_test() {
  let note = string.repeat("a", 1_100_000)
  let text =
    "{\"t\":\"reject\",\"reason\":{\"category\":\"x\",\"note\":\""
    <> note
    <> "\"}}"
  let assert Error(_) = view.verdict(text, wire.text())
}

pub fn a_corrected_exact_number_is_read_exactly_test() {
  let text =
    "{\"t\":\"correct\",\"output\":"
    <> exact
    <> ",\"reason\":{\"category\":\"x\"}}"
  let assert Ok(Correct(output:, ..)) =
    view.verdict(text, wire.codec(codec.number()))
  assert number.compare(output, amount(exact)) == order.Eq
}

/// The correction a client sends is recorded, read back and released with
/// the number it wrote.
pub fn an_exact_correction_reaches_the_tool_unchanged_test() {
  let db = memory.new()
  let assert Ok(always_ask) =
    policy.new(version: 1, rules: [], otherwise: AnyoneHolding("finance"))
  let desk =
    decisions.desk(
      decisions.point("exact.amount", wire.codec(codec.number()))
        |> decisions.allowing(vocabulary.ApproveRejectOrCorrect),
      drives: fn(_) {
        Gated(
          name: "pay",
          guard: fn(_, _) { Ok([]) },
          execute: fn(tx, released) {
            Ok(memory.put(
              tx,
              "paid",
              number.to_string(decisions.output(released)),
            ))
          },
        )
      },
      under: fn(_) { Ok(always_ask) },
      over: memory.port(),
    )
  let proposal =
    decisions.proposal(
      trigger: Trigger("invoice", "1"),
      about: Subject("person", "ana"),
      context: Manifest(refs: [], renderer: "r"),
      recommending: Recommendation(
        output: amount("10.5"),
        by: vocabulary.ModelCall("reader", "1"),
        explanation: RunAnswer("r"),
        signals: [],
        reads: [],
      ),
    )
  let assert Ok(made) =
    memory.transaction(db, decisions.recommend(desk, _, proposal))
  let assert Ok(verdict) =
    view.verdict(
      "{\"t\":\"correct\",\"output\":"
        <> exact
        <> ",\"reason\":{\"category\":\"typo\"}}",
      wire.codec(codec.number()),
    )
  let assert Ok(decided) =
    memory.transaction(db, fn(tx) {
      use card <- result.try(
        decisions.open(
          desk,
          tx,
          made.id,
          by: Validator("bia", ["finance"]),
          latest: fn(ref) { ref.revision },
        ),
      )
      decisions.decide(desk, tx, card, verdict)
    })
  let assert occurrence.Released(final:, ..) = decided.status
  assert number.compare(final, amount(exact)) == order.Eq
  let assert Ok(read_back) =
    memory.transaction(db, decisions.read(desk, _, occurrence: made.id))
  let assert occurrence.Released(final:, ..) = read_back.status
  assert number.compare(final, amount(exact)) == order.Eq
  assert memory.get(db, "paid") == Ok(number.to_string(amount(exact)))
}

/// A recommendation may carry an exact number beyond a float's precision
/// or range.
pub fn an_exact_recommendation_is_stored_exactly_test() {
  stored_exactly(exact)
  stored_exactly("1e400")
}

fn stored_exactly(exact: String) -> Nil {
  let db = memory.new()
  let assert Ok(always_ask) =
    policy.new(version: 1, rules: [], otherwise: AnyoneHolding("finance"))
  let desk =
    decisions.desk(
      decisions.point("exact.recommended", wire.codec(codec.number())),
      drives: fn(_) {
        Gated(name: "pay", guard: fn(_, _) { Ok([]) }, execute: fn(_, _) {
          Ok(Nil)
        })
      },
      under: fn(_) { Ok(always_ask) },
      over: memory.port(),
    )
  let proposal =
    decisions.proposal(
      trigger: Trigger("invoice", "2"),
      about: Subject("person", "ana"),
      context: Manifest(refs: [], renderer: "r"),
      recommending: Recommendation(
        output: amount(exact),
        by: vocabulary.ModelCall("reader", "1"),
        explanation: RunAnswer("r"),
        signals: [],
        reads: [],
      ),
    )
  let assert Ok(made) =
    memory.transaction(db, decisions.recommend(desk, _, proposal))
  let assert Ok(back) =
    memory.transaction(db, decisions.read(desk, _, occurrence: made.id))
  assert number.compare(back.recommendation.output, amount(exact)) == order.Eq
  Nil
}

pub fn an_output_from_a_client_is_parsed_strictly_test() {
  let assert Error(_) = wire.parse(wire.text(), "{\"a\":1,\"a\":2}")
  let assert Ok(parsed) = wire.parse(wire.codec(codec.number()), exact)
  assert number.compare(parsed, amount(exact)) == order.Eq
}
