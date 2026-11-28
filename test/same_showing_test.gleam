//// `decisions.showing` answers what `open` would do for a validator:
//// return their latest showing again, or record a new one.

import decisions
import decisions/memory.{type Tx}
import decisions/vocabulary.{type Manifest, type Ref, Manifest, Ref}
import gleam/option.{None, Some}
import gleam/result
import support/reply
import support/world

fn context(message: String) -> Manifest {
  Manifest(refs: [Ref("profile", "ana", "1")], renderer: "reply-" <> message)
}

fn latest(tx: Tx) -> fn(Ref) -> String {
  fn(ref: Ref) {
    memory.get(tx, ref.kind <> ":" <> ref.id)
    |> result.unwrap(ref.revision)
  }
}

fn open(w: world.World, id: String, validator) {
  world.in_tx(w, fn(tx) {
    decisions.open(
      reply.desk(),
      tx,
      occurrence: id,
      by: validator,
      latest: latest(tx),
    )
  })
}

fn showing(w: world.World, id: String, validator) {
  let current = world.read(w, reply.desk(), id)
  let assert Ok(answer) =
    world.in_tx(w, fn(tx) {
      Ok(decisions.showing(current, by: validator, latest: latest(tx)))
    })
  answer
}

/// Before any showing there is none to return; after one, it is the
/// ticket `open` returns again, and only to the validator it was shown to.
pub fn the_showing_is_what_open_returns_again_test() {
  let w = world.new()
  let drafted = reply.draft(w, "m1", "run-1", context("m1"))
  assert showing(w, drafted.id, world.felipe) == None
  let assert Ok(card) = open(w, drafted.id, world.felipe)
  assert showing(w, drafted.id, world.felipe) == Some(decisions.ticket(card))
  assert showing(w, drafted.id, world.bia) == None
  let assert Ok(again) = open(w, drafted.id, world.felipe)
  assert decisions.ticket(again) == decisions.ticket(card)
  // Another validator's showing is not an entry that ends this one.
  let assert Ok(_) = open(w, drafted.id, world.bia)
  assert showing(w, drafted.id, world.felipe) == Some(decisions.ticket(card))
}

/// An input that drifted since the showing ends it: there is no showing to
/// return, and `open` records a new one.
pub fn drift_ends_the_showing_test() {
  let w = world.new()
  let drafted = reply.draft(w, "m2", "run-2", context("m2"))
  let assert Ok(card) = open(w, drafted.id, world.felipe)
  world.commit(w.db, memory.put(_, "profile:ana", "2"))
  assert showing(w, drafted.id, world.felipe) == None
  let assert Ok(new) = open(w, drafted.id, world.felipe)
  assert decisions.ticket(new) != decisions.ticket(card)
  assert showing(w, drafted.id, world.felipe) == Some(decisions.ticket(new))
}

/// Any entry other than a showing, recorded after it, ends it.
pub fn a_note_ends_the_showing_test() {
  let w = world.new()
  let drafted = reply.draft(w, "m3", "run-3", context("m3"))
  let assert Ok(card) = open(w, drafted.id, world.felipe)
  let assert Ok(_) =
    world.in_tx(w, decisions.note(reply.desk(), _, card, "called ana"))
  assert showing(w, drafted.id, world.felipe) == None
  let assert Ok(new) = open(w, drafted.id, world.felipe)
  assert decisions.ticket(new) != decisions.ticket(card)
}
