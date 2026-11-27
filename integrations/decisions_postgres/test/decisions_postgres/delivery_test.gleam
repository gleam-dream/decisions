//// Wake-ups and settlement notices delivered by Grind: a hold ends and is
//// released, a cancelled wake-up does nothing when its job arrives, a
//// notice reaches what follows once however often its job is delivered,
//// and a poisoned record is set aside without blocking the queue.

import decisions
import decisions/fact
import decisions/occurrence
import decisions/policy
import decisions/store.{Head, Stored}
import decisions/vocabulary.{Approve}
import decisions_postgres
import decisions_postgres/queue
import decisions_postgres/telemetry
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import grind/testing as grind_testing
import grind/worker
import kit
import pog
import sinal
import support/policies

pub fn a_hold_ends_and_grind_releases_it_test() {
  let #(name, store) = kit.store()
  let spec =
    kit.Spec(
      ..kit.spec("held"),
      policy: kit.proceed(),
      hold: Some(duration.milliseconds(200)),
    )
  let desk = kit.desk(store, spec)
  let delivered = process.new_subject()
  let watch =
    sinal.observe(telemetry.wake_delivered(), fn(_, wake) {
      case wake.point == spec.name {
        True -> process.send(delivered, wake)
        False -> Nil
      }
    })
  use env <- kit.run(name, store, kit.delivering(), [decisions.waker(desk)], [])
  let assert Ok(held) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert Ok(wake) = process.receive(delivered, 10_000)
  let _ = sinal.detach(watch)
  assert wake.occurrence == held.id
  assert wake.lag_ms >= 0
  let assert Ok(known) =
    kit.tx(env, decisions.read(desk, _, occurrence: held.id))
  let assert occurrence.Released(..) = known.status
  assert kit.effects_of(env.db, held.id) == 1
  let assert Ok(wakes) = decisions_postgres.inspection().wakes(env.db)
  assert !list.any(wakes, fn(w) { w.occurrence == held.id })
  kit.check(env, [desk])
}

/// `schedule` leaves a wake-up that was already delivered alone: after
/// the hold's job delivered it, scheduling the occurrence again adds a new
/// wake-up with a job of its own, and the delivered one is neither
/// revived nor delivered again.
pub fn schedule_leaves_a_delivered_wake_up_alone_test() {
  let #(name, store) = kit.store()
  let spec =
    kit.Spec(
      ..kit.spec("delivered"),
      policy: kit.proceed(),
      hold: Some(duration.milliseconds(100)),
    )
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.delivering(), [decisions.waker(desk)], [])
  let assert Ok(held) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert True =
    kit.eventually(10_000, fn() {
      kit.jobs(env, "decisions.wake") == [#("succeeded", 1)]
    })
  let port = decisions_postgres.port(store)
  let later = timestamp.add(port.now(env.db), duration.hours(1))
  let assert Ok(Nil) = port.schedule(env.db, spec.name, held.id, [later])
  let assert Ok(wakes) = decisions_postgres.inspection().wakes(env.db)
  assert list.filter(wakes, fn(w) { w.occurrence == held.id })
    == [store.Wake(point: spec.name, occurrence: held.id, at: later)]
  // The later wake-up is a new job, scheduled an hour away; the delivered
  // one stays as it was.
  let assert [#("succeeded", 1), #("scheduled", 0)] =
    kit.jobs(env, "decisions.wake")
  assert kit.effects_of(env.db, held.id) == 1
  // Cancelling removes only the pending one.
  let assert Ok(Nil) = port.schedule(env.db, spec.name, held.id, [])
  let assert Ok(wakes) = decisions_postgres.inspection().wakes(env.db)
  assert !list.any(wakes, fn(w) { w.occurrence == held.id })
  kit.check(env, [desk])
}

/// Withdrawing cancels the hold's wake-up in the store's own table. Grind
/// cannot cancel the job, so the job arrives, finds nothing pending, and
/// does nothing.
pub fn a_cancelled_wake_up_does_nothing_when_its_job_arrives_test() {
  let #(name, store) = kit.store()
  let spec =
    kit.Spec(
      ..kit.spec("withdrawn"),
      policy: kit.proceed(),
      hold: Some(duration.milliseconds(400)),
    )
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.delivering(), [decisions.waker(desk)], [])
  let assert Ok(held) =
    kit.tx(env, decisions.recommend(
      desk,
      _,
      kit.own_act(spec.name, by: "caio", about: kit.ana),
    ))
  let assert Ok(_) =
    kit.tx(env, decisions.withdraw(desk, _, occurrence: held.id, by: "caio"))
  let assert True =
    kit.eventually(10_000, fn() {
      kit.jobs(env, "decisions.wake") == [#("succeeded", 1)]
    })
  assert kit.effects_of(env.db, held.id) == 0
  let assert Ok(known) =
    kit.tx(env, decisions.read(desk, _, occurrence: held.id))
  let assert occurrence.Withdrawn(_) = known.status
  kit.check(env, [desk])
}

/// A follower runs once per notice: in the transaction that marks the
/// notice delivered. The same job delivered again (as after a worker lost
/// between its commit and Grind's acknowledgement) does nothing.
pub fn a_settlement_reaches_its_follower_once_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("followed"), policy: kit.proceed())
  let store = decisions_postgres.following(store, spec.name)
  let desk = kit.desk(store, spec)
  let follower = #(spec.name, fn(tx, id) {
    pog.query(
      "INSERT INTO test_effects (point, occurrence, key) VALUES ($1, $2, 'followed')",
    )
    |> pog.parameter(pog.text("follow:" <> spec.name))
    |> pog.parameter(pog.text(id))
    |> pog.execute(tx)
    |> result.replace(Nil)
    |> result.map_error(fn(_) { decisions.ApplicationFailed("insert failed") })
  })
  use env <- kit.run(name, store, kit.delivering(), [], [follower])
  let assert Ok(released) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert True =
    kit.eventually(10_000, fn() {
      kit.effects(env.db, "follow:" <> spec.name) == 1
    })
  // The job again, by hand, with the runtime's pool.
  let worker = decisions_postgres.settlement_worker(store, [follower])
  let notice =
    kit.scalar(
      env.db,
      "SELECT id FROM decisions_settled WHERE occurrence_id = $1",
      [pog.text(released.id)],
      decode.int,
    )
  let context =
    grind_testing.context(job_id: 1, attempt: 1)
    |> grind_testing.with_connection(env.db)
  let assert Ok(worker.Succeeded("delivered before")) =
    grind_testing.perform_with(
      worker,
      context,
      decisions_postgres.NoticeJob(
        notice:,
        point: spec.name,
        occurrence: released.id,
      ),
    )
  assert kit.effects(env.db, "follow:" <> spec.name) == 1
  kit.check(env, [desk])
}

/// A follower whose store is contended is delivered again later, and the
/// notice is not set aside: a transient failure counts for nothing.
pub fn a_follower_that_meets_contention_is_delivered_again_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("contended_follower"), policy: kit.proceed())
  let store = decisions_postgres.following(store, spec.name)
  let desk = kit.desk(store, spec)
  let follower = #(spec.name, fn(tx, id) {
    case kit.once("contended:" <> id) {
      True ->
        Error(
          decisions.DeskRefused(
            decisions.StoreFailed(store.Contended("40P01 deadlock")),
          ),
        )
      False ->
        pog.query(
          "INSERT INTO test_effects (point, occurrence, key) VALUES ($1, $2, 'followed')",
        )
        |> pog.parameter(pog.text("follow:" <> spec.name))
        |> pog.parameter(pog.text(id))
        |> pog.execute(tx)
        |> result.replace(Nil)
        |> result.map_error(fn(_) {
          decisions.ApplicationFailed("insert failed")
        })
    }
  })
  use env <- kit.run(name, store, kit.delivering(), [], [follower])
  let assert Ok(released) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert True =
    kit.eventually(10_000, fn() {
      kit.effects(env.db, "follow:" <> spec.name) == 1
    })
  assert kit.scalar(
    env.db,
    "SELECT set_aside_at IS NULL AND delivered_at IS NOT NULL
       FROM decisions_settled WHERE occurrence_id = $1",
    [pog.text(released.id)],
    decode.bool,
  )
  kit.check(env, [desk])
}

/// A follower that finds a record it cannot read: the notice is set
/// aside at once, and the next settlement is still delivered.
pub fn a_notice_whose_follower_finds_poison_is_set_aside_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("bad_follower"), policy: kit.proceed())
  let store = decisions_postgres.following(store, spec.name)
  let desk = kit.desk(store, spec)
  let follower = #(spec.name, fn(_tx, _id) {
    Error(decisions.DeskRefused(decisions.Unreadable("downstream is broken")))
  })
  let aside = process.new_subject()
  let watch =
    sinal.observe(telemetry.set_aside(), fn(_, record) {
      case record.point == spec.name {
        True -> process.send(aside, record)
        False -> Nil
      }
    })
  use env <- kit.run(name, store, kit.delivering(), [], [follower])
  let assert Ok(released) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert Ok(record) = process.receive(aside, 10_000)
  let _ = sinal.detach(watch)
  assert record.kind == telemetry.Notice
  assert record.occurrence == released.id
  assert string.contains(
    kit.scalar(
      env.db,
      "SELECT set_aside_reason FROM decisions_settled WHERE occurrence_id = $1",
      [pog.text(released.id)],
      decode.string,
    ),
    "downstream is broken",
  )
  kit.check(env, [desk])
}

/// The application's own failure is counted and retried with backoff,
/// and the notice is set aside after the worker's last attempt, without
/// the application dressing its error as a store failure.
pub fn an_application_failure_is_counted_then_set_aside_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("app_failure"), policy: kit.proceed())
  let store =
    decisions_postgres.following(store, spec.name)
    |> decisions_postgres.with_settlement_attempts(3)
  let desk = kit.desk(store, spec)
  let follower = #(spec.name, fn(_tx, _id) {
    Error(decisions.ApplicationFailed("the mail server refused"))
  })
  let aside = process.new_subject()
  let watch =
    sinal.observe(telemetry.set_aside(), fn(_, record) {
      case record.point == spec.name {
        True -> process.send(aside, record)
        False -> Nil
      }
    })
  use env <- kit.run(name, store, kit.delivering(), [], [follower])
  let assert Ok(released) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert Ok(record) = process.receive(aside, 10_000)
  let _ = sinal.detach(watch)
  assert record.kind == telemetry.Notice
  assert record.occurrence == released.id
  assert record.source == decisions_postgres.default_name
  // Three attempts were made and counted by Grind before it was set aside.
  let assert True =
    kit.eventually(5000, fn() {
      case kit.jobs(env, "decisions.settlement") {
        [#("discarded", _)] -> True
        _ -> False
      }
    })
  let attempts =
    kit.scalar(
      env.db,
      "SELECT attempt_count FROM \"" <> env.schema <> "\".grind_jobs
       WHERE worker_id = 'decisions.settlement'",
      [],
      decode.int,
    )
  assert attempts == 3
  kit.check(env, [desk])
}

/// B6: one stored occurrence no longer decodes. Its wake-up is set aside
/// and so is the occurrence: it leaves the queue, and the other
/// occurrences of its point are still delivered and decided.
pub fn a_poisoned_occurrence_is_set_aside_and_blocks_nothing_test() {
  let #(name, store) = kit.store()
  let spec =
    kit.Spec(..kit.spec("poison"), validity: Some(duration.milliseconds(300)))
  let desk = kit.desk(store, spec)
  // The poisoned record is kept under a point of its own, so the checker
  // can audit every other occurrence: an unreadable one fails its audit.
  let poisoned = kit.Spec(..spec, name: kit.tag("poisoned"))
  let poisoned_desk = kit.desk(store, poisoned)
  let aside = process.new_subject()
  let watch =
    sinal.observe(telemetry.set_aside(), fn(_, record) {
      case record.point == poisoned.name {
        True -> process.send(aside, record.kind)
        False -> Nil
      }
    })
  use env <- kit.run(
    name,
    store,
    kit.delivering(),
    [decisions.waker(desk), decisions.waker(poisoned_desk)],
    [],
  )
  // A record whose recommendation is not this point's: written through the
  // port, which never parses an entry, as a record from an older codec
  // would be.
  let port = decisions_postgres.port(store)
  let bad = kit.tag("bad")
  let now = port.now(env.db)
  let soon = timestamp.add(now, duration.milliseconds(300))
  let assert Ok(Nil) =
    pog.transaction(env.db, fn(tx) {
      use Nil <- result.try(
        port.append(
          tx,
          bad,
          Head(
            point: poisoned.name,
            subject: kit.ana,
            status: store.Awaiting,
            awaiting: ["finance"],
            due: Some(soon),
            arrived: now,
            approved: [],
            may_not_decide: [],
            review_pending: False,
            bundle: option.None,
          ),
          [Stored(1, now, "recommended", "{\"not\":\"a recommendation\"}")],
        ),
      )
      port.schedule(tx, poisoned.name, bad, [soon])
    })
    |> result.map_error(fn(_) { Nil })
  let good =
    list.map(kit.int_range(3), fn(_) {
      let assert Ok(waiting) =
        kit.tx(env, decisions.recommend(
          desk,
          _,
          kit.proposal(spec.name, kit.ana),
        ))
      waiting.id
    })
  let bia = kit.finance(kit.tag("bia"))
  let assert Ok(page) = queue.page(env.db, for: bia, limit: 10, after: None)
  assert list.any(page, fn(card) { card.occurrence == bad })
  // The first good one is decided; the other two expire at their deadline.
  let assert [first, ..] = good
  let assert Ok(_) =
    kit.tx(env, kit.open_and_decide(desk, _, first, bia, Approve))
  let kinds = [
    process.receive(aside, 10_000),
    process.receive(aside, 10_000),
  ]
  let _ = sinal.detach(watch)
  assert list.sort(
      list.map(kinds, fn(kind) {
        let assert Ok(kind) = kind
        telemetry.kind_name(kind)
      }),
      string.compare,
    )
    == ["occurrence", "wake_up"]
  let assert True =
    kit.eventually(10_000, fn() {
      list.all(list.drop(good, 1), fn(id) {
        case kit.tx(env, decisions.read(desk, _, occurrence: id)) {
          Ok(known) ->
            case known.status {
              occurrence.Expired(_) -> True
              _ -> False
            }
          Error(_) -> False
        }
      })
    })
  let assert Ok(page) = queue.page(env.db, for: bia, limit: 10, after: None)
  assert !list.any(page, fn(card) { card.occurrence == bad })
  let assert Ok(set_aside) = queue.set_aside(env.db, limit: 100)
  assert list.any(set_aside, fn(record) { record.occurrence == bad })
  let assert Error(decisions_postgres.Refused(decisions.Unreadable(_))) =
    kit.tx(env, decisions.read(poisoned_desk, _, occurrence: bad))
  kit.check(env, [desk])
}

/// An escalation 30 minutes away, a restart, and a store whose clock is an
/// hour ahead: `deliver_due` delivers the escalation once through the
/// worker's code path, and the job that Grind delivers later finds nothing
/// pending and does nothing.
pub fn deliver_due_delivers_an_escalation_once_after_a_restart_test() {
  let escalating =
    policies.checked(
      version: 1,
      rules: [
        policy.When(
          policy.AtLeast(fact.name(fact.waited_minutes()), 30.0),
          policy.Ask(policy.AnyoneHolding("managers")),
        ),
      ],
      otherwise: policy.AnyoneHolding("finance"),
    )
  let spec = kit.Spec(..kit.spec("escalation"), policy: escalating)
  let #(first_name, first_store) = kit.store()
  let first_desk = kit.desk(first_store, spec)
  let first =
    kit.start(
      first_name,
      first_store,
      kit.delivering(),
      [decisions.waker(first_desk)],
      [],
      None,
    )
  let assert Ok(waiting) =
    kit.tx(first, decisions.recommend(
      first_desk,
      _,
      kit.proposal(spec.name, kit.ana),
    ))
  let assert Ok(Some(head)) =
    decisions_postgres.inspection().head(first.db, waiting.id)
  assert head.awaiting == ["finance"]
  kit.stop(first)
  // A new runtime, with the store's clock an hour ahead.
  let #(second_name, second_store) = kit.store()
  let later =
    decisions_postgres.with_clock_offset(second_store, duration.hours(1))
  let later_desk = kit.desk(later, spec)
  let wakers = [decisions.waker(later_desk)]
  let second =
    kit.start(
      second_name,
      later,
      kit.delivering(),
      wakers,
      [],
      Some(first.schema),
    )
  let wake =
    kit.scalar(
      second.db,
      "SELECT id FROM decisions_wakes WHERE occurrence_id = $1",
      [pog.text(waiting.id)],
      decode.int,
    )
  let assert Ok(1) =
    decisions_postgres.deliver_due(later, second.db, wakers, limit: 100)
  let assert Ok(Some(head)) =
    decisions_postgres.inspection().head(second.db, waiting.id)
  assert head.awaiting == ["managers"]
  // Nothing else is due, and the Grind job, when it comes, does nothing.
  let assert Ok(0) =
    decisions_postgres.deliver_due(later, second.db, wakers, limit: 100)
  let worker = decisions_postgres.wake_worker(later, wakers)
  let context =
    grind_testing.context(job_id: 1, attempt: 1)
    |> grind_testing.with_connection(second.db)
  let assert Ok(worker.Succeeded("nothing pending")) =
    grind_testing.perform_with(
      worker,
      context,
      decisions_postgres.WakeJob(
        wake:,
        point: spec.name,
        occurrence: waiting.id,
        at_ms: 0,
      ),
    )
  let assert Ok(known) =
    kit.tx(second, decisions.read(later_desk, _, occurrence: waiting.id))
  assert list.length(known.entries) == 3
  kit.check(second, [later_desk])
  kit.stop(second)
}

/// A policy step that consults another point, on a desk with no consult
/// handler wired: each delivery fails with `ConsultFailed`, which is
/// counted, and the wake-up is set aside when its attempts are used
/// instead of being delivered for ever.
pub fn a_wake_up_that_cannot_consult_is_counted_and_set_aside_test() {
  let consulting =
    policies.checked(
      version: 1,
      rules: [
        policy.When(
          policy.AtLeast(fact.name(fact.waited_minutes()), 1.0),
          policy.Consult(point: "billing.elsewhere"),
        ),
      ],
      otherwise: policy.AnyoneHolding("finance"),
    )
  let spec = kit.Spec(..kit.spec("no_consult"), policy: consulting)
  let #(name, store) = kit.store()
  let store = decisions_postgres.with_wake_attempts(store, 3)
  let base = decisions_postgres.port(store)
  // The occurrence is made over a clock 61 s behind, so its one-minute
  // step is due now; the desk that wakes it reads the real clock.
  let behind =
    store.Port(..base, now: fn(tx) {
      timestamp.add(base.now(tx), duration.seconds(-61))
    })
  let making = kit.desk_over(behind, spec)
  let waking = kit.desk(store, spec)
  let aside = process.new_subject()
  let watch =
    sinal.observe(telemetry.set_aside(), fn(_, record) {
      case record.point == spec.name {
        True -> process.send(aside, record)
        False -> Nil
      }
    })
  use env <- kit.run(
    name,
    store,
    kit.delivering(),
    [decisions.waker(waking)],
    [],
  )
  let assert Ok(waiting) =
    kit.tx(env, decisions.recommend(making, _, kit.proposal(spec.name, kit.ana)))
  let assert Ok(record) = process.receive(aside, 15_000)
  let _ = sinal.detach(watch)
  assert record.kind == telemetry.WakeUp
  assert record.occurrence == waiting.id
  let assert True =
    kit.eventually(5000, fn() {
      case kit.jobs(env, "decisions.wake") {
        [#("discarded", _)] -> True
        _ -> False
      }
    })
  let attempts =
    kit.scalar(
      env.db,
      "SELECT attempt_count FROM \"" <> env.schema <> "\".grind_jobs
       WHERE worker_id = 'decisions.wake'",
      [],
      decode.int,
    )
  assert attempts == 3
}

/// A tool that answers `Unsure` at the end of a hold: nothing is recorded
/// as refused, the wake-up is delivered again after a backoff, and the
/// hold is released once.
pub fn a_wake_up_that_meets_an_unsure_tool_is_retried_and_releases_once_test() {
  let #(name, store) = kit.store()
  let spec =
    kit.Spec(
      ..kit.spec("unsure"),
      policy: kit.proceed(),
      hold: Some(duration.milliseconds(100)),
      execute: fn(tx, released) {
        case kit.once("unsure:" <> decisions.occurrence_of(released)) {
          True -> Error(decisions.Unsure("the registry did not answer"))
          False -> kit.record_effect(tx, released)
        }
      },
    )
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.delivering(), [decisions.waker(desk)], [])
  let assert Ok(held) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert True =
    kit.eventually(10_000, fn() { kit.effects_of(env.db, held.id) == 1 })
  let assert True =
    kit.eventually(5000, fn() {
      case kit.jobs(env, "decisions.wake") {
        [#("succeeded", _)] -> True
        _ -> False
      }
    })
  // One counted attempt failed (Unsure), the next released.
  let attempts =
    kit.scalar(
      env.db,
      "SELECT attempt_count FROM \"" <> env.schema <> "\".grind_jobs
       WHERE worker_id = 'decisions.wake'",
      [],
      decode.int,
    )
  assert attempts == 2
  let assert Ok(known) =
    kit.tx(env, decisions.read(desk, _, occurrence: held.id))
  let assert occurrence.Released(..) = known.status
  assert kit.effects_of(env.db, held.id) == 1
  kit.check(env, [desk])
}
