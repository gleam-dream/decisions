//// A deadline of the occurrence's own. A reply to a customer may be sent
//// only until 24 hours after the customer's message, so each draft's
//// deadline is an instant the application knows when the message arrives.
//// The message's transaction expects the draft with that deadline; the
//// draft recommended 90 seconds later keeps it, and if nobody has decided
//// it when the window closes, it expires.

// Used by `run` below, outside the README region.
import gleam/option.{Some}
import gleam/result

// snips-start: deadline-per-occurrence
import decisions
import decisions/memory.{type Memory}
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Ask, Policy}
import decisions/vocabulary.{
  Agent, Manifest, Recommendation, RuleFired, Subject, Trigger,
}
import decisions/wire
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}

pub fn desk() -> decisions.Desk(String, Memory) {
  decisions.desk(
    // No validity of its own: each draft carries its window.
    decisions.point("reply.draft", wire.text()),
    drives: fn(_) {
      decisions.Gated(
        name: "send",
        guard: fn(_, _) { Ok([]) },
        execute: fn(_, _) { Ok(Nil) },
      )
    },
    under: fn(_) { Ok(Policy(1, [], Ask(AnyoneHolding("support")))) },
    over: memory.port(),
  )
}

/// The transaction that stores the customer's message expects the draft,
/// due when the service window closes.
pub fn receive(
  store: Memory,
  message: String,
  written_at: Timestamp,
) -> Result(Nil, decisions.Refusal) {
  memory.transaction(store, decisions.expect_until(
    desk(),
    _,
    key: "reply:" <> message,
    trigger: Trigger(kind: "message", id: message),
    about: Subject("party", "ana"),
    valid_until: timestamp.add(written_at, duration.hours(24)),
  ))
}

/// The model's draft keeps the deadline the expectation carries.
pub fn draft(
  store: Memory,
  message: String,
  text: String,
) -> Result(occurrence.Occurrence(String), decisions.Refusal) {
  memory.transaction(store, decisions.recommend_once(
    desk(),
    _,
    key: "reply:" <> message,
    proposal: decisions.proposal(
      trigger: Trigger(kind: "message", id: message),
      about: Subject("party", "ana"),
      context: Manifest(refs: [], renderer: "reply-1"),
      recommending: Recommendation(
        output: text,
        by: Agent(kind: "reply", version: "1"),
        explanation: RuleFired("draft"),
        signals: [],
        reads: [],
      ),
    ),
  ))
}

// snips-end: deadline-per-occurrence

/// The whole topic: the message at Monday 09:00, the draft at 09:01:30,
/// nobody reviews it, and the wake-up at Tuesday 09:00 expires it. Returns
/// the draft's deadline and its status after the wake-up.
pub fn run() -> #(Bool, String) {
  let store = memory.new()
  let monday = wire.from_milliseconds(1_800_000_000_000)
  memory.set_clock(store, monday)
  let assert Ok(Nil) = receive(store, "m-1", monday)
  memory.advance(store, duration.seconds(90))
  let assert Ok(drafted) = draft(store, "m-1", "Olá Ana, segue o boleto.")
  memory.set_clock(store, timestamp.add(monday, duration.hours(24)))
  let woken =
    memory.transaction(store, decisions.wake(desk(), _, occurrence: "reply:m-1"))
    |> result.map(fn(woken) {
      case woken {
        decisions.Woken(known) -> occurrence.status_name(known.status)
        _ -> "nothing"
      }
    })
  let closes = timestamp.add(monday, duration.hours(24))
  #(drafted.valid_until == Some(closes), result.unwrap(woken, "refused"))
}
