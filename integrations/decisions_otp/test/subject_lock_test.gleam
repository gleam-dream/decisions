//// The core's subject lock over the process-safe store: it stores
//// nothing, the shared admissions scenario needs it, and a `happened`
//// waiting on it is part of the deadlock detection.

import decisions
import decisions/conformance
import decisions/store as port_types
import decisions/vocabulary.{Subject, Trigger}
import decisions_otp/store
import decisions_otp/stress
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import gleam/time/duration
import support/lab

/// Loading a lock id locks it until the transaction ends and leaves
/// nothing: no entries, no head, nothing in `waiting`, the queues, the
/// pages, the inspection or a restart.
pub fn a_lock_id_holds_nothing_test() {
  let s = lab.start()
  let about = Subject("person", "ana")
  let lock = decisions.subject_lock(point: "p", subject: about)
  let holding = process.new_subject()
  let go = process.new_subject()
  process.spawn(fn() {
    let gate = process.new_subject()
    process.send(go, gate)
    let assert Ok(Nil) =
      store.transaction(s, fn(tx) {
        let assert Ok([]) = store.port().load(tx, lock)
        process.send(holding, Nil)
        let assert Ok(Nil) = process.receive(gate, 5000)
        Ok(Nil)
      })
  })
  let assert Ok(gate) = process.receive(go, 1000)
  let assert Ok(Nil) = process.receive(holding, 1000)
  // Held: a second transaction asking for the id waits.
  let waited = process.new_subject()
  process.spawn(fn() {
    process.send(waited, 0)
    let assert Ok([]) = store.port().load(store.handle(s), lock)
    process.send(waited, monotonic_us())
  })
  // Seen positively: the second load started before the release and
  // returned after it.
  let assert Ok(0) = process.receive(waited, 5000)
  let released = monotonic_us()
  process.send(gate, Nil)
  let assert Ok(loaded) = process.receive(waited, 5000)
  assert loaded >= released
  let handle = store.handle(s)
  assert store.entries(handle, lock) == []
  assert store.heads(handle) == []
  assert store.port().waiting(handle, "p", about) == Ok([])
  assert store.queue(handle, "finance") == []
  assert store.occurrences_of(handle, "p", after: None, limit: 10).ids == []
  assert store.inspection().head(handle, lock) == Ok(None)
  let assert Ok(again) = store.restart(s, lab.config())
  assert store.heads(store.handle(again)) == []
}

@external(erlang, "decisions_otp_ffi", "monotonic_us")
fn monotonic_us() -> Int

/// The shared scenario fails against a store whose `load` does not lock
/// an id with no entries: the admissions then miss each other and more
/// than one key is left pending.
pub fn the_admissions_scenario_needs_the_subject_lock_test() {
  let assert [scenario] =
    list.filter(stress.scenarios(), fn(scenario) {
      string.starts_with(scenario.name, "concurrent admissions")
    })
  let broken = fn() {
    use target <- result.try(stress.in_memory(lab.config()))
    let port = target.adapter.port
    // Lock ids are loaded in a transaction of their own, so the caller's
    // transaction holds no lock on them.
    let unlocked =
      port_types.Port(..port, load: fn(tx, id) {
        case string.starts_with(id, "decisions.subject-lock:") {
          True -> port.load(store.handle(store.store_of(tx)), id)
          False -> port.load(tx, id)
        }
      })
    Ok(
      stress.Target(
        ..target,
        adapter: conformance.Adapter(..target.adapter, port: unlocked),
      ),
    )
  }
  let outcome = stress.run_scenario(scenario, broken, stress.default_load())
  let assert Error(stress.Failed(saw:, ..)) = outcome
  assert string.starts_with(saw, "pending after the admissions")
}

/// `expect`-then-`happened` against `happened` alone: a transaction holds
/// a record and wants the subject lock while another holds the subject
/// lock and wants the record. The deadlock detection refuses one with
/// `Contended`; the other commits; neither hangs.
pub fn expect_then_happened_is_a_detected_deadlock_test() {
  lab.quiet()
  let assert Ok(s) =
    store.start(
      store.Config(..lab.config(), lock_timeout: duration.seconds(30)),
    )
  let desk = lab.desk(lab.point("lock.order", None), lab.asking("finance"))
  let about = Subject("person", "ana")
  // A waiting record about the subject, which `happened` will lock.
  let assert Ok(Nil) =
    store.transaction(s, decisions.expect(
      desk,
      _,
      key: "a",
      trigger: Trigger("lab", "a"),
      about:,
    ))
  let ended = process.new_subject()
  let holds_record = process.new_subject()
  // The first: locks record "a" (as `expect` of that key does), then
  // calls `happened` and so wants the subject lock.
  process.spawn(fn() {
    let gate = process.new_subject()
    process.send(holds_record, gate)
    let outcome =
      store.transaction(s, fn(tx) {
        use _ <- result.try(decisions.expect(
          desk,
          tx,
          key: "a",
          trigger: Trigger("lab", "a"),
          about:,
        ))
        let _ = process.receive(gate, 5000)
        decisions.happened(desk, tx, "superseded", about:)
        |> result.replace(Nil)
      })
    process.send(ended, #("expect then happened", outcome))
  })
  let assert Ok(gate) = process.receive(holds_record, 1000)
  // The second: `happened` alone takes the subject lock, then wants "a".
  // Its port says when it holds the subject lock.
  let has_subject = process.new_subject()
  let port = store.port()
  let watched =
    decisions.desk(
      decisions.point_of(desk),
      drives: fn(_) {
        decisions.Gated(
          name: "none",
          guard: fn(_, _) { Ok([]) },
          execute: fn(_, _) { Ok(Nil) },
        )
      },
      under: fn(_) { Ok(lab.asking("finance")) },
      over: port_types.Port(..port, load: fn(tx, id) {
        let loaded = port.load(tx, id)
        case string.starts_with(id, "decisions.subject-lock:") {
          True -> process.send(has_subject, Nil)
          False -> Nil
        }
        loaded
      }),
    )
  process.spawn(fn() {
    let outcome =
      store.transaction(s, fn(tx) {
        decisions.happened(watched, tx, "superseded", about:)
        |> result.replace(Nil)
      })
    process.send(ended, #("happened", outcome))
  })
  // Seen positively: the second holds the subject lock before the first,
  // which holds "a", asks for it.
  let assert Ok(Nil) = process.receive(has_subject, 5000)
  process.send(gate, Nil)
  let assert Ok(#(_, first)) = process.receive(ended, 10_000)
  let assert Ok(#(_, second)) = process.receive(ended, 10_000)
  let contended = fn(outcome) {
    case outcome {
      Error(decisions.StoreFailed(port_types.Contended(detail))) ->
        string.starts_with(detail, "deadlock")
      _ -> False
    }
  }
  assert list.count([first, second], contended) == 1
  assert list.count([first, second], result.is_ok) == 1
}
