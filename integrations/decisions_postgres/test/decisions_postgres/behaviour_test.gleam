//// What one transaction at a time must show over PostgreSQL: a tool that
//// writes and then refuses leaves nothing, a verdict after the deadline is
//// refused before any wake-up arrives, a store clock behind the job
//// queue's is waited for, the store's clock is the database's, and the
//// transaction helper tells a refusal from a conflict from an unavailable
//// store.

import decisions
import decisions/entry
import decisions/model
import decisions/occurrence
import decisions/store
import decisions/vocabulary.{Approve}
import decisions/wire
import decisions_postgres.{Conflict, Contended, Refused}
import decisions_postgres/queue
import decisions_postgres/telemetry
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import kit
import pog
import sinal

fn writes_then_refuses(
  tx: decisions_postgres.Tx,
  released: decisions.Released(String),
) -> Result(Nil, vocabulary.Stop) {
  use Nil <- result.try(kit.record_effect(tx, released))
  Error(vocabulary.Refuse("the registry refuses"))
}

/// The verdict's transaction rolls back with the tool's write, and a
/// second transaction keeps the refused verdict on the record.
pub fn a_tool_that_writes_then_refuses_a_verdict_leaves_nothing_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("refuses"), execute: writes_then_refuses)
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let bia = kit.finance("bia")
  let assert Ok(waiting) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  // The card is opened in one request and decided in another.
  let assert Ok(ticket) =
    kit.tx(env, fn(tx) {
      decisions.open(desk, tx, occurrence: waiting.id, by: bia, latest: fn(ref) {
        ref.revision
      })
      |> result.map(decisions.ticket)
    })
  let assert Error(Refused(decisions.ToolRefused(..))) =
    decisions_postgres.decide(
      env.pool,
      desk,
      decisions.resume(desk, _, ticket, by: bia),
      Approve,
    )
  assert kit.effects_of(env.db, waiting.id) == 0
  let assert Ok(known) =
    kit.tx(env, decisions.read(desk, _, occurrence: waiting.id))
  let assert occurrence.Awaiting(_) = known.status
  let assert Ok(last) = list.last(known.entries)
  assert entry.kind(last.event) == "verdict_refused"
  kit.check(env, [desk])
}

/// After a hold nobody waits on the release, so a refusal ends the
/// occurrence `refused`; the savepoint takes the tool's write back.
pub fn a_tool_that_writes_then_refuses_after_a_hold_leaves_nothing_test() {
  let #(name, store) = kit.store()
  let spec =
    kit.Spec(
      ..kit.spec("refuses_held"),
      policy: kit.proceed(),
      hold: Some(duration.milliseconds(50)),
      execute: writes_then_refuses,
    )
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let assert Ok(held) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert occurrence.Held(until:, ..) = held.status
  kit.wait_for_store_clock(env, until)
  let assert Ok(decisions.Woken(woken)) =
    kit.tx(env, decisions.wake(desk, _, occurrence: held.id))
  assert woken.status == occurrence.Refused("the registry refuses")
  assert kit.effects_of(env.db, held.id) == 0
  kit.check(env, [desk])
}

/// A tool whose statement fails aborts nothing but its savepoint: the
/// refusal is appended and committed, with the SQLSTATE in its reason.
pub fn a_tool_whose_statement_fails_after_a_hold_ends_refused_test() {
  let #(name, store) = kit.store()
  let spec =
    kit.Spec(
      ..kit.spec("fails_held"),
      policy: kit.proceed(),
      hold: Some(duration.milliseconds(50)),
      execute: fn(tx, released) {
        use Nil <- result.try(kit.record_effect(tx, released))
        pog.query("SELECT 1 / 0")
        |> pog.execute(decisions_postgres.connection(tx))
        |> result.replace(Nil)
        |> result.map_error(fn(error) {
          vocabulary.Refuse(string.inspect(error))
        })
      },
    )
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let assert Ok(held) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert occurrence.Held(until:, ..) = held.status
  kit.wait_for_store_clock(env, until)
  let assert Ok(decisions.Woken(woken)) =
    kit.tx(env, decisions.wake(desk, _, occurrence: held.id))
  let assert occurrence.Refused(reason) = woken.status
  assert string.contains(reason, "22012")
  assert kit.effects_of(env.db, held.id) == 0
  kit.check(env, [desk])
}

/// A verdict given after the validity ended is refused although the
/// wake-up that expires the occurrence has not been delivered; no tool
/// runs. The wake-up, delivered later, expires it.
pub fn a_verdict_after_the_deadline_is_refused_before_any_wake_up_test() {
  let #(name, store) = kit.store()
  let spec =
    kit.Spec(..kit.spec("deadline"), validity: Some(duration.milliseconds(300)))
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let assert Ok(waiting) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert Some(deadline) = waiting.valid_until
  kit.wait_for_store_clock(env, deadline)
  let assert Error(Refused(_)) =
    kit.tx(env, kit.open_and_decide(
      desk,
      _,
      waiting.id,
      kit.finance("bia"),
      Approve,
    ))
  assert kit.effects_of(env.db, waiting.id) == 0
  // Its wake-up is still pending: nothing has delivered it.
  let assert Ok(wakes) = kit.within(env, decisions_postgres.inspection().wakes)
  assert list.any(wakes, fn(wake) { wake.occurrence == waiting.id })
  let assert Ok(decisions.Woken(expired)) =
    kit.tx(env, decisions.wake(desk, _, occurrence: waiting.id))
  let assert occurrence.Expired(_) = expired.status
  kit.check(env, [desk])
}

/// Two keys expected with their own deadline (`expect_until`) an hour
/// ahead, one whose model failed: the pending queue shows the deadline, a
/// wake-up before it is not due (`wake` answers `NotDue`), and
/// a store whose clock stands past the deadline expires both through the
/// wake worker's code path. A late recommendation commits expired after the
/// expiry, with the one notice the expiry admitted, and a late failure is
/// refused without writing.
pub fn an_expected_record_expires_at_its_own_deadline_test() {
  let #(name, pg) = kit.store()
  let later = decisions_postgres.with_clock_offset(pg, duration.hours(2))
  let spec = kit.spec("own-deadline")
  let desk = kit.desk(pg, spec)
  let late_desk = kit.desk(later, spec)
  let late_wakers = [decisions.waker(late_desk)]
  use env <- kit.run(name, pg, kit.options(), [], [])
  let deadline = hour_ahead(pg, env)
  let failing = kit.tag("failing")
  let late = kit.tag("late")
  let assert Ok(Nil) =
    kit.tx(env, fn(tx) {
      use Nil <- result.try(expect_by(desk, tx, failing, deadline))
      expect_by(desk, tx, late, deadline)
    })
  let fail = fn(desk, tx) {
    decisions.record_failure(
      desk,
      tx,
      key: failing,
      trigger: vocabulary.Trigger("test", failing),
      about: kit.ana,
      failure: model.Raised("down"),
    )
  }
  let assert Ok([_]) = kit.tx(env, fail(desk, _))
  let assert Ok(pending) =
    queue.pending(env.pool, point: spec.name, limit: 10, after: None)
  assert list.map(pending, fn(summary) { summary.due })
    == [Some(deadline), Some(deadline)]
  // Before the deadline the wake-up says when to come back, and nothing is
  // due on the store's clock.
  assert kit.tx(env, decisions.wake(desk, _, occurrence: failing))
    == Ok(decisions.NotDue(deadline))
  let assert Ok(0) =
    decisions_postgres.deliver_due(
      pg,
      env.pool,
      [decisions.waker(desk)],
      limit: 10,
    )
  // Past the deadline on the store's clock.
  let assert Ok(2) =
    decisions_postgres.deliver_due(later, env.pool, late_wakers, limit: 10)
  let assert Ok(Some(head)) =
    kit.within(env, decisions_postgres.inspection().head(_, failing))
  assert head.status == store.Expired
  let assert Ok(recorded) =
    kit.tx(env, decisions.recommend_once(
      late_desk,
      _,
      key: late,
      proposal: kit.proposal(spec.name, kit.ana),
    ))
  assert recorded.status == occurrence.Expired(vocabulary.DeadlinePassed)
  assert recorded.valid_until == Some(deadline)
  assert kinds(recorded) == ["expected", "expired", "recommended"]
  // Refused in a transaction that commits anyway, as a caller that treats
  // the refusal as done would run it: nothing is written.
  let read = fn() {
    kit.tx(env, decisions.read_record(late_desk, _, key: failing))
  }
  let before = read()
  let assert Ok(Error(decisions.DeadlinePassedBefore(at))) =
    kit.tx(env, fn(tx) { Ok(fail(late_desk, tx)) })
  assert at == deadline
  assert read() == before
  assert kit.effects_of(env.db, late) == 0
  kit.check(env, [late_desk])
}

/// Grind itself delivers a record's own deadline: the job admitted with the
/// expectation runs at the deadline and expires the record.
pub fn grind_delivers_a_record_s_own_deadline_test() {
  let #(name, pg) = kit.store()
  let spec = kit.spec("own-deadline-grind")
  let desk = kit.desk(pg, spec)
  use env <- kit.run(name, pg, kit.delivering(), [decisions.waker(desk)], [])
  let port = decisions_postgres.port(pg)
  let deadline =
    timestamp.add(kit.within(env, port.now), duration.seconds(2))
    |> wire.milliseconds
    |> wire.from_milliseconds
  let key = kit.tag("grind")
  let assert Ok(Nil) = kit.tx(env, expect_by(desk, _, key, deadline))
  let assert [#("succeeded", 1)] = kit.finished_jobs(env, "decisions.wake")
  let assert Ok(decisions.NotBegun(pending)) =
    kit.tx(env, decisions.read_record(desk, _, key:))
  assert pending.ended == Some(vocabulary.DeadlinePassed)
  kit.check(env, [desk])
}

/// The wake-up and late recommendations for lapsed keys, started together
/// through a gate: whichever takes a key's lock first, every key ends with
/// one shape (expected, expired, recommended), one settlement notice, and
/// every invariant holding.
pub fn a_wake_up_racing_a_late_recommendation_leaves_one_notice_test() {
  let #(name, pg) = kit.store()
  let later = decisions_postgres.with_clock_offset(pg, duration.hours(2))
  let spec = kit.spec("own-deadline-race")
  let desk = kit.desk(pg, spec)
  let late_desk = kit.desk(later, spec)
  use env <- kit.run(name, pg, kit.options(), [], [])
  let deadline = hour_ahead(pg, env)
  let keys =
    list.map([1, 2, 3, 4, 5, 6], fn(n) {
      kit.tag("race") <> "-" <> int.to_string(n)
    })
  list.each(keys, fn(key) {
    let assert Ok(Nil) = kit.tx(env, expect_by(desk, _, key, deadline))
  })
  // Every key waits for its wake-up before the race.
  let assert Ok(wakes) = kit.within(env, decisions_postgres.inspection().wakes)
  assert list.all(keys, fn(key) {
    list.any(wakes, fn(wake) { wake.occurrence == key && wake.at == deadline })
  })
  let outcomes =
    kit.race(list.length(keys) + 1, 10_000, fn(n) {
      case list.drop(keys, n - 1) |> list.first {
        Ok(key) if n > 0 ->
          kit.tx(env, decisions.recommend_once(
            late_desk,
            _,
            key:,
            proposal: kit.proposal(spec.name, kit.ana),
          ))
          |> result.replace(Nil)
          |> result.map_error(string.inspect)
        _ ->
          decisions_postgres.deliver_due(
            later,
            env.pool,
            [decisions.waker(late_desk)],
            limit: 10,
          )
          |> result.replace(Nil)
          |> result.map_error(string.inspect)
      }
    })
  assert list.all(outcomes, fn(outcome) { outcome == Ok(Nil) })
  let assert Ok(notices) =
    kit.within(env, decisions_postgres.inspection().notices)
  list.each(keys, fn(key) {
    let assert Ok(known) =
      kit.tx(env, decisions.read(late_desk, _, occurrence: key))
    assert known.status == occurrence.Expired(vocabulary.DeadlinePassed)
    assert kinds(known) == ["expected", "expired", "recommended"]
    assert list.count(notices, fn(notice) { notice.occurrence == key }) == 1
  })
  kit.check(env, [late_desk])
}

/// An hour after the store's clock, in whole milliseconds.
fn hour_ahead(
  pg: decisions_postgres.Store,
  env: kit.Env,
) -> timestamp.Timestamp {
  timestamp.add(
    kit.within(env, decisions_postgres.port(pg).now),
    duration.hours(1),
  )
  |> wire.milliseconds
  |> wire.from_milliseconds
}

fn expect_by(desk, tx, key: String, deadline: timestamp.Timestamp) {
  decisions.expect_until(
    desk,
    tx,
    key:,
    trigger: vocabulary.Trigger("test", key),
    about: kit.ana,
    valid_until: deadline,
  )
}

fn kinds(known: occurrence.Occurrence(o)) -> List(String) {
  list.map(known.entries, fn(e) { entry.kind(e.event) })
}

type Offset

@external(erlang, "kit_ffi", "offset_new")
fn offset_new() -> Offset

@external(erlang, "kit_ffi", "offset_get")
fn offset_get(offset: Offset) -> Int

@external(erlang, "kit_ffi", "offset_add")
fn offset_add(offset: Offset, ms: Int) -> Nil

/// The application's port reads a store clock behind the database's,
/// which Grind delivers by. The hold's job arrives before the hold ends on
/// the store's clock: the wake-up says when to come back, the worker
/// reschedules it by the time left on that clock, and once the store's
/// clock reaches the hold's end the wake-up releases it once.
///
/// The store's clock is ten minutes behind until the test moves it, so
/// every delivery before that is early by construction.
pub fn a_store_clock_behind_the_job_queue_is_waited_for_test() {
  let #(name, store) = kit.store()
  let spec =
    kit.Spec(
      ..kit.spec("skew"),
      policy: kit.proceed(),
      hold: Some(duration.milliseconds(300)),
    )
  let base = decisions_postgres.port(store)
  let behind = offset_new()
  offset_add(behind, -600_000)
  let skewed =
    store.Port(..base, now: fn(tx) {
      timestamp.add(base.now(tx), duration.milliseconds(offset_get(behind)))
    })
  let desk = kit.desk_over(skewed, spec)
  let rescheduled = process.new_subject()
  let watch =
    sinal.observe(telemetry.wake_rescheduled(), fn(_, early) {
      case early.point == spec.name {
        True -> process.send(rescheduled, early)
        False -> Nil
      }
    })
  let wakers = [decisions.waker(desk)]
  use env <- kit.run(name, store, kit.delivering(), wakers, [])
  let assert Ok(held) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert occurrence.Held(until:, ..) = held.status
  // The wake-up is due on the database's clock (ten minutes past), so its
  // delivery now, through the worker's code path, comes before the hold's
  // end on the store's clock: it is rescheduled, and nothing is released.
  // (Grind's own delivery of the job, whenever it comes, is early in the
  // same way and is snoozed.)
  let assert Ok(0) =
    decisions_postgres.deliver_due(store, env.pool, wakers, limit: 10)
  let assert Ok(early) = process.receive(rescheduled, 5000)
  let _ = sinal.detach(watch)
  assert early.occurrence == held.id
  assert early.until_ms == wire.milliseconds(until)
  assert kit.effects_of(env.db, held.id) == 0
  // The store's clock catches up; the wake-up, delivered now through the
  // worker's code path, releases it once.
  offset_add(behind, 600_000)
  kit.wait_for_store_clock(env, until)
  let assert Ok(1) =
    decisions_postgres.deliver_due(store, env.pool, wakers, limit: 10)
  assert kit.effects_of(env.db, held.id) == 1
  let assert Ok(known) =
    kit.tx(env, decisions.read(desk, _, occurrence: held.id))
  let assert occurrence.Released(..) = known.status
  let assert Ok(last) = list.last(known.entries)
  assert timestamp.compare(last.at, until) != order.Lt
  // The snoozed job, when it comes back, finds nothing pending.
  let assert Ok(0) =
    decisions_postgres.deliver_due(store, env.pool, wakers, limit: 10)
  kit.check(env, [desk])
}

/// The port's clock is the database's, read when it is called, and entries
/// carry it.
pub fn the_store_clock_is_the_database_clock_test() {
  let #(name, store) = kit.store()
  let spec = kit.spec("clock")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let database = fn() {
    kit.scalar(env.db, "SELECT decisions_ms(clock_timestamp())", [], decode.int)
  }
  let before = database()
  let assert Ok(made) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let after = database()
  let assert [first, ..] = made.entries
  let at = wire.milliseconds(first.at)
  assert before <= at && at <= after
  // Inside one transaction the clock moves: it is not the transaction's
  // start time.
  let assert Ok(#(a, b)) =
    decisions_postgres.transaction(env.pool, fn(tx) {
      let port = decisions_postgres.port(store)
      let a = port.now(tx)
      process.sleep(20)
      Ok(#(a, port.now(tx)))
    })
    |> result.map_error(fn(_: decisions_postgres.Failure) { Nil })
  assert wire.milliseconds(b) - wire.milliseconds(a) >= 20
}

/// A verb that waited for another transaction's lock is stamped with when
/// it ran, not when its transaction began: the clock is read after the
/// lock, on a clock that moves while a transaction is open.
pub fn a_verb_that_waited_for_the_lock_is_stamped_after_it_test() {
  let #(name, store) = kit.store()
  let spec = kit.spec("lock_clock")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let assert Ok(waiting) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let port = decisions_postgres.port(store)
  let holding = process.new_subject()
  process.spawn(fn() {
    let _ =
      decisions_postgres.transaction(env.pool, fn(tx) {
        let _ = port.load(tx, waiting.id)
        process.send(holding, Nil)
        process.sleep(300)
        Ok(Nil)
      })
      |> result.map_error(fn(_: decisions_postgres.Failure) { Nil })
    Nil
  })
  let assert Ok(Nil) = process.receive(holding, 5000)
  let begun =
    kit.scalar(env.db, "SELECT decisions_ms(clock_timestamp())", [], decode.int)
  // This transaction starts now, then waits about 300 ms for the lock.
  let assert Ok(decided) =
    kit.tx(env, kit.open_and_decide(
      desk,
      _,
      waiting.id,
      kit.finance("bia"),
      Approve,
    ))
  let assert Ok(last) = list.last(decided.entries)
  assert wire.milliseconds(last.at) - begun >= 250
  kit.check(env, [desk])
}

/// The helper separates a refusal, a conflict that is safe to retry, and
/// a store that is unavailable.
pub fn the_transaction_helper_classifies_failures_test() {
  let #(name, store) = kit.store()
  // The store's own lock timeout, short, ends the wait below.
  let store =
    decisions_postgres.with_lock_timeout(store, Some(duration.milliseconds(50)))
  let spec = kit.spec("helper")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let assert Error(Refused(decisions.UnknownOccurrence)) =
    kit.tx(env, decisions.read(desk, _, occurrence: kit.tag("absent")))
  // Two transactions append the first entry of one id without loading it:
  // the database refuses the second.
  let id = kit.tag("conflict")
  let port = decisions_postgres.port(store)
  let head =
    store.Head(
      point: spec.name,
      subject: kit.ana,
      status: store.Recommended,
      awaiting: [],
      due: None,
      arrived: wire.from_milliseconds(1_800_000_000_000),
      approved: [],
      may_not_decide: [],
      review_pending: False,
      bundle: option.None,
    )
  let first = [
    store.Stored(
      1,
      wire.from_milliseconds(1_800_000_000_000),
      "recommended",
      "{}",
    ),
  ]
  let append = fn(tx) {
    port.append(tx, id, head, first) |> result.map_error(decisions.StoreFailed)
  }
  let assert Ok(Nil) = kit.tx(env, append)
  let assert Error(Conflict(_)) = kit.tx(env, append)
  // A lock that is not granted in time is contention: nothing was written.
  let assert Ok(waiting) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let holder = process.new_subject()
  process.spawn_unlinked(fn() {
    decisions_postgres.transaction(env.pool, fn(tx) {
      let _ = port.load(tx, waiting.id)
      let release = process.new_subject()
      process.send(holder, release)
      let _ = process.receive(release, 10_000)
      Ok(Nil)
    })
    |> result.map_error(fn(_: decisions_postgres.Failure) { Nil })
  })
  let assert Ok(release) = process.receive(holder, 5000)
  let assert Error(Contended(detail)) =
    kit.tx(env, fn(tx) { decisions.read(desk, tx, occurrence: waiting.id) })
  assert string.contains(detail, "55P03")
  process.send(release, Nil)
}

/// A transaction that writes the application's own rows keeps both kinds
/// of failure typed: the verb's refusal as the library's failure, the
/// application's error as itself; and either rolls everything back.
pub fn a_transaction_keeps_the_application_error_typed_test() {
  let #(name, store) = kit.store()
  let spec = kit.spec("own_error")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let save = fn(tx, id) {
    pog.query(
      "INSERT INTO test_effects (point, occurrence, key) VALUES ($1, $2, 'own')",
    )
    |> pog.parameter(pog.text("own:" <> spec.name))
    |> pog.parameter(pog.text(id))
    |> pog.execute(decisions_postgres.connection(tx))
    |> result.replace(Nil)
    |> result.map_error(fn(_) { OwnRowRefused })
  }
  // Both writes commit together.
  let assert Ok(made) =
    decisions_postgres.transaction_with(env.pool, fn(tx) {
      use made <- result.try(
        decisions.recommend(desk, tx, kit.proposal(spec.name, kit.ana))
        |> decisions_postgres.desk,
      )
      use Nil <- result.try(
        save(tx, made.id) |> result.map_error(decisions_postgres.Own),
      )
      Ok(made)
    })
  assert kit.effects(env.db, "own:" <> spec.name) == 1
  // The application's error comes back as its own type, and the verb's
  // write rolled back with it.
  let assert Error(decisions_postgres.OwnFailed(OwnRowRefused)) =
    decisions_postgres.transaction_with(env.pool, fn(tx) {
      use _ <- result.try(
        decisions.recommend(desk, tx, kit.proposal(spec.name, kit.ana))
        |> decisions_postgres.desk,
      )
      Error(decisions_postgres.Own(OwnRowRefused))
    })
  // A refusal is the library's failure, classified as `transaction` does.
  let assert Error(decisions_postgres.LibraryFailed(Refused(
    decisions.UnknownOccurrence,
  ))) =
    decisions_postgres.transaction_with(env.pool, fn(tx) {
      use _ <- result.try(
        save(tx, made.id) |> result.map_error(decisions_postgres.Own),
      )
      decisions.read(desk, tx, occurrence: kit.tag("absent"))
      |> decisions_postgres.desk
    })
  assert kit.effects(env.db, "own:" <> spec.name) == 1
  let assert Ok(occurrences) =
    kit.within(env, decisions_postgres.inspection().occurrences(_, spec.name))
  assert list.length(occurrences) == 1
  kit.check(env, [desk])
}

type OwnError {
  OwnRowRefused
}

/// The store's test clock offset: a test stands an hour later by building
/// a second store with a larger offset, without wrapping the port. The
/// first store's deadline is past on the second store's clock.
pub fn a_store_clock_offset_stands_an_hour_later_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("hour"), validity: Some(duration.hours(1)))
  let now_desk = kit.desk(store, spec)
  let later =
    decisions_postgres.with_clock_offset(
      store,
      duration.add(duration.hours(1), duration.seconds(1)),
    )
  let later_desk = kit.desk(later, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let assert Ok(waiting) =
    kit.tx(env, decisions.recommend(
      now_desk,
      _,
      kit.proposal(spec.name, kit.ana),
    ))
  let assert Ok(decisions.NotDue(_)) =
    kit.tx(env, decisions.wake(now_desk, _, occurrence: waiting.id))
  let assert Ok(decisions.Woken(expired)) =
    kit.tx(env, decisions.wake(later_desk, _, occurrence: waiting.id))
  let assert occurrence.Expired(_) = expired.status
  kit.check(env, [now_desk])
}

/// A store whose clock is an hour ahead schedules its wake-up jobs on the
/// database's clock, so a 300 ms hold is released in about 300 ms, not an
/// hour later, and the worker measures it on the store's own clock.
pub fn an_offset_store_delivers_its_wake_ups_on_time_test() {
  let #(name, store) = kit.store()
  let store = decisions_postgres.with_clock_offset(store, duration.hours(1))
  let spec =
    kit.Spec(
      ..kit.spec("ahead"),
      policy: kit.proceed(),
      hold: Some(duration.milliseconds(300)),
    )
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.delivering(), [decisions.waker(desk)], [])
  let assert Ok(held) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  // Wait for Grind to acknowledge the job (it records the outcome after the
  // handler's transaction committed), then claim everything about it: one
  // delivery, and one release.
  let assert [#("succeeded", 1)] = kit.finished_jobs(env, "decisions.wake")
  assert kit.effects_of(env.db, held.id) == 1
  kit.check(env, [desk])
}
