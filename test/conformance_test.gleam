//// The in-memory store passes the storage port's conformance suite, and
//// the suite catches a broken adapter for every clause it claims to check.

import decisions
import decisions/conformance.{type Adapter}
import decisions/memory.{type Memory}
import decisions/store.{Conflict, Stored}
import decisions/vocabulary
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import support/world

fn fresh(change: fn(Adapter(Memory)) -> Adapter(Memory)) {
  fn() {
    let db = memory.new()
    memory.set_clock(db, world.t0())
    Ok(change(world.adapter(db)))
  }
}

fn failed(change: fn(Adapter(Memory)) -> Adapter(Memory)) -> List(String) {
  case conformance.run(fresh(change)) {
    Ok(Nil) -> []
    Error(unmet) ->
      list.map(unmet, fn(one) {
        case one {
          conformance.CheckFailed(check:, ..) -> check
          conformance.SetupFailed(reason:) -> reason
        }
      })
  }
}

fn port(
  change: fn(store.Port(Memory)) -> store.Port(Memory),
) -> fn(Adapter(Memory)) -> Adapter(Memory) {
  fn(adapter: Adapter(Memory)) {
    conformance.Adapter(..adapter, port: change(adapter.port))
  }
}

pub fn the_memory_store_conforms_test() {
  assert failed(fn(adapter) { adapter }) == []
}

/// The suite assumes nothing about the clock between two reads: an
/// adapter whose clock advances on every read passes.
pub fn a_clock_that_moves_on_every_read_passes_test() {
  assert failed(
      port(fn(p) {
        store.Port(..p, now: fn(tx) {
          memory.set_clock(
            tx,
            timestamp.add(memory.now(tx), duration.milliseconds(7)),
          )
          memory.now(tx)
        })
      }),
    )
    == []
}

/// For every clause, an adapter broken in that clause alone fails the
/// check that names it.
pub fn each_check_catches_its_broken_adapter_test() {
  let fake = Stored(seq: 1, at: world.t0(), kind: "recommended", event: "{}")
  let lenient =
    port(fn(p) {
      store.Port(..p, append: fn(tx, id, head, entries) {
        case p.append(tx, id, head, entries) {
          Error(Conflict(_)) -> Ok(Nil)
          other -> other
        }
      })
    })
  let no_savepoint =
    port(fn(p) { store.Port(..p, atomically: fn(tx, body) { Ok(body(tx)) }) })
  let broken = [
    #(
      "an absent id loads empty",
      port(fn(p) {
        store.Port(..p, load: fn(tx, id) {
          case p.load(tx, id) {
            Ok([]) -> Ok([fake])
            other -> other
          }
        })
      }),
    ),
    #("an absent id takes its first entry once", lenient),
    #(
      "entries come back in order and unchanged",
      port(fn(p) {
        store.Port(..p, load: fn(tx, id) {
          case p.load(tx, id) {
            Ok(entries) -> Ok(list.reverse(entries))
            other -> other
          }
        })
      }),
    ),
    #("a repeated sequence number is refused", lenient),
    #("a gap in sequence numbers is refused", lenient),
    #("a second release is refused", lenient),
    #("a rolled-back transaction leaves nothing", fn(adapter: Adapter(Memory)) {
      conformance.Adapter(..adapter, transaction: fn(body) {
        body(adapter.handle)
      })
    }),
    #("a savepoint rolls back alone", no_savepoint),
    #(
      "a savepoint keeps what succeeded",
      port(fn(p) {
        store.Port(..p, atomically: fn(tx, body) {
          // Everything the body wrote is undone, whatever it returned.
          case memory.transaction(tx, fn(t) { Error(body(t)) }) {
            Error(ran) -> Ok(ran)
            Ok(ran) -> Ok(ran)
          }
        })
      }),
    ),
    #("a savepoint whose body raises rolls back alone", no_savepoint),
    #(
      "a savepoint inside a rolled-back transaction leaves nothing",
      fn(adapter: Adapter(Memory)) {
        conformance.Adapter(..adapter, transaction: fn(body) {
          body(adapter.handle)
        })
      },
    ),
    #(
      "the head comes back as written",
      port(fn(p) {
        store.Port(..p, append: fn(tx, id, head, entries) {
          p.append(tx, id, store.Head(..head, approved: []), entries)
        })
      }),
    ),
    #(
      "a pending head keeps its due time and its wake-up",
      port(fn(p) {
        store.Port(..p, append: fn(tx, id, head: store.Head, entries) {
          // An adapter that keeps a due time only for an occurrence.
          let head = case head.status {
            store.Pending -> store.Head(..head, due: option.None)
            _ -> head
          }
          p.append(tx, id, head, entries)
        })
      }),
    ),
    #(
      "waiting filters by point, subject and status, in id order",
      port(fn(p) {
        store.Port(..p, waiting: fn(tx, point, subject) {
          memory.heads(tx)
          |> list.filter(fn(pair) {
            { pair.1 }.point == point
            && { pair.1 }.subject == subject
            && { pair.1 }.status != store.Released
          })
          |> list.map(fn(pair) { pair.0 })
          |> list.sort(string.compare)
          |> Ok
        })
      }),
    ),
    #(
      "wake-ups are replaced and cancelled",
      port(fn(p) {
        store.Port(..p, schedule: fn(tx, point, id, at) {
          case at {
            [] -> Ok(Nil)
            _ -> p.schedule(tx, point, id, at)
          }
        })
      }),
    ),
    #(
      "settlement notices are admitted in order",
      port(fn(p) { store.Port(..p, settled: fn(_, _, _) { Ok(Nil) }) }),
    ),
    #(
      "new ids are unique",
      port(fn(p) { store.Port(..p, new_id: fn(_) { "occ-1" }) }),
    ),
    #(
      "a desk keeps every invariant over the adapter",
      port(fn(p) {
        store.Port(..p, settled: fn(tx, point, id) {
          let _ = p.settled(tx, point, id)
          p.settled(tx, point, id)
        })
      }),
    ),
    #("a refused release leaves nothing behind", no_savepoint),
    #(
      "a wake-up that is early says when to come back",
      port(fn(p) { store.Port(..p, schedule: fn(_, _, _, _) { Ok(Nil) }) }),
    ),
    #(
      "a desk schedules its deadline and policy steps and cancels them",
      port(fn(p) {
        store.Port(..p, schedule: fn(tx, point, id, at) {
          p.schedule(tx, point, id, list.take(at, 1))
        })
      }),
    ),
    #(
      "a subject lock stores nothing and orders two admissions",
      port(fn(p) {
        // Loading an id with no entry creates a row for it.
        store.Port(..p, load: fn(tx, id) {
          case p.load(tx, id) {
            Ok([]) ->
              case string.starts_with(id, decisions.subject_lock_prefix) {
                True -> {
                  let assert Ok(Nil) =
                    p.append(
                      tx,
                      id,
                      store.Head(
                        point: "",
                        subject: vocabulary.Subject("", ""),
                        status: store.Pending,
                        awaiting: [],
                        due: option.None,
                        arrived: world.t0(),
                        approved: [],
                        may_not_decide: [],
                        review_pending: False,
                        bundle: option.None,
                      ),
                      [fake],
                    )
                  Ok([])
                }
                False -> Ok([])
              }
            other -> other
          }
        })
      }),
    ),
    #(
      "members returns a bundle's records of every point, in id order",
      port(fn(p) {
        // An adapter that returns a bundle's members in the order written.
        store.Port(..p, members: fn(tx, bundle) {
          p.members(tx, bundle) |> result.map(list.reverse)
        })
      }),
    ),
    #(
      "a desk admits a bundle and tells when it is complete",
      port(fn(p) {
        // An adapter that sees only the first member of a bundle.
        store.Port(..p, members: fn(tx, bundle) {
          p.members(tx, bundle) |> result.map(list.take(_, 1))
        })
      }),
    ),
  ]
  // Every check has a broken adapter here.
  assert list.sort(list.map(broken, fn(pair) { pair.0 }), string.compare)
    == list.sort(conformance.names(), string.compare)
  list.each(broken, fn(pair) {
    let #(check, change) = pair
    let failing = failed(change)
    case list.contains(failing, check) {
      True -> Nil
      False ->
        panic as {
          "the check \""
          <> check
          <> "\" passed a broken adapter; failing: "
          <> string.inspect(failing)
        }
    }
  })
}
