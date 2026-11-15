//// The storage port's contract as executable checks. An adapter's own
//// tests run them; `decisions/memory` passes them, and so must every
//// adapter.
////
//// Each check gets a fresh `Adapter` and returns `Ok(Nil)` or a
//// `Unmet` value that names the check and what it saw. The checks cover what
//// one process can observe: an absent id loads empty and takes its first
//// entry once, a repeated sequence number, a gap and a second release are
//// refused, a rolled-back transaction leaves nothing, a savepoint rolls
//// back alone (whether its body returns an error or raises) and keeps the
//// transaction usable, a savepoint's writes go with a transaction that
//// rolls back, the head comes back as written, `waiting` returns only
//// recommended and awaiting occurrences in id order, wake-ups are replaced
//// and cancelled, settlement notices are admitted once, entries come back
//// in order and byte for byte, and a desk driven over the adapter
//// schedules its hold, deadline and policy steps, cancels them when it
//// settles, and keeps every invariant of `decisions/testing`. This
//// package's own tests break an in-memory adapter in each of these clauses
//// in turn and show that the check naming it fails.
////
//// The suite assumes nothing about the clock between two reads: an
//// adapter's `now` may return a later time on every call.
////
//// What needs several processes, or a real clock, is not checked here:
//// that `now` is the wall clock at the moment of the call and not the
//// transaction's start, that `schedule` leaves alone a wake-up the job
//// queue already delivered (delivery is outside the port), that a second
//// transaction loading an absent or a present id waits for the first, that
//// uncommitted writes are invisible to other transactions, and that a
//// process killed inside a transaction or a savepoint leaves nothing.
//// The stress suites of `decisions_otp` and `decisions_postgres` check
//// those.
////
//// ```gleam
//// import decisions/conformance
//// import decisions/memory
////
//// pub fn memory_conforms_test() {
////   let assert Ok(Nil) =
////     conformance.run(fn() {
////       let store = memory.new()
////       Ok(conformance.Adapter(
////         port: memory.port(),
////         inspect: memory.inspection(),
////         handle: store,
////         transaction: fn(body) { memory.transaction(store, body) },
////         cleanup: fn() { Nil },
////       ))
////     })
//// }
//// ```
////
//// Target-independent: builds for Erlang and JavaScript.

import decisions.{type Desk, Gated}
import decisions/internal/rescue
import decisions/model
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Ask, Never, Policy, Proceed}
import decisions/store.{
  type Head, type Inspection, type Port, type Stored, Conflict, Head, Notice,
  Stored,
}
import decisions/testing
import decisions/vocabulary.{
  Approve, Manifest, OwnAct, Person, Recommendation, Ref, Subject, Trigger,
  Validator,
}
import decisions/wire
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}

/// An adapter under test.
pub type Adapter(tx) {
  Adapter(
    port: Port(tx),
    inspect: Inspection(tx),
    /// A handle usable outside any transaction: each port call on it is a
    /// transaction of its own. The checks read through it.
    handle: tx,
    /// Run `body` in one transaction: commit on `Ok`, roll back on `Error`.
    transaction: fn(fn(tx) -> Result(Nil, String)) -> Result(Nil, String),
    /// Called after each check, whatever its result.
    cleanup: fn() -> Nil,
  )
}

/// A named check of one clause of the contract.
pub type Check(tx) {
  Check(name: String, run: fn(Adapter(tx)) -> Result(Nil, String))
}

/// Why the suite did not pass.
pub type Unmet {
  /// The adapter factory returned this error.
  SetupFailed(reason: String)
  /// The named check saw this.
  CheckFailed(check: String, saw: String)
}

/// Every check, in the order `run` runs them.
pub fn checks() -> List(Check(tx)) {
  [
    Check("an absent id loads empty", absent_loads_empty),
    Check("an absent id takes its first entry once", first_entry_once),
    Check("entries come back in order and unchanged", entries_round_trip),
    Check("a repeated sequence number is refused", repeated_sequence),
    Check("a gap in sequence numbers is refused", gap_refused),
    Check("a second release is refused", second_release),
    Check("a rolled-back transaction leaves nothing", rollback_leaves_nothing),
    Check("a savepoint rolls back alone", savepoint_rolls_back),
    Check("a savepoint keeps what succeeded", savepoint_keeps),
    Check("a savepoint whose body raises rolls back alone", savepoint_raises),
    Check(
      "a savepoint inside a rolled-back transaction leaves nothing",
      savepoint_in_rollback,
    ),
    Check("the head comes back as written", head_round_trip),
    Check("waiting filters by point, subject and status, in id order", waiting),
    Check("wake-ups are replaced and cancelled", wakes_replaced),
    Check("settlement notices are admitted in order", notices),
    Check("new ids are unique", unique_ids),
    Check("a desk keeps every invariant over the adapter", desk_invariants),
    Check("a refused release leaves nothing behind", refused_release),
    Check("a wake-up that is early says when to come back", early_wake),
    Check(
      "a desk schedules its deadline and policy steps and cancels them",
      desk_wakes,
    ),
  ]
}

/// Run every check, each on a fresh adapter, and report every failure.
pub fn run(
  fresh: fn() -> Result(Adapter(tx), String),
) -> Result(Nil, List(Unmet)) {
  let failures =
    list.filter_map(checks(), fn(check) {
      case run_check(check, fresh) {
        Ok(Nil) -> Error(Nil)
        Error(failure) -> Ok(failure)
      }
    })
  case failures {
    [] -> Ok(Nil)
    _ -> Error(failures)
  }
}

/// Run one check on a fresh adapter.
pub fn run_check(
  check: Check(tx),
  fresh: fn() -> Result(Adapter(tx), String),
) -> Result(Nil, Unmet) {
  use adapter <- result.try(fresh() |> result.map_error(SetupFailed))
  let outcome = check.run(adapter)
  adapter.cleanup()
  outcome |> result.map_error(CheckFailed(check.name, _))
}

// -- Store checks ---------------------------------------------------------------------

fn absent_loads_empty(adapter: Adapter(tx)) -> Result(Nil, String) {
  let id = fresh_id(adapter, "absent")
  use found <- result.try(load(adapter, adapter.handle, id))
  expect(found == [], "load of an absent id returned entries")
}

fn first_entry_once(adapter: Adapter(tx)) -> Result(Nil, String) {
  let id = fresh_id(adapter, "first")
  let first = fn(tx) {
    use found <- result.try(load(adapter, tx, id))
    case found {
      [] ->
        append(adapter, tx, id, head(adapter, "p"), [stored(1, "recommended")])
      _ -> Ok(Nil)
    }
  }
  use Nil <- result.try(adapter.transaction(first))
  use Nil <- result.try(adapter.transaction(first))
  use found <- result.try(load(adapter, adapter.handle, id))
  use Nil <- result.try(expect(
    list.length(found) == 1,
    "two admissions stored " <> int.to_string(list.length(found)) <> " entries",
  ))
  // A second first entry, written without loading, is refused.
  case
    adapter.port.append(adapter.handle, id, head(adapter, "p"), [
      stored(1, "recommended"),
    ])
  {
    Error(Conflict(_)) -> Ok(Nil)
    Error(error) ->
      Error("a second first entry failed as " <> store.describe(error))
    Ok(Nil) -> Error("a second first entry was accepted")
  }
}

fn entries_round_trip(adapter: Adapter(tx)) -> Result(Nil, String) {
  let id = fresh_id(adapter, "order")
  let written = [
    stored(1, "recommended"),
    Stored(
      ..stored(2, "policy_applied"),
      event: "{\"text\":\"ção ✓ \\\"q\\\"\"}",
    ),
  ]
  let more = [stored(3, "opened"), stored(4, "decided")]
  use Nil <- result.try(append(
    adapter,
    adapter.handle,
    id,
    head(adapter, "p"),
    written,
  ))
  use Nil <- result.try(append(
    adapter,
    adapter.handle,
    id,
    head(adapter, "p"),
    more,
  ))
  use found <- result.try(load(adapter, adapter.handle, id))
  expect(
    found == list.append(written, more),
    "entries came back as " <> string.inspect(found),
  )
}

fn repeated_sequence(adapter: Adapter(tx)) -> Result(Nil, String) {
  let id = fresh_id(adapter, "repeat")
  use Nil <- result.try(
    append(adapter, adapter.handle, id, head(adapter, "p"), [
      stored(1, "recommended"),
      stored(2, "policy_applied"),
    ]),
  )
  use Nil <- result.try(refused(
    adapter.port.append(adapter.handle, id, head(adapter, "p"), [
      stored(2, "opened"),
    ]),
    "a repeated sequence number",
  ))
  use found <- result.try(load(adapter, adapter.handle, id))
  expect(list.length(found) == 2, "a refused append changed the record")
}

fn gap_refused(adapter: Adapter(tx)) -> Result(Nil, String) {
  let id = fresh_id(adapter, "gap")
  use Nil <- result.try(
    append(adapter, adapter.handle, id, head(adapter, "p"), [
      stored(1, "recommended"),
    ]),
  )
  refused(
    adapter.port.append(adapter.handle, id, head(adapter, "p"), [
      stored(3, "opened"),
    ]),
    "a gap",
  )
}

fn second_release(adapter: Adapter(tx)) -> Result(Nil, String) {
  let id = fresh_id(adapter, "release")
  use Nil <- result.try(
    append(adapter, adapter.handle, id, head(adapter, "p"), [
      stored(1, "recommended"),
      stored(2, "released"),
    ]),
  )
  use Nil <- result.try(refused(
    adapter.port.append(adapter.handle, id, head(adapter, "p"), [
      stored(3, "released"),
    ]),
    "a second release",
  ))
  let other = fresh_id(adapter, "release")
  refused(
    adapter.port.append(adapter.handle, other, head(adapter, "p"), [
      stored(1, "recommended"),
      stored(2, "released"),
      stored(3, "released"),
    ]),
    "two releases in one append",
  )
}

fn rollback_leaves_nothing(adapter: Adapter(tx)) -> Result(Nil, String) {
  let id = fresh_id(adapter, "rollback")
  let rolled =
    adapter.transaction(fn(tx) {
      use Nil <- result.try(
        append(adapter, tx, id, head(adapter, "p"), [
          stored(1, "recommended"),
        ]),
      )
      use Nil <- result.try(
        adapter.port.schedule(tx, "p", id, [at(adapter, 60)])
        |> result.map_error(store.describe),
      )
      use Nil <- result.try(
        adapter.port.settled(tx, "p", id) |> result.map_error(store.describe),
      )
      Error("roll back")
    })
  use Nil <- result.try(expect(
    rolled == Error("roll back"),
    "the transaction did not return its error",
  ))
  use found <- result.try(load(adapter, adapter.handle, id))
  use head <- result.try(
    adapter.inspect.head(adapter.handle, id) |> result.map_error(store.describe),
  )
  use wakes <- result.try(
    adapter.inspect.wakes(adapter.handle) |> result.map_error(store.describe),
  )
  use notices <- result.try(
    adapter.inspect.notices(adapter.handle) |> result.map_error(store.describe),
  )
  expect(
    found == []
      && head == None
      && !list.any(wakes, fn(wake) { wake.occurrence == id })
      && !list.any(notices, fn(notice) { notice.occurrence == id }),
    "a rolled-back transaction left something",
  )
}

fn savepoint_rolls_back(adapter: Adapter(tx)) -> Result(Nil, String) {
  let outer = fresh_id(adapter, "outer")
  let inner = fresh_id(adapter, "inner")
  use Nil <- result.try(
    adapter.transaction(fn(tx) {
      use Nil <- result.try(
        append(adapter, tx, outer, head(adapter, "p"), [
          stored(1, "recommended"),
        ]),
      )
      use ran <- result.try(
        adapter.port.atomically(tx, fn(tx) {
          case
            adapter.port.append(tx, inner, head(adapter, "p"), [
              stored(1, "recommended"),
            ])
          {
            Ok(Nil) -> Error("the tool refuses after writing")
            Error(error) -> Error("the write failed: " <> store.describe(error))
          }
        })
        |> result.map_error(store.describe),
      )
      use Nil <- result.try(expect(
        ran == Error("the tool refuses after writing"),
        "atomically returned " <> string.inspect(ran),
      ))
      // The transaction is still usable after the savepoint rolled back.
      append(adapter, tx, outer, head(adapter, "p"), [stored(2, "refused")])
    }),
  )
  use outer_found <- result.try(load(adapter, adapter.handle, outer))
  use inner_found <- result.try(load(adapter, adapter.handle, inner))
  expect(
    list.length(outer_found) == 2 && inner_found == [],
    "after the savepoint the outer record holds "
      <> int.to_string(list.length(outer_found))
      <> " entries and the inner "
      <> int.to_string(list.length(inner_found)),
  )
}

fn savepoint_keeps(adapter: Adapter(tx)) -> Result(Nil, String) {
  let inner = fresh_id(adapter, "kept")
  let evidence = Ref("provider.account", "clinica-x", "1")
  use Nil <- result.try(
    adapter.transaction(fn(tx) {
      use ran <- result.try(
        adapter.port.atomically(tx, fn(tx) {
          append(adapter, tx, inner, head(adapter, "p"), [
            stored(1, "recommended"),
          ])
          |> result.replace([evidence])
        })
        |> result.map_error(store.describe),
      )
      expect(
        ran == Ok([evidence]),
        "atomically returned " <> string.inspect(ran),
      )
    }),
  )
  use found <- result.try(load(adapter, adapter.handle, inner))
  expect(list.length(found) == 1, "what the savepoint wrote was lost")
}

fn savepoint_raises(adapter: Adapter(tx)) -> Result(Nil, String) {
  let outer = fresh_id(adapter, "outer")
  let inner = fresh_id(adapter, "inner")
  use Nil <- result.try(
    adapter.transaction(fn(tx) {
      use Nil <- result.try(
        append(adapter, tx, outer, head(adapter, "p"), [
          stored(1, "recommended"),
        ]),
      )
      let raised =
        rescue.rescue(fn() {
          adapter.port.atomically(tx, fn(tx) {
            let _ =
              adapter.port.append(tx, inner, head(adapter, "p"), [
                stored(1, "recommended"),
              ])
            panic as "the tool raised after writing"
          })
        })
      use Nil <- result.try(expect(
        result.is_error(raised),
        "a raise inside the savepoint did not reach the caller",
      ))
      // The transaction is still usable after the savepoint rolled back.
      append(adapter, tx, outer, head(adapter, "p"), [stored(2, "refused")])
    }),
  )
  use outer_found <- result.try(load(adapter, adapter.handle, outer))
  use inner_found <- result.try(load(adapter, adapter.handle, inner))
  expect(
    list.length(outer_found) == 2 && inner_found == [],
    "after a raise in the savepoint the outer record holds "
      <> int.to_string(list.length(outer_found))
      <> " entries and the inner "
      <> int.to_string(list.length(inner_found)),
  )
}

fn savepoint_in_rollback(adapter: Adapter(tx)) -> Result(Nil, String) {
  let inner = fresh_id(adapter, "inner")
  let rolled =
    adapter.transaction(fn(tx) {
      use _ <- result.try(
        adapter.port.atomically(tx, fn(tx) {
          append(adapter, tx, inner, head(adapter, "p"), [
            stored(1, "recommended"),
          ])
          |> result.replace([])
        })
        |> result.map_error(store.describe),
      )
      Error("roll back")
    })
  use Nil <- result.try(expect(
    rolled == Error("roll back"),
    "the transaction did not return its error",
  ))
  use found <- result.try(load(adapter, adapter.handle, inner))
  expect(
    found == [],
    "a savepoint's writes survived its transaction's rollback",
  )
}

fn head_round_trip(adapter: Adapter(tx)) -> Result(Nil, String) {
  let id = fresh_id(adapter, "head")
  let base = at(adapter, 0)
  let first =
    Head(
      point: "billing.fee_refund",
      subject: Subject("company", "clinica-x"),
      status: store.Awaiting,
      awaiting: ["finance", "managers"],
      due: Some(plus(base, 3600)),
      arrived: base,
      approved: ["bia"],
      may_not_decide: ["felipe", "bia"],
      review_pending: False,
    )
  let second =
    Head(
      ..first,
      status: store.Released,
      awaiting: [],
      due: None,
      approved: [],
      may_not_decide: [],
      review_pending: True,
    )
  use Nil <- result.try(
    append(adapter, adapter.handle, id, first, [
      stored(1, "recommended"),
    ]),
  )
  use read <- result.try(
    adapter.inspect.head(adapter.handle, id) |> result.map_error(store.describe),
  )
  use Nil <- result.try(expect(
    read == Some(first),
    "the head came back as " <> string.inspect(read),
  ))
  use Nil <- result.try(
    append(adapter, adapter.handle, id, second, [
      stored(2, "released"),
    ]),
  )
  use read <- result.try(
    adapter.inspect.head(adapter.handle, id) |> result.map_error(store.describe),
  )
  expect(
    read == Some(second),
    "the replaced head came back as " <> string.inspect(read),
  )
}

fn waiting(adapter: Adapter(tx)) -> Result(Nil, String) {
  let point = fresh_id(adapter, "point")
  let ana = Subject("person", fresh_id(adapter, "ana"))
  let other = Subject("person", fresh_id(adapter, "other"))
  let with = fn(status, subject, point) {
    Head(..head(adapter, point), status:, subject:)
  }
  // One record of the point about Ana in every status, written in an order
  // that is not the id order, plus one about someone else and one of
  // another point.
  let records =
    list.index_map(list.reverse(store.statuses), fn(status, index) {
      #(
        fresh_id(adapter, "w" <> int.to_string(100 - index)),
        with(status, ana, point),
      )
    })
  let elsewhere = [
    #(fresh_id(adapter, "w-other"), with(store.Awaiting, other, point)),
    #(
      fresh_id(adapter, "w-point"),
      with(store.Awaiting, ana, point <> ".other"),
    ),
  ]
  use Nil <- result.try(
    list.try_each(list.append(records, elsewhere), fn(pair) {
      append(adapter, adapter.handle, pair.0, pair.1, [stored(1, "recommended")])
    }),
  )
  use found <- result.try(
    adapter.port.waiting(adapter.handle, point, ana)
    |> result.map_error(store.describe),
  )
  let expected =
    records
    |> list.filter(fn(pair) { store.is_waiting({ pair.1 }.status) })
    |> list.map(fn(pair) { pair.0 })
    |> list.sort(string.compare)
  expect(found == expected, "waiting returned " <> string.inspect(found))
}

fn wakes_replaced(adapter: Adapter(tx)) -> Result(Nil, String) {
  let id = fresh_id(adapter, "wakes")
  let neighbour = fresh_id(adapter, "neighbour")
  let mine = fn() {
    adapter.inspect.wakes(adapter.handle)
    |> result.map_error(store.describe)
    |> result.map(fn(wakes) {
      list.filter_map(wakes, fn(wake) {
        case wake.occurrence == id && wake.point == "p" {
          True -> Ok(wake.at)
          False -> Error(Nil)
        }
      })
      |> list.sort(timestamp.compare)
    })
  }
  let schedule = fn(id, times) {
    adapter.port.schedule(adapter.handle, "p", id, times)
    |> result.map_error(store.describe)
  }
  // The clock moves on every read, so every expected time is computed
  // once, from one reading.
  let base = at(adapter, 0)
  let #(t30, t60, t90, t120) = #(
    plus(base, 30),
    plus(base, 60),
    plus(base, 90),
    plus(base, 120),
  )
  use Nil <- result.try(schedule(neighbour, [t30]))
  use Nil <- result.try(schedule(id, [t60, t120]))
  use found <- result.try(mine())
  use Nil <- result.try(expect(
    found == [t60, t120],
    "scheduled two, found " <> string.inspect(found),
  ))
  use Nil <- result.try(schedule(id, [t90]))
  use found <- result.try(mine())
  use Nil <- result.try(expect(
    found == [t90],
    "replaced with one, found " <> string.inspect(found),
  ))
  use Nil <- result.try(schedule(id, []))
  use found <- result.try(mine())
  use Nil <- result.try(expect(
    found == [],
    "cancelled, found " <> string.inspect(found),
  ))
  use all <- result.try(
    adapter.inspect.wakes(adapter.handle) |> result.map_error(store.describe),
  )
  expect(
    list.any(all, fn(wake) { wake.occurrence == neighbour }),
    "cancelling one occurrence's wake-ups removed another's",
  )
}

fn notices(adapter: Adapter(tx)) -> Result(Nil, String) {
  let first = fresh_id(adapter, "settled")
  let second = fresh_id(adapter, "settled")
  use Nil <- result.try(
    adapter.port.settled(adapter.handle, "p", first)
    |> result.map_error(store.describe),
  )
  use Nil <- result.try(
    adapter.port.settled(adapter.handle, "q", second)
    |> result.map_error(store.describe),
  )
  use all <- result.try(
    adapter.inspect.notices(adapter.handle) |> result.map_error(store.describe),
  )
  let mine =
    list.filter(all, fn(notice) {
      notice.occurrence == first || notice.occurrence == second
    })
  expect(
    mine == [Notice("p", first), Notice("q", second)],
    "notices came back as " <> string.inspect(mine),
  )
}

fn unique_ids(adapter: Adapter(tx)) -> Result(Nil, String) {
  let ids =
    list.repeat(Nil, 200)
    |> list.map(fn(_) { adapter.port.new_id(adapter.handle) })
  expect(set.size(set.from_list(ids)) == 200, "new_id repeated an id")
}

// -- Desk checks ------------------------------------------------------------------------

fn desk_invariants(adapter: Adapter(tx)) -> Result(Nil, String) {
  let #(desk, name) = conformance_desk(adapter, ask(), None, None)
  let bia = Validator("bia", ["finance"])
  let key = fresh_id(adapter, "key")
  use Nil <- result.try(
    adapter.transaction(fn(tx) {
      decisions.recommend_once(desk, tx, key:, proposal: proposal(name))
      |> result.replace(Nil)
      |> result.map_error(decisions.describe)
    }),
  )
  // The same key again finds what the first admission made.
  use Nil <- result.try(
    adapter.transaction(fn(tx) {
      decisions.recommend_once(desk, tx, key:, proposal: proposal(name))
      |> result.replace(Nil)
      |> result.map_error(decisions.describe)
    }),
  )
  use Nil <- result.try(
    adapter.transaction(fn(tx) {
      {
        use card <- result.try(
          decisions.open(desk, tx, occurrence: key, by: bia, latest: fn(ref) {
            ref.revision
          }),
        )
        decisions.decide(desk, tx, card, Approve)
      }
      |> result.replace(Nil)
      |> result.map_error(decisions.describe)
    }),
  )
  use known <- result.try(
    decisions.read(desk, adapter.handle, occurrence: key)
    |> result.map_error(decisions.describe),
  )
  use Nil <- result.try(case known.status {
    occurrence.Released(..) -> Ok(Nil)
    other -> Error("the occurrence ended " <> occurrence.status_name(other))
  })
  invariants(adapter, desk)
}

fn refused_release(adapter: Adapter(tx)) -> Result(Nil, String) {
  let side = fresh_id(adapter, "side")
  // A tool that writes, then refuses: what it wrote must not survive.
  let tool = fn(tx) {
    use Nil <- result.try(
      append(adapter, tx, side, head(adapter, "side"), [
        stored(1, "recommended"),
      ])
      |> result.map_error(decisions.Unsure),
    )
    Error(decisions.Refuse("the registry refuses"))
  }
  let #(desk, name) = conformance_desk(adapter, proceed(), None, Some(tool))
  let key = fresh_id(adapter, "key")
  use Nil <- result.try(
    adapter.transaction(fn(tx) {
      decisions.recommend_once(desk, tx, key:, proposal: proposal(name))
      |> result.replace(Nil)
      |> result.map_error(decisions.describe)
    }),
  )
  use known <- result.try(
    decisions.read(desk, adapter.handle, occurrence: key)
    |> result.map_error(decisions.describe),
  )
  use found <- result.try(load(adapter, adapter.handle, side))
  use Nil <- result.try(expect(
    known.status == occurrence.Refused("the registry refuses") && found == [],
    "the occurrence ended "
      <> occurrence.status_name(known.status)
      <> " and the tool's write "
      <> case found {
      [] -> "is gone"
      _ -> "survived"
    },
  ))
  invariants(adapter, desk)
}

fn early_wake(adapter: Adapter(tx)) -> Result(Nil, String) {
  let #(desk, name) =
    conformance_desk(adapter, proceed(), Some(duration.hours(1)), None)
  let key = fresh_id(adapter, "key")
  use Nil <- result.try(
    adapter.transaction(fn(tx) {
      decisions.recommend_once(desk, tx, key:, proposal: proposal(name))
      |> result.replace(Nil)
      |> result.map_error(decisions.describe)
    }),
  )
  use known <- result.try(
    decisions.read(desk, adapter.handle, occurrence: key)
    |> result.map_error(decisions.describe),
  )
  use until <- result.try(case known.status {
    occurrence.Held(until:, ..) -> Ok(until)
    other -> Error("expected held, found " <> occurrence.status_name(other))
  })
  use woken <- result.try(
    decisions.wake(desk, adapter.handle, occurrence: key)
    |> result.map_error(decisions.describe),
  )
  use Nil <- result.try(expect(
    woken == decisions.NotDue(until),
    "an early wake-up returned " <> string.inspect(woken),
  ))
  use pending <- result.try(
    adapter.inspect.wakes(adapter.handle) |> result.map_error(store.describe),
  )
  use Nil <- result.try(expect(
    list.any(pending, fn(wake) { wake.occurrence == key && wake.at == until }),
    "the hold's end was not scheduled",
  ))
  use Nil <- result.try(
    adapter.transaction(fn(tx) {
      decisions.withdraw(desk, tx, occurrence: key, by: "caio")
      |> result.replace(Nil)
      |> result.map_error(decisions.describe)
    }),
  )
  invariants(adapter, desk)
}

fn desk_wakes(adapter: Adapter(tx)) -> Result(Nil, String) {
  let name = fresh_id(adapter, "conformance.point")
  let escalating =
    Policy(
      version: 1,
      rules: [
        policy.When(
          policy.waited(240),
          Ask(
            policy.Either([AnyoneHolding("finance"), AnyoneHolding("managers")]),
          ),
        ),
      ],
      otherwise: Ask(AnyoneHolding("finance")),
    )
  let desk =
    decisions.desk(
      decisions.point(name, wire.text())
        |> decisions.valid_for(duration.hours(24)),
      drives: fn(_) {
        Gated(
          name: "conformance_tool",
          guard: fn(_, _) { Ok([]) },
          execute: fn(_, _) { Ok(Nil) },
        )
      },
      under: fn(_) { Ok(escalating) },
      over: adapter.port,
    )
  let key = fresh_id(adapter, "key")
  use Nil <- result.try(
    adapter.transaction(fn(tx) {
      decisions.recommend_once(desk, tx, key:, proposal: proposal(name))
      |> result.replace(Nil)
      |> result.map_error(decisions.describe)
    }),
  )
  use known <- result.try(
    decisions.read(desk, adapter.handle, occurrence: key)
    |> result.map_error(decisions.describe),
  )
  let mine = fn() {
    adapter.inspect.wakes(adapter.handle)
    |> result.map_error(store.describe)
    |> result.map(fn(wakes) {
      list.filter_map(wakes, fn(wake) {
        case wake.occurrence == key && wake.point == name {
          True -> Ok(wake.at)
          False -> Error(Nil)
        }
      })
      |> list.sort(timestamp.compare)
    })
  }
  use pending <- result.try(mine())
  use Nil <- result.try(expect(
    pending == occurrence.wake_times(known) && list.length(pending) == 2,
    "the escalation and the deadline were scheduled as "
      <> string.inspect(pending),
  ))
  use Nil <- result.try(
    adapter.transaction(fn(tx) {
      {
        use card <- result.try(
          decisions.open(
            desk,
            tx,
            occurrence: key,
            by: Validator("bia", ["finance"]),
            latest: fn(ref) { ref.revision },
          ),
        )
        decisions.decide(desk, tx, card, Approve)
      }
      |> result.replace(Nil)
      |> result.map_error(decisions.describe)
    }),
  )
  use pending <- result.try(mine())
  use Nil <- result.try(expect(
    pending == [],
    "settling left wake-ups " <> string.inspect(pending),
  ))
  invariants(adapter, desk)
}

fn invariants(
  adapter: Adapter(tx),
  desk: Desk(String, tx),
) -> Result(Nil, String) {
  testing.check(adapter.handle, adapter.inspect, [testing.audit_record(desk)])
  |> result.replace(Nil)
  |> result.map_error(string.inspect)
}

fn conformance_desk(
  adapter: Adapter(tx),
  policy: policy.Policy,
  hold: option.Option(duration.Duration),
  tool: option.Option(fn(tx) -> Result(Nil, decisions.Stop)),
) -> #(Desk(String, tx), String) {
  let name = fresh_id(adapter, "conformance.point")
  let point = decisions.point(name, wire.text())
  let point = case hold {
    Some(hold) -> decisions.with_hold(point, hold)
    None -> point
  }
  let desk =
    decisions.desk(
      point,
      drives: fn(_) {
        Gated(
          name: "conformance_tool",
          guard: fn(_, _) { Ok([]) },
          execute: fn(tx, _) {
            case tool {
              None -> Ok(Nil)
              Some(write) -> write(tx)
            }
          },
        )
      },
      under: fn(_) { Ok(policy) },
      over: adapter.port,
    )
  #(desk, name)
}

fn ask() -> policy.Policy {
  Policy(version: 1, rules: [], otherwise: Ask(AnyoneHolding("finance")))
}

fn proceed() -> policy.Policy {
  Policy(
    version: 1,
    rules: [policy.When(policy.OwnAct, Proceed(Never))],
    otherwise: Proceed(Never),
  )
}

fn proposal(name: String) -> decisions.Proposal(String) {
  decisions.proposal(
    trigger: Trigger("conformance", name),
    about: Subject("company", "clinica-x"),
    context: Manifest(refs: [Ref("message", "m1", "1")], renderer: "test-1"),
    recommending: Recommendation(
      output: "approve the refund",
      by: Person("caio"),
      explanation: OwnAct,
      signals: [],
      reads: [],
    ),
  )
}

// -- Helpers ---------------------------------------------------------------------------

fn fresh_id(adapter: Adapter(tx), prefix: String) -> String {
  prefix
  <> "-"
  <> adapter.port.new_id(adapter.handle)
  <> "-"
  <> model.digest(prefix)
}

/// `base` plus whole seconds.
fn plus(base: Timestamp, seconds: Int) -> Timestamp {
  timestamp.add(base, duration.seconds(seconds))
}

/// The adapter's clock now, plus whole seconds, at millisecond precision.
/// Each call reads the clock again: call it once per expected value.
fn at(adapter: Adapter(tx), seconds: Int) -> Timestamp {
  adapter.port.now(adapter.handle)
  |> timestamp.add(duration.seconds(seconds))
  |> wire.milliseconds
  |> wire.from_milliseconds
}

fn head(adapter: Adapter(tx), point: String) -> Head {
  Head(
    point:,
    subject: Subject("company", "clinica-x"),
    status: store.Recommended,
    awaiting: [],
    due: None,
    arrived: at(adapter, 0),
    approved: [],
    may_not_decide: [],
    review_pending: False,
  )
}

fn stored(seq: Int, kind: String) -> Stored {
  Stored(
    seq:,
    at: wire.from_milliseconds(1_800_000_000_000 + seq * 1000),
    kind:,
    event: "{\"seq\":" <> int.to_string(seq) <> "}",
  )
}

fn load(
  adapter: Adapter(tx),
  tx: tx,
  id: String,
) -> Result(List(Stored), String) {
  adapter.port.load(tx, id) |> result.map_error(store.describe)
}

fn append(
  adapter: Adapter(tx),
  tx: tx,
  id: String,
  head: Head,
  entries: List(Stored),
) -> Result(Nil, String) {
  adapter.port.append(tx, id, head, entries) |> result.map_error(store.describe)
}

fn refused(
  written: Result(Nil, store.StoreError),
  what: String,
) -> Result(Nil, String) {
  case written {
    Error(Conflict(_)) -> Ok(Nil)
    Error(error) -> Error(what <> " failed as " <> store.describe(error))
    Ok(Nil) -> Error(what <> " was accepted")
  }
}

fn expect(holds: Bool, otherwise: String) -> Result(Nil, String) {
  case holds {
    True -> Ok(Nil)
    False -> Error(otherwise)
  }
}

/// Every check's name, for an adapter's report.
pub fn names() -> List(String) {
  list.map(checks(), fn(check) { check.name })
}
