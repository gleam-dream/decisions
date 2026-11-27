//// Test support: the `reply.draft` decision point and its gated tool
//// `send_message`.

import decisions.{type Desk, type Gated, type Point, Gated}
import decisions/memory.{type Memory}
import decisions/occurrence.{type Occurrence}
import decisions/policy.{AnyoneHolding, Never, OwnAct, Proceed, When}
import decisions/vocabulary.{
  type Manifest, Agent, ApproveRejectOrCorrect, ParentRun, Recommendation,
  RunAnswer, Trigger,
}
import decisions/wire
import gleam/int
import gleam/option.{None}
import gleam/order
import gleam/result
import gleam/time/duration
import gleam/time/timestamp
import support/policies
import support/world.{type World}

pub const draft_text = "O DAS vence dia 20."

pub fn point() -> Point(String) {
  decisions.point("reply.draft", wire.text())
  |> decisions.allowing(ApproveRejectOrCorrect)
  |> decisions.with_hold(duration.seconds(5))
  |> decisions.superseded_by("customer.message")
}

/// The guard is the service window: 24 hours from the customer's latest
/// message. It reads the subject and the world, and nothing of the text.
pub fn send_message() -> Gated(String, Memory) {
  Gated(
    name: "send_message",
    guard: fn(tx, subject) {
      let latest =
        memory.get(tx, "latest_inbound:" <> subject.id)
        |> result.try(int.parse)
        |> result.unwrap(0)
      let closes =
        timestamp.add(wire.from_milliseconds(latest), duration.hours(24))
      case timestamp.compare(memory.now(tx), closes) {
        order.Lt -> Ok([])
        _ -> Error(vocabulary.Refuse("the service window is closed"))
      }
    },
    execute: fn(tx, released) {
      Ok(world.push(tx, "outbox", decisions.output(released)))
    },
  )
}

/// The first policy of every decision point: a person's own act proceeds,
/// anything else asks a person.
pub fn desk() -> Desk(String, Memory) {
  decisions.desk(
    point(),
    drives: fn(_) { send_message() },
    under: fn(_) {
      Ok(policies.checked(
        version: 1,
        rules: [When(OwnAct, Proceed(Never, None))],
        otherwise: AnyoneHolding("operators"),
      ))
    },
    over: memory.port(),
  )
}

/// Ana's message arrives and the reply agent's run drafts an answer.
pub fn draft(
  world: World,
  message: String,
  run: String,
  context: Manifest,
) -> Occurrence(String) {
  let assert Ok(drafted) =
    world.in_tx(world, fn(tx) {
      memory.put(
        tx,
        "latest_inbound:ana",
        int.to_string(wire.milliseconds(memory.now(tx))),
      )
      decisions.recommend(
        desk(),
        tx,
        decisions.proposal(
          trigger: Trigger(kind: "message", id: message),
          about: world.ana,
          context:,
          recommending: Recommendation(
            reads: [],
            output: draft_text,
            by: Agent(kind: "reply", version: "7"),
            explanation: RunAnswer(run),
            signals: [],
          ),
        )
          |> decisions.hanging_from(ParentRun(run)),
      )
    })
  drafted
}

pub fn outbox(world: World) -> List(String) {
  world.all(world.db, "outbox")
}
