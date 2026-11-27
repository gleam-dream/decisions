//// Use case 19 and condition E2: a validator in another system. The card
//// leaves as JSON; the verdict returns as JSON, by a callback that may
//// arrive twice or late.

import decisions.{type Desk}
import decisions/memory.{type Tx}
import decisions/model
import decisions/occurrence
import decisions/policy.{AnyoneHolding}
import decisions/view
import decisions/vocabulary.{DeadlinePassed, Validator}
import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/time/duration
import support/payout.{Payout}
import support/policies
import support/world.{type World}

const risk_service = Validator(subject: "risk-service", holds: ["partner-risk"])

fn desk() -> Desk(payout.Payout, Tx) {
  payout.desk_of(
    payout.point() |> decisions.valid_for(duration.hours(1)),
    policies.checked(
      version: 1,
      rules: [],
      otherwise: AnyoneHolding("partner-risk"),
    ),
  )
}

/// Our side, outbound: open the card for the partner and send the document.
fn send_card(w: World, id: String) -> String {
  let assert Ok(text) =
    world.in_tx(w, fn(tx) {
      use card <- result.try(world.open(desk(), tx, id, risk_service))
      let assert Ok(document) =
        view.of(card, content: fn(_) {
          Error(model.Declined("this card has no inputs"))
        })
        |> view.to_json(payout.codec())
      Ok(json.to_string(document))
    })
  text
}

/// The partner's side. It has none of our code: it reads the document as
/// JSON and answers in JSON.
fn partner_decides(document: String) -> #(decisions.Ticket, String) {
  let assert Ok(#(ticket, cents, verdicts, schema_type)) =
    json.parse(document, {
      use ticket <- decode.then(view.ticket_decoder())
      use cents <- decode.subfield(
        ["recommendation", "output", "cents"],
        decode.int,
      )
      use verdicts <- decode.field("verdicts", decode.list(decode.string))
      use schema_type <- decode.subfield(
        ["output_schema", "type"],
        decode.string,
      )
      decode.success(#(ticket, cents, verdicts, schema_type))
    })
  assert verdicts == ["approve", "reject", "correct"]
  // The output's schema is on the card, so the partner could build a
  // correction form without our code.
  assert schema_type == "object"
  let answer = case cents <= 100_000 {
    True -> "{\"t\":\"approve\"}"
    False ->
      "{\"t\":\"reject\",\"reason\":{\"category\":\"over_limit\",\"note\":null}}"
  }
  #(ticket, answer)
}

/// Our side, inbound: the callback. The ticket names the showing the
/// verdict was given on, and the body decodes only with this point's codec.
fn callback(
  w: World,
  ticket: decisions.Ticket,
  body: String,
) -> Result(String, String) {
  world.in_tx(w, fn(tx) {
    use verdict <- result.try(
      view.verdict(body, payout.codec())
      |> result.replace_error("the verdict does not decode for this point"),
    )
    use card <- result.try(
      decisions.resume(desk(), tx, ticket, by: risk_service)
      |> result.map_error(decisions.describe),
    )
    decisions.decide(desk(), tx, card, verdict)
    |> result.map(fn(decided) { occurrence.status_name(decided.status) })
    |> result.map_error(decisions.describe)
  })
}

pub fn a_callback_that_arrives_twice_decides_once_test() {
  let w = world.new()
  let assert Ok(waiting) =
    world.in_tx(w, payout.request(
      desk(),
      _,
      key: "payout-30",
      by: "felipe",
      payout: Payout("clinica-x", 50_000),
    ))
  let #(ticket, answer) = partner_decides(send_card(w, waiting.id))
  assert ticket.occurrence == "payout-30"

  assert callback(w, ticket, answer) == Ok("released")
  // The same callback again: the verdict stood, and nothing ran twice.
  assert callback(w, ticket, answer) == Ok("released")
  assert payout.payouts(w) == ["clinica-x:50000"]

  // A verdict whose correction is not a payout does not decode.
  assert callback(
      w,
      ticket,
      "{\"t\":\"correct\",\"output\":{\"fee\":\"f\"},\"reason\":{\"category\":\"x\",\"note\":null}}",
    )
    == Error("the verdict does not decode for this point")

  // A ticket that names no showing to this validator is refused.
  assert callback(w, decisions.Ticket(..ticket, seen: ticket.seen + 7), answer)
    == Error("this card was never shown to this validator")
}

pub fn a_callback_after_expiry_is_refused_with_the_reason_test() {
  let w = world.new()
  let assert Ok(waiting) =
    world.in_tx(w, payout.request(
      desk(),
      _,
      key: "payout-31",
      by: "felipe",
      payout: Payout("clinica-x", 50_000),
    ))
  let #(ticket, answer) = partner_decides(send_card(w, waiting.id))

  world.at(w, duration.hours(1))
  assert world.deliver_due(w, [decisions.waker(desk())]) == 1
  let expired = world.read(w, desk(), ticket.occurrence)
  assert expired.status == occurrence.Expired(DeadlinePassed)

  assert callback(w, ticket, answer)
    == Error("the occurrence is not waiting for a verdict")
  assert payout.payouts(w) == []
}
