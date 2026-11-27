//// A single-process, in-memory store for tests and examples. It implements
//// the whole storage port and passes `decisions/conformance`.
////
//// It keeps nothing but text, so `restart` is honest: only what a
//// database would hold survives it. A transaction is `transaction`: when
//// its body returns `Error`, or raises, every row is put back. The
//// transaction value `tx` is the `Memory` itself.
////
//// It is safe only for one process at a time: it serialises nothing, so
//// two processes using one `Memory` at once can interleave their
//// transactions. The lock the port promises (on an occurrence, and on an
//// id that does not exist yet) holds here only because one process runs
//// one transaction at a time. For concurrent tests use the process-safe
//// store of `decisions_otp`.
////
//// The same table also holds an application's own rows (`get` and
//// `put`), so a gated tool's writes commit and roll back with the verdict
//// that released them, as they would in one database.
////
//// ```gleam
//// import decisions/memory
////
//// let store = memory.new()
//// let desk = decisions.desk(point, drives:, under:, over: memory.port())
//// let assert Ok(waiting) =
////   memory.transaction(store, decisions.recommend(desk, _, proposal))
//// memory.queue(store, "finance")
//// ```
////
//// Target-independent: builds for Erlang (an ETS table) and JavaScript (a
//// `Map`).

import decisions/model.{type Evidence, Evidence}
import decisions/store.{
  type Head, type Inspection, type Notice, type Port, type StoreError,
  type Stored, type Wake, Conflict, Head, Inspection, Notice, Port, Stored, Wake,
}
import decisions/vocabulary.{type Ref, type Subject, type Validator}
import decisions/wire
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp.{type Timestamp}

/// A table of text. It is also the transaction value of the port.
pub type Memory

/// A new, empty store whose clock reads the Unix epoch.
@external(erlang, "decisions_memory_ffi", "new")
@external(javascript, "../decisions_memory_ffi.mjs", "new_")
pub fn new() -> Memory

@external(erlang, "decisions_memory_ffi", "get")
@external(javascript, "../decisions_memory_ffi.mjs", "get")
fn raw_get(memory: Memory, key: String) -> Result(String, Nil)

@external(erlang, "decisions_memory_ffi", "put")
@external(javascript, "../decisions_memory_ffi.mjs", "put")
fn raw_put(memory: Memory, key: String, value: String) -> Nil

@external(erlang, "decisions_memory_ffi", "rows")
@external(javascript, "../decisions_memory_ffi.mjs", "rows")
fn rows(memory: Memory) -> List(#(String, String))

@external(erlang, "decisions_memory_ffi", "restore")
@external(javascript, "../decisions_memory_ffi.mjs", "restore")
fn restore(memory: Memory, rows: List(#(String, String))) -> Nil

@external(erlang, "decisions_memory_ffi", "guarded")
@external(javascript, "../decisions_memory_ffi.mjs", "guarded")
fn guarded(memory: Memory, body: fn() -> Result(a, e)) -> Result(a, e)

/// Run `body` as one transaction. When it returns `Error`, or raises,
/// every row is put back as it was, the application's rows included.
pub fn transaction(
  memory: Memory,
  body: fn(Memory) -> Result(a, e),
) -> Result(a, e) {
  guarded(memory, fn() { body(memory) })
}

/// A new table holding only the old one's text, as a database would after
/// a restart. Everything built on the old handle must be built again.
pub fn restart(memory: Memory) -> Memory {
  let fresh = new()
  restore(fresh, rows(memory))
  fresh
}

/// An application's own row, read in the same transactions as the
/// record.
pub fn get(memory: Memory, key: String) -> Result(String, Nil) {
  raw_get(memory, "app:" <> key)
}

/// Write an application's own row. It commits and rolls back with the
/// transaction it is written in.
pub fn put(memory: Memory, key: String, value: String) -> Nil {
  raw_put(memory, "app:" <> key, value)
}

/// The storage port over a `Memory`.
pub fn port() -> Port(Memory) {
  Port(
    load: fn(tx, id) { Ok(entries(tx, id)) },
    append:,
    waiting: fn(tx, point, subject) { Ok(waiting(tx, point, subject)) },
    schedule:,
    settled: fn(tx, point, occurrence) {
      write_list(
        tx,
        "notices",
        list.append(notices(tx), [Notice(point:, occurrence:)]),
        notice_to_json,
      )
      Ok(Nil)
    },
    atomically: fn(tx, body) { Ok(guarded(tx, fn() { body(tx) })) },
    now: now,
    new_id: fn(tx) {
      let next =
        { raw_get(tx, "next_id") |> result.try(int.parse) |> result.unwrap(0) }
        + 1
      raw_put(tx, "next_id", int.to_string(next))
      "occ-" <> int.to_string(next)
    },
    members: fn(tx, bundle) { Ok(members(tx, bundle)) },
  )
}

/// What `decisions/conformance` and `decisions/testing` read.
pub fn inspection() -> Inspection(Memory) {
  Inspection(
    occurrences: fn(tx, point) {
      Ok(
        heads(tx)
        |> list.filter(fn(pair) { { pair.1 }.point == point })
        |> list.map(fn(pair) { pair.0 }),
      )
    },
    head: fn(tx, id) { Ok(head(tx, id)) },
    wakes: fn(tx) { Ok(wakes(tx)) },
    notices: fn(tx) { Ok(notices(tx)) },
  )
}

/// Evidence kept in the same table, for `decisions/model.capture`.
pub fn evidence() -> Evidence(Memory) {
  Evidence(
    put: fn(tx, ref, body) {
      raw_put(tx, evidence_key(ref), body)
      Ok(Nil)
    },
    get: fn(tx, ref) {
      raw_get(tx, evidence_key(ref))
      |> result.replace_error("no evidence stored for " <> evidence_key(ref))
    },
  )
}

fn evidence_key(ref: Ref) -> String {
  "evidence:" <> ref.kind <> ":" <> ref.id <> "@" <> ref.revision
}

// -- The clock ------------------------------------------------------------------

/// The store's clock. It moves only when a test moves it.
pub fn now(memory: Memory) -> Timestamp {
  raw_get(memory, "clock")
  |> result.try(int.parse)
  |> result.unwrap(0)
  |> wire.from_milliseconds
}

/// Set the clock, forwards or backwards.
pub fn set_clock(memory: Memory, at: Timestamp) -> Nil {
  raw_put(memory, "clock", int.to_string(wire.milliseconds(at)))
}

/// Move the clock forward.
pub fn advance(memory: Memory, by: Duration) -> Nil {
  set_clock(memory, timestamp.add(now(memory), by))
}

// -- What a test may read --------------------------------------------------------

/// The stored entries of a record, in sequence order.
pub fn entries(memory: Memory, id: String) -> List(Stored) {
  read_list(memory, "entries:" <> id, stored_decoder())
}

/// Every record's head, in the order the records were first written.
pub fn heads(memory: Memory) -> List(#(String, Head)) {
  read_list(memory, "ids", decode.string)
  |> list.filter_map(fn(id) {
    head(memory, id) |> option.to_result(Nil) |> result.map(fn(h) { #(id, h) })
  })
}

fn head(memory: Memory, id: String) -> Option(Head) {
  raw_get(memory, "head:" <> id)
  |> result.try(fn(text) {
    json.parse(text, head_decoder()) |> result.replace_error(Nil)
  })
  |> option.from_result
}

/// The occurrences waiting for a holder of `set`: the soonest due first,
/// those with no due time last, then in arrival order.
pub fn queue(memory: Memory, set: String) -> List(String) {
  heads(memory)
  |> list.filter(fn(pair) { list.contains({ pair.1 }.awaiting, set) })
  |> in_queue_order
}

/// The occurrences a validator may decide: waiting for a set they hold,
/// not already approved by them, and not among those the head says may
/// not decide (their own request under `SomeoneElseHolding`), in queue
/// order.
pub fn queue_for(memory: Memory, validator: Validator) -> List(String) {
  heads(memory)
  |> list.filter(fn(pair) {
    let head = pair.1
    list.any(head.awaiting, list.contains(validator.holds, _))
    && !list.contains(head.approved, validator.subject)
    && !list.contains(head.may_not_decide, validator.subject)
  })
  |> in_queue_order
}

fn in_queue_order(pairs: List(#(String, Head))) -> List(String) {
  pairs
  |> list.sort(fn(a, b) {
    let #(_, first) = a
    let #(_, second) = b
    case first.due, second.due {
      Some(x), Some(y) ->
        case timestamp.compare(x, y) {
          order.Eq -> timestamp.compare(first.arrived, second.arrived)
          other -> other
        }
      Some(_), None -> order.Lt
      None, Some(_) -> order.Gt
      None, None -> timestamp.compare(first.arrived, second.arrived)
    }
  })
  |> list.map(fn(pair) { pair.0 })
}

/// Sampled occurrences waiting for a review after the fact.
pub fn review_queue(memory: Memory) -> List(String) {
  heads(memory)
  |> list.filter(fn(pair) { { pair.1 }.review_pending })
  |> list.map(fn(pair) { pair.0 })
}

/// Every pending wake-up.
pub fn wakes(memory: Memory) -> List(Wake) {
  read_list(memory, "wakes", wake_decoder())
}

/// The wake-ups due now, removed as a delivered job would be.
pub fn take_due(memory: Memory) -> List(Wake) {
  let at = now(memory)
  let #(due, later) =
    list.partition(wakes(memory), fn(wake) {
      timestamp.compare(wake.at, at) != order.Gt
    })
  write_list(memory, "wakes", later, wake_to_json)
  due
}

/// Put a delivered wake-up back for `until`, as a job queue snoozes a job
/// that `decisions.wake` found early (`NotDue(until)`).
pub fn snooze(memory: Memory, wake: Wake, until: Timestamp) -> Nil {
  write_list(
    memory,
    "wakes",
    list.append(wakes(memory), [Wake(..wake, at: until)]),
    wake_to_json,
  )
}

/// Every settlement notice, in the order admitted.
pub fn notices(memory: Memory) -> List(Notice) {
  read_list(memory, "notices", {
    use point <- decode.field("point", decode.string)
    use occurrence <- decode.field("occurrence", decode.string)
    decode.success(Notice(point:, occurrence:))
  })
}

/// Replace the stored text of one entry, bypassing every rule of the
/// port. It exists to test what a desk does with a record it cannot read.
pub fn tamper(memory: Memory, id: String, seq: Int, text: String) -> Nil {
  let changed =
    list.map(entries(memory, id), fn(stored) {
      case stored.seq == seq {
        True -> Stored(..stored, event: text)
        False -> stored
      }
    })
  write_list(memory, "entries:" <> id, changed, stored_to_json)
}

// -- The port ----------------------------------------------------------------------

fn append(
  tx: Memory,
  id: String,
  head: Head,
  fresh: List(Stored),
) -> Result(Nil, StoreError) {
  let held = entries(tx, id)
  let last = list.length(held)
  let in_order =
    list.index_map(fresh, fn(stored, index) { stored.seq == last + index + 1 })
    |> list.all(fn(ok) { ok })
  let releases =
    list.append(held, fresh)
    |> list.count(fn(stored) { stored.kind == "released" })
  case in_order, releases > 1 {
    False, _ ->
      Error(Conflict(
        "occurrence "
        <> id
        <> " holds "
        <> int.to_string(last)
        <> " entries; these do not follow",
      ))
    True, True -> Error(Conflict("occurrence " <> id <> " is already released"))
    True, False -> {
      case held {
        [] -> {
          let ids = list.append(read_list(tx, "ids", decode.string), [id])
          write_list(tx, "ids", ids, json.string)
        }
        _ -> Nil
      }
      write_list(tx, "entries:" <> id, list.append(held, fresh), stored_to_json)
      raw_put(tx, "head:" <> id, json.to_string(head_to_json(head)))
      Ok(Nil)
    }
  }
}

fn waiting(tx: Memory, point: String, subject: Subject) -> List(String) {
  heads(tx)
  |> list.filter(fn(pair) {
    let Head(point: of, subject: about, status:, ..) = pair.1
    of == point && about == subject && store.is_waiting(status)
  })
  |> list.map(fn(pair) { pair.0 })
  |> list.sort(string.compare)
}

fn members(tx: Memory, bundle: String) -> List(#(String, Head)) {
  heads(tx)
  |> list.filter(fn(pair) {
    case { pair.1 }.bundle {
      Some(of) -> of.key == bundle
      None -> False
    }
  })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

fn schedule(
  tx: Memory,
  point: String,
  occurrence: String,
  at: List(Timestamp),
) -> Result(Nil, StoreError) {
  let others =
    list.filter(wakes(tx), fn(wake) {
      wake.point != point || wake.occurrence != occurrence
    })
  let mine = list.map(at, fn(at) { Wake(point:, occurrence:, at:) })
  write_list(tx, "wakes", list.append(others, mine), wake_to_json)
  Ok(Nil)
}

// -- Text --------------------------------------------------------------------------

fn read_list(memory: Memory, key: String, decoder: Decoder(a)) -> List(a) {
  raw_get(memory, key)
  |> result.try(fn(text) {
    json.parse(text, decode.list(decoder)) |> result.replace_error(Nil)
  })
  |> result.unwrap([])
}

fn write_list(
  memory: Memory,
  key: String,
  items: List(a),
  encode: fn(a) -> Json,
) -> Nil {
  raw_put(memory, key, json.to_string(json.array(items, encode)))
}

fn stored_to_json(stored: Stored) -> Json {
  json.object([
    #("seq", json.int(stored.seq)),
    #("at", wire.time(stored.at)),
    #("kind", json.string(stored.kind)),
    #("event", json.string(stored.event)),
  ])
}

fn stored_decoder() -> Decoder(Stored) {
  use seq <- decode.field("seq", decode.int)
  use at <- decode.field("at", wire.time_decoder())
  use kind <- decode.field("kind", decode.string)
  use event <- decode.field("event", decode.string)
  decode.success(Stored(seq:, at:, kind:, event:))
}

fn head_to_json(head: Head) -> Json {
  json.object([
    #("point", json.string(head.point)),
    #("subject", wire.subject(head.subject)),
    #("status", json.string(store.status_name(head.status))),
    #("awaiting", json.array(head.awaiting, json.string)),
    #("due", wire.optional(head.due, wire.time)),
    #("arrived", wire.time(head.arrived)),
    #("approved", json.array(head.approved, json.string)),
    #("may_not_decide", json.array(head.may_not_decide, json.string)),
    #("review_pending", json.bool(head.review_pending)),
    #("bundle", wire.optional(head.bundle, wire.bundle)),
  ])
}

fn head_decoder() -> Decoder(Head) {
  use point <- decode.field("point", decode.string)
  use subject <- decode.field("subject", wire.subject_decoder())
  use status <- decode.field("status", {
    use name <- decode.then(decode.string)
    case store.parse_status(name) {
      Ok(status) -> decode.success(status)
      Error(Nil) -> decode.failure(store.Pending, "a status")
    }
  })
  use awaiting <- decode.field("awaiting", decode.list(decode.string))
  use due <- decode.field("due", decode.optional(wire.time_decoder()))
  use arrived <- decode.field("arrived", wire.time_decoder())
  use approved <- decode.field("approved", decode.list(decode.string))
  use may_not_decide <- decode.field(
    "may_not_decide",
    decode.list(decode.string),
  )
  use review_pending <- decode.field("review_pending", decode.bool)
  use bundle <- decode.optional_field(
    "bundle",
    None,
    decode.optional(wire.bundle_decoder()),
  )
  decode.success(Head(
    point:,
    subject:,
    status:,
    awaiting:,
    due:,
    arrived:,
    approved:,
    may_not_decide:,
    review_pending:,
    bundle:,
  ))
}

fn wake_to_json(wake: Wake) -> Json {
  json.object([
    #("point", json.string(wake.point)),
    #("occurrence", json.string(wake.occurrence)),
    #("at", wire.time(wake.at)),
  ])
}

fn wake_decoder() -> Decoder(Wake) {
  use point <- decode.field("point", decode.string)
  use occurrence <- decode.field("occurrence", decode.string)
  use at <- decode.field("at", wire.time_decoder())
  decode.success(Wake(point:, occurrence:, at:))
}

fn notice_to_json(notice: Notice) -> Json {
  json.object([
    #("point", json.string(notice.point)),
    #("occurrence", json.string(notice.occurrence)),
  ])
}
