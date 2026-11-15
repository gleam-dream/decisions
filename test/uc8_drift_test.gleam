//// Use case 8: drift while waiting, a restart, the guard checked again.

import decisions
import decisions/memory.{type Memory}
import decisions/occurrence
import decisions/store.{Notice}
import decisions/vocabulary.{type Manifest, type Ref, Approve, Manifest, Ref}
import gleam/result
import gleam/time/duration
import support/reply
import support/world

/// The context builder of `reply.draft`: it reads the current world.
fn build_context(db: Memory, message: String) -> Manifest {
  Manifest(
    refs: [
      Ref("profile", "ana", current_revision(db, "profile", "ana")),
      Ref("message", message, "1"),
    ],
    renderer: "reply-1",
  )
}

fn current_revision(db: Memory, kind: String, id: String) -> String {
  memory.get(db, kind <> ":" <> id) |> result.unwrap("1")
}

fn latest(db: Memory) -> fn(Ref) -> String {
  fn(ref: Ref) {
    memory.get(db, ref.kind <> ":" <> ref.id) |> result.unwrap(ref.revision)
  }
}

pub fn a_stale_draft_is_refused_and_the_follow_on_reads_the_current_world_test() {
  let w = world.new()
  let drafted = reply.draft(w, "m1", "run-1", build_context(w.db, "m1"))
  assert drafted.context.refs
    == [Ref("profile", "ana", "1"), Ref("message", "m1", "1")]

  // Overnight the service restarts. Only the database's text survives.
  let w = world.restart(w)
  assert memory.queue(w.db, "operators") == [drafted.id]
  let assert occurrence.Awaiting(_) =
    world.read(w, reply.desk(), drafted.id).status

  // Ana's profile is revised.
  memory.put(w.db, "profile:ana", "2")

  // Two seconds before the window closes, Felipe opens the card.
  world.at(w, duration.seconds(24 * 3600 - 2))
  let assert Ok(held) =
    world.in_tx(w, fn(tx) {
      let assert Ok(card) =
        decisions.open(
          reply.desk(),
          tx,
          occurrence: drafted.id,
          by: world.felipe,
          latest: latest(tx),
        )
      // The card marks the input that changed since the model read it.
      assert occurrence.drift(decisions.shown(card))
        == [Ref("profile", "ana", "2")]
      decisions.decide(reply.desk(), tx, card, Approve)
    })
  let assert occurrence.Held(..) = held.status

  // The hold ends three seconds after the window closed.
  world.at(w, duration.seconds(24 * 3600 + 3))
  assert world.deliver_due(w, [decisions.waker(reply.desk())]) == 1
  let refused = world.read(w, reply.desk(), drafted.id)
  assert refused.status == occurrence.Refused("the service window is closed")
  assert reply.outbox(w) == []

  // Settling admitted one notice. The run that follows builds its context
  // from the current world, never from the waiting run's view.
  assert memory.notices(w.db) == [Notice("reply.draft", drafted.id)]
  let follow_on = build_context(w.db, "m1")
  assert follow_on.refs
    == [Ref("profile", "ana", "2"), Ref("message", "m1", "1")]
}
