//// Test support: the world a scenario runs in.
////
//// `db` is the application's database: transactional, and all that
//// survives a restart. `fabric` stands for an agent runtime's retained
//// runs. `outside` is everything beyond the platform; it never rolls back.

import decisions.{type Card, type Desk, type Refusal}
import decisions/conformance
import decisions/learning.{type Read, Read}
import decisions/memory.{type Memory}
import decisions/model.{type Sources, Sources}
import decisions/occurrence.{type Occurrence}
import decisions/testing
import decisions/vocabulary.{
  type Explanation, type Ref, type Validator, type Verdict, RunAction, RunAnswer,
  Subject, Validator,
}
import decisions/wire
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}

pub type World {
  World(db: Memory, fabric: Memory, outside: Memory)
}

pub const ana = Subject(kind: "person", id: "ana")

pub const clinica = Subject(kind: "company", id: "clinica-x")

pub const clinica_y = Subject(kind: "company", id: "clinica-y")

pub const felipe = Validator(subject: "felipe", holds: ["operators", "finance"])

pub const bia = Validator(subject: "bia", holds: ["operators", "finance"])

pub const caio = Validator(subject: "caio", holds: ["operators", "finance"])

pub const dora = Validator(subject: "dora", holds: ["managers", "finance"])

/// A manager who holds no finance set.
pub const dora_as_manager = Validator(subject: "dora", holds: ["managers"])

pub const caio_in_support = Validator(subject: "caio", holds: ["support"])

pub fn t0() -> Timestamp {
  wire.from_milliseconds(1_800_000_000_000)
}

pub fn new() -> World {
  let db = memory.new()
  memory.set_clock(db, t0())
  World(db:, fabric: memory.new(), outside: memory.new())
}

/// Only the database's text survives; every desk must be built again.
pub fn restart(world: World) -> World {
  World(..world, db: memory.restart(world.db))
}

pub fn at(world: World, offset: Duration) -> Nil {
  memory.set_clock(world.db, timestamp.add(t0(), offset))
}

pub fn in_tx(world: World, body: fn(Memory) -> Result(a, e)) -> Result(a, e) {
  memory.transaction(world.db, body)
}

/// The memory store as an adapter, for conformance and invariant checks.
pub fn adapter(db: Memory) -> conformance.Adapter(Memory) {
  conformance.Adapter(
    port: memory.port(),
    inspect: memory.inspection(),
    transaction: fn(body) { memory.transaction(db, body) },
    cleanup: fn() { Nil },
  )
}

/// Every invariant of `decisions/testing` holds over these audits.
pub fn invariants_hold(
  world: World,
  audits: List(testing.Audit(Memory)),
) -> Nil {
  case testing.check(world.db, memory.inspection(), audits) {
    Ok(_) -> Nil
    Error(violations) ->
      panic as { "invariants broken: " <> string.inspect(violations) }
  }
}

/// Deliver the wake-ups due now, each in its own transaction, as a job
/// queue would. A wake-up that arrived early is scheduled again at the
/// time it names. Returns how many were delivered.
pub fn deliver_due(
  world: World,
  wakers: List(
    #(String, fn(Memory, String) -> Result(option.Option(Timestamp), Refusal)),
  ),
) -> Int {
  let due = memory.take_due(world.db)
  list.each(due, fn(wake) {
    let assert Ok(waker) = list.key_find(wakers, wake.point)
    case in_tx(world, waker(_, wake.occurrence)) {
      Ok(None) -> Nil
      Ok(Some(until)) -> memory.snooze(world.db, wake, until)
      Error(refusal) ->
        panic as { "a wake-up failed: " <> decisions.describe(refusal) }
    }
  })
  list.length(due)
}

// -- Lists and counters of text ------------------------------------------------

pub fn push(memory: Memory, key: String, text: String) -> Nil {
  memory.put(
    memory,
    key,
    json.to_string(json.array(
      list.append(all(memory, key), [text]),
      json.string,
    )),
  )
}

pub fn all(memory: Memory, key: String) -> List(String) {
  memory.get(memory, key)
  |> result.try(fn(text) {
    json.parse(text, decode.list(decode.string)) |> result.replace_error(Nil)
  })
  |> result.unwrap([])
}

pub fn bump(memory: Memory, key: String) -> Nil {
  memory.put(memory, key, int.to_string(count(memory, key) + 1))
}

pub fn count(memory: Memory, key: String) -> Int {
  memory.get(memory, key) |> result.try(int.parse) |> result.unwrap(0)
}

pub fn effects(key: String) -> fn(Memory) -> Result(Int, String) {
  fn(db) { Ok(list.length(all(db, key))) }
}

// -- Retained runs, standing for an agent runtime --------------------------------

/// Sources for a model inside run `run`. Each read goes through capture, so
/// its response is evidence before the model sees it, and is retained in
/// the run.
pub fn capturing(
  world: World,
  run: String,
  resolve: fn(Ref) -> Result(String, String),
  fetch: fn(String, String) -> Result(String, String),
) -> Sources {
  Sources(
    resolve: fn(ref: Ref) {
      resolve(ref)
      |> result.map_error(model.ReadFailed(ref.kind, ref.id, _))
    },
    read: fn(name, argument) {
      use captured <- result.try(
        model.capture(
          memory.evidence(),
          world.db,
          source: name,
          request: argument,
          fetch: fn() { fetch(name, argument) },
        )
        |> result.map_error(model.ReadFailed(name, argument, _)),
      )
      push(
        world.fabric,
        "run:" <> run,
        json.to_string(
          json.object([
            #("name", json.string(name)),
            #("argument", json.string(argument)),
            #("result", wire.ref(captured.ref)),
          ]),
        ),
      )
      Ok(captured)
    },
  )
}

/// The reads retained in the run an explanation points into.
pub fn reads(world: World) -> fn(Explanation) -> List(Read) {
  fn(explanation) {
    case explanation {
      RunAnswer(run:) | RunAction(run:, ..) ->
        all(world.fabric, "run:" <> run)
        |> list.filter_map(fn(text) {
          json.parse(text, {
            use name <- decode.field("name", decode.string)
            use argument <- decode.field("argument", decode.string)
            use result <- decode.field("result", wire.ref_decoder())
            decode.success(Read(name:, argument:, result:))
          })
        })
      _ -> []
    }
  }
}

pub fn unchanged(ref: Ref) -> String {
  ref.revision
}

/// A validator opens the card, in the caller's transaction.
pub fn open(
  desk: Desk(o, Memory),
  tx: Memory,
  id: String,
  validator: Validator,
) -> Result(Card(o), Refusal) {
  decisions.open(desk, tx, occurrence: id, by: validator, latest: unchanged)
}

/// A validator opens the card and gives a verdict, in one transaction.
pub fn open_and_decide(
  desk: Desk(o, Memory),
  tx: Memory,
  id: String,
  validator: Validator,
  verdict: Verdict(o),
) -> Result(Occurrence(o), Refusal) {
  use card <- result.try(open(desk, tx, id, validator))
  decisions.decide(desk, tx, card, verdict)
}

pub fn read(world: World, desk: Desk(o, Memory), id: String) -> Occurrence(o) {
  let assert Ok(known) = in_tx(world, decisions.read(desk, _, occurrence: id))
  known
}

pub fn numbers(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..numbers(from + 1, to)]
  }
}
