//// `happened` serialises on its point and subject: it loads the subject
//// lock before it reads `waiting` and before any record's lock.

import decisions.{Gated}
import decisions/memory.{type Memory}
import decisions/policy.{AnyoneHolding, Ask, Policy}
import decisions/store
import decisions/vocabulary.{
  Agent, Manifest, Recommendation, RuleFired, Subject, Trigger,
}
import decisions/wire
import gleam/list
import gleam/result
import gleam/string
import support/world

const subject = Subject("contact", "c-1")

fn log(tx: Memory, call: String) -> Nil {
  let before = memory.get(tx, "calls") |> result.unwrap("")
  memory.put(tx, "calls", before <> call <> "\n")
}

fn calls(db: Memory) -> List(String) {
  memory.get(db, "calls")
  |> result.unwrap("")
  |> string.split("\n")
  |> list.filter(fn(line) { line != "" })
}

/// The memory port, writing down each `load` and `waiting` it serves.
fn watched() -> store.Port(Memory) {
  let p = memory.port()
  store.Port(
    ..p,
    load: fn(tx, id) {
      log(tx, "load " <> id)
      p.load(tx, id)
    },
    waiting: fn(tx, point, about) {
      log(tx, "waiting")
      p.waiting(tx, point, about)
    },
  )
}

fn desk() {
  decisions.desk(
    decisions.point("lock.reply", wire.text())
      |> decisions.superseded_by("newer_message"),
    drives: fn(_) {
      Gated(name: "send", guard: fn(_, _) { Ok([]) }, execute: fn(_, _) {
        Ok(Nil)
      })
    },
    under: fn(_) { Ok(Policy(1, [], Ask(AnyoneHolding("support")))) },
    over: watched(),
  )
}

fn proposal(text: String) {
  decisions.proposal(
    trigger: Trigger("message", text),
    about: subject,
    context: Manifest([], "r"),
    recommending: Recommendation(
      text,
      Agent("reply", "1"),
      RuleFired("r"),
      [],
      [],
    ),
  )
}

fn seeded() -> Memory {
  let db = world.new().db
  let d = desk()
  let assert Ok(_) =
    memory.transaction(db, decisions.recommend_once(
      d,
      _,
      key: "reply:m1",
      proposal: proposal("m1"),
    ))
  let assert Ok(Nil) =
    memory.transaction(db, decisions.expect(
      d,
      _,
      key: "reply:m2",
      trigger: Trigger("message", "m2"),
      about: subject,
    ))
  memory.put(db, "calls", "")
  db
}

pub fn the_subject_lock_comes_before_waiting_and_every_record_test() {
  let db = seeded()
  let lock = decisions.subject_lock(point: "lock.reply", subject:)
  let assert Ok(decisions.Supersession(
    expired: [_],
    not_begun: ["reply:m2"],
    unreadable: [],
  )) =
    memory.transaction(db, decisions.happened(
      desk(),
      _,
      "newer_message",
      about: subject,
    ))
  let assert ["load " <> first, "waiting", ..records] = calls(db)
  assert first == lock
  // Every record is locked after the subject, in `waiting`'s order (a
  // record may be read again once it is locked).
  assert list.unique(records) == ["load reply:m1", "load reply:m2"]
  // The lock id holds nothing and is no record.
  assert memory.entries(db, lock) == []
  assert list.key_find(memory.heads(db), lock) == Error(Nil)
}

pub fn an_undeclared_event_loads_nothing_test() {
  let db = seeded()
  assert memory.transaction(db, decisions.happened(
      desk(),
      _,
      "something_else",
      about: subject,
    ))
    == Ok(decisions.Supersession(expired: [], not_begun: [], unreadable: []))
  assert calls(db) == []
}

pub fn the_lock_id_is_bounded_test() {
  let long = string.repeat("ponto-ção.", 5000)
  let id =
    decisions.subject_lock(point: long, subject: Subject(long, long <> "x"))
  assert string.byte_size(id) <= 255
  assert string.starts_with(id, decisions.subject_lock_prefix)
  assert string.byte_size(decisions.subject_lock(
      point: "",
      subject: Subject("", ""),
    ))
    == string.byte_size(id)
}

pub fn points_and_subjects_give_different_lock_ids_test() {
  let id = fn(point, kind, of) {
    decisions.subject_lock(point:, subject: Subject(kind, of))
  }
  let ids = [
    id("a", "contact", "1"),
    id("a", "contact", "2"),
    id("b", "contact", "1"),
    id("a", "company", "1"),
    // The parts cannot be confused by moving a separator.
    id("a", "b:c", "1"),
    id("a:b", "c", "1"),
    id("a", "bc", "1"),
    id("ab", "c", "1"),
    id("p", "k", "i:d"),
    id("p", "k:i", "d"),
  ]
  assert list.length(list.unique(ids)) == list.length(ids)
  // The same point and subject always give the same lock.
  assert id("a", "contact", "1") == id("a", "contact", "1")
}

/// Superseding reads each record once: one `load` for the subject lock,
/// then one per waiting record.
pub fn happened_loads_each_record_once_test() {
  let db = world.new().db
  let d = desk()
  let keys = ["reply:a", "reply:b", "reply:c", "reply:d"]
  list.each(keys, fn(key) {
    let assert Ok(_) =
      memory.transaction(db, decisions.recommend_once(
        d,
        _,
        key:,
        proposal: proposal(key),
      ))
  })
  let assert Ok(Nil) =
    memory.transaction(db, decisions.expect(
      d,
      _,
      key: "reply:e",
      trigger: Trigger("message", "e"),
      about: subject,
    ))
  memory.put(db, "calls", "")
  let assert Ok(decisions.Supersession(expired:, not_begun: ["reply:e"], ..)) =
    memory.transaction(db, decisions.happened(
      d,
      _,
      "newer_message",
      about: subject,
    ))
  assert list.length(expired) == 4
  let lock = decisions.subject_lock(point: "lock.reply", subject:)
  assert calls(db)
    == [
      "load " <> lock,
      "waiting",
      ..list.map(list.append(keys, ["reply:e"]), fn(key) { "load " <> key })
    ]
}
