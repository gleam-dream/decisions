//// A card opened in one request and decided in another. A page keeps the
//// card's `Ticket` and nothing else; the verdict names the showing it was
//// given on.

// snips-start: ticket
import decisions.{type Ticket}
import decisions/memory.{type Memory}
import decisions/occurrence.{type Occurrence}
import decisions/vocabulary.{type Validator, Approve}
import decisions_usage/clinic.{type Refund}
import decisions_usage/first_point
import gleam/result

/// First request: show the card, and give the page its ticket.
pub fn show(
  store: Memory,
  id: String,
  to validator: Validator,
) -> Result(Ticket, decisions.Refusal) {
  memory.transaction(store, fn(tx) {
    decisions.open(
      first_point.desk(),
      tx,
      occurrence: id,
      by: validator,
      latest: fn(ref) { ref.revision },
    )
    |> result.map(decisions.ticket)
  })
}

/// A later request: the page sends the ticket back with the verdict.
/// Resuming records nothing; a ticket that names no showing to this
/// validator is refused.
pub fn approve(
  store: Memory,
  ticket: Ticket,
  by validator: Validator,
) -> Result(Occurrence(Refund), decisions.Refusal) {
  memory.transaction(store, fn(tx) {
    use card <- result.try(decisions.resume(
      first_point.desk(),
      tx,
      ticket,
      by: validator,
    ))
    decisions.decide(first_point.desk(), tx, card, Approve)
  })
}

// snips-end: ticket

/// The whole topic: Felipe cannot use Bia's ticket; Bia's verdict names
/// the showing.
pub fn run() -> #(
  Result(Occurrence(Refund), decisions.Refusal),
  List(#(String, Int)),
  Int,
) {
  let store = memory.new()
  let assert Ok(waiting) = first_point.recommend(store)
  let assert Ok(ticket) = show(store, waiting.id, to: clinic.bia)
  let felipe = approve(store, ticket, by: clinic.felipe)
  let assert Ok(decided) = approve(store, ticket, by: clinic.bia)
  #(felipe, occurrence.seen(decided), ticket.seen)
}
