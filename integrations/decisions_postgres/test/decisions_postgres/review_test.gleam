//// The corrections an independent review of this adapter asked for, each
//// with the scenario that shows it: a follower that raises, a delivery
//// that is snoozed for ever, a pending row with no job, paging by commit
//// order, names too long for the store, an append with no entries, an
//// application role that does not own the tables, and the classification
//// of a real deadlock and a real serialization failure.

import decisions
import decisions/occurrence
import decisions/store.{Head, Stored}
import decisions/vocabulary.{Approve}
import decisions/wire
import decisions_postgres.{Contended}
import decisions_postgres/internal/sql
import decisions_postgres/queue
import decisions_postgres/telemetry
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import kit
import pog
import sinal

fn watch_aside(
  point: String,
) -> #(process.Subject(telemetry.SetAside), sinal.Attachment) {
  let aside = process.new_subject()
  let attachment =
    sinal.observe(telemetry.set_aside(), fn(_, record) {
      case record.point == point {
        True -> process.send(aside, record)
        False -> Nil
      }
    })
  #(aside, attachment)
}

fn attempts_of(env: kit.Env, worker_id: String) -> Int {
  kit.scalar(
    env.db,
    "SELECT attempt_count FROM \"" <> env.schema <> "\".grind_jobs
     WHERE worker_id = $1",
    [pog.text(worker_id)],
    decode.int,
  )
}

/// G1: a follower that raises is an application failure: counted, and the
/// notice is set aside after the last attempt. Without the catch, the raise
/// crashed the attempt and Grind held the job uncertain.
pub fn a_follower_that_raises_is_counted_and_set_aside_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("raises"), policy: kit.proceed())
  let store =
    decisions_postgres.following(store, spec.name)
    |> decisions_postgres.with_settlement_attempts(2)
  let desk = kit.desk(store, spec)
  let follower = #(spec.name, fn(_tx, _id) { panic as "the follower broke" })
  let #(aside, watch) = watch_aside(spec.name)
  use env <- kit.run(name, store, kit.delivering(), [], [follower])
  let assert Ok(released) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert Ok(record) = process.receive(aside, 15_000)
  let _ = sinal.detach(watch)
  assert record.occurrence == released.id
  assert string.contains(record.reason, "the follower broke")
  let assert True =
    kit.eventually(5000, fn() {
      kit.jobs(env, "decisions.settlement") |> list.map(fn(j) { j.0 })
      == ["discarded"]
    })
  assert attempts_of(env, "decisions.settlement") == 2
}

/// G1: a notice delivered again and again without an outcome (the store
/// stays unavailable to its follower) is set aside when its snooze limit is
/// reached, and reported; the job is never dropped silently.
pub fn a_notice_snoozed_to_its_limit_is_set_aside_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("snoozed"), policy: kit.proceed())
  let store =
    decisions_postgres.following(store, spec.name)
    |> decisions_postgres.with_snooze_limit(2)
  let desk = kit.desk(store, spec)
  let follower = #(spec.name, fn(_tx, _id) {
    Error(
      decisions.DeskRefused(
        decisions.StoreFailed(store.Unavailable("still down")),
      ),
    )
  })
  let #(aside, watch) = watch_aside(spec.name)
  use env <- kit.run(name, store, kit.delivering(), [], [follower])
  let assert Ok(released) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert Ok(record) = process.receive(aside, 20_000)
  let _ = sinal.detach(watch)
  assert record.occurrence == released.id
  assert string.contains(record.reason, "delivered again 2 times")
  assert attempts_of(env, "decisions.settlement") <= 1
}

/// G1: a point added to `following` after its occurrences settled has
/// notices with no job, and a wake-up row can be left with none (here: its
/// job went to a runtime that never runs it); nothing delivers them until
/// `sweep` admits a job for each, and then each is delivered once.
pub fn sweep_admits_a_job_for_pending_rows_that_have_none_test() {
  let spec = kit.Spec(..kit.spec("swept"), policy: kit.proceed())
  let held =
    kit.Spec(
      ..kit.spec("swept_held"),
      policy: kit.proceed(),
      hold: Some(duration.milliseconds(50)),
    )
  // A runtime with no consumers admits the hold's job, then goes away.
  let #(other_name, other_store) = kit.store()
  let other = kit.start(other_name, other_store, kit.options(), [], [], None)
  let assert Ok(waiting) =
    kit.tx(other, decisions.recommend(
      kit.desk(other_store, held),
      _,
      kit.proposal(held.name, kit.ana),
    ))
  kit.stop(other)
  let #(name, store) = kit.store()
  // Settled before anything followed the point: notices, no jobs.
  let unfollowed_desk = kit.desk(store, spec)
  let followed = decisions_postgres.following(store, spec.name)
  let held_desk = kit.desk(followed, held)
  let follower = #(spec.name, fn(tx, id) {
    pog.query(
      "INSERT INTO test_effects (point, occurrence, key) VALUES ($1, $2, 'swept')",
    )
    |> pog.parameter(pog.text("follow:" <> spec.name))
    |> pog.parameter(pog.text(id))
    |> pog.execute(tx)
    |> result.replace(Nil)
    |> result.map_error(fn(_) { decisions.ApplicationFailed("insert failed") })
  })
  use env <- kit.run(
    name,
    followed,
    kit.delivering(),
    [decisions.waker(held_desk)],
    [follower],
  )
  let settled =
    list.map(kit.int_range(3), fn(_) {
      let assert Ok(made) =
        kit.tx(env, decisions.recommend(
          unfollowed_desk,
          _,
          kit.proposal(spec.name, kit.ana),
        ))
      made.id
    })
  // The row keeps the other runtime's job id; this runtime has no such job.
  let assert Ok(_) =
    pog.query(
      "UPDATE decisions_wakes SET job_id = NULL WHERE occurrence_id = $1",
    )
    |> pog.parameter(pog.text(waiting.id))
    |> pog.execute(env.db)
  // No job exists in this runtime for either, so nothing can deliver them.
  assert kit.jobs(env, "decisions.settlement") == []
  assert kit.jobs(env, "decisions.wake") == []
  assert kit.effects(env.db, "follow:" <> spec.name) == 0
  assert kit.effects_of(env.db, waiting.id) == 0
  let assert Ok(swept) = decisions_postgres.sweep(followed, env.db)
  assert swept.notices == 3
  // The tables are shared by every test in this database, each with its
  // own Grind schema, so other tests' rows may be swept too.
  assert swept.wakes >= 1
  let assert True =
    kit.eventually(10_000, fn() {
      kit.effects(env.db, "follow:" <> spec.name) == 3
    })
  assert list.all(settled, fn(id) {
    kit.scalar(
      env.db,
      "SELECT count(*) FROM test_effects WHERE occurrence = $1 AND key = 'swept'",
      [pog.text(id)],
      decode.int,
    )
    == 1
  })
  let assert True =
    kit.eventually(10_000, fn() { kit.effects_of(env.db, waiting.id) == 1 })
  // No notice is left without a job.
  let assert Ok(again) = decisions_postgres.sweep(followed, env.db)
  assert again.notices == 0
  kit.check(env, [unfollowed_desk, held_desk])
}

/// G2: a settlement whose transaction began first and committed last is
/// not skipped: pages follow commit order, and a page never passes a
/// transaction still running.
pub fn settled_since_never_skips_a_late_commit_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("paged"), policy: kit.proceed())
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let since = decisions_postgres.port(store).now(env.db)
  let holding = process.new_subject()
  // The first transaction settles A and waits before committing.
  process.spawn(fn() {
    let _ =
      pog.transaction(env.db, fn(tx) {
        let assert Ok(early) =
          decisions.recommend(desk, tx, kit.proposal(spec.name, kit.ana))
        let release = process.new_subject()
        process.send(holding, #(early.id, release))
        let _ = process.receive(release, 10_000)
        Ok(Nil)
      })
      |> result.map_error(fn(_: pog.TransactionError(Nil)) { Nil })
    Nil
  })
  let assert Ok(#(early, release)) = process.receive(holding, 5000)
  // A later transaction settles B and commits first.
  let assert Ok(late) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let read = fn(after) {
    let assert Ok(page) =
      queue.settled_since(env.db, point: spec.name, since:, limit: 10, after:)
    page
  }
  // While A's transaction runs, B is held back too.
  assert read(None) == []
  process.send(release, Nil)
  let assert True = kit.eventually(5000, fn() { list.length(read(None)) == 2 })
  // Reading one at a time with the cursor returns both, once each, A first.
  let assert [first] = page_of_one(env, spec.name, since, None)
  let assert [second] = page_of_one(env, spec.name, since, Some(first))
  assert page_of_one(env, spec.name, since, Some(second)) == []
  assert [first.occurrence, second.occurrence] == [early, late.id]
}

fn page_of_one(env: kit.Env, point, since, after) {
  let assert Ok(page) =
    queue.settled_since(env.db, point:, since:, limit: 1, after:)
  page
}

/// G3: an occurrence id or a point name longer than the store keeps is
/// refused at once with a conflict that says so; nothing is written and
/// the `NOTIFY` payload stays bounded.
pub fn names_longer_than_the_store_keeps_are_refused_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("long"), policy: kit.proceed())
  let long_point = kit.Spec(..spec, name: string.repeat("p", 300))
  let desk = kit.desk(store, spec)
  let long_desk = kit.desk(store, long_point)
  use env <- kit.run(name, store, kit.options(), [], [])
  let key = string.repeat("k", decisions_postgres.max_name_bytes + 1)
  let assert Error(decisions_postgres.Conflict(detail)) =
    kit.tx(env, decisions.recommend_once(
      desk,
      _,
      key:,
      proposal: kit.proposal(spec.name, kit.ana),
    ))
  assert string.contains(detail, "at most 255")
  let assert Error(decisions_postgres.Conflict(detail)) =
    kit.tx(env, decisions.recommend(
      long_desk,
      _,
      kit.proposal(long_point.name, kit.ana),
    ))
  assert string.contains(detail, "the point name")
  // At the limit it is kept.
  let assert Ok(_) =
    kit.tx(env, decisions.recommend_once(
      desk,
      _,
      key: string.repeat("k", decisions_postgres.max_name_bytes),
      proposal: kit.proposal(spec.name, kit.ana),
    ))
  // The database refuses it too, whoever writes.
  let assert Error(pog.ConstraintViolated(constraint:, ..)) =
    pog.query(
      "INSERT INTO decisions_occurrences
         (id, point, subject_kind, subject_id, status, awaiting, approved,
          may_not_decide, arrived, review_pending, last_seq)
       VALUES ($1, 'p', 'person', 'ana', 'recommended', '{}', '{}', '{}',
               clock_timestamp(), false, 1)",
    )
    |> pog.parameter(pog.text(key))
    |> pog.execute(env.db)
  assert constraint == "decisions_occurrences_id_length"
}

/// G6: an append with no entries replaces the head, as the port says.
pub fn an_append_with_no_entries_replaces_the_head_test() {
  let #(name, store) = kit.store()
  use env <- kit.run(name, store, kit.options(), [], [])
  let port = decisions_postgres.port(store)
  let id = kit.tag("empty")
  let at = wire.from_milliseconds(1_800_000_000_000)
  let first =
    Head(
      point: kit.tag("p"),
      subject: kit.ana,
      status: store.Recommended,
      awaiting: [],
      due: None,
      arrived: at,
      approved: [],
      may_not_decide: [],
      review_pending: False,
    )
  let assert Ok(Nil) =
    port.append(env.db, id, first, [Stored(1, at, "recommended", "{}")])
  let second = Head(..first, status: store.Awaiting, awaiting: ["finance"])
  let assert Ok(Nil) = port.append(env.db, id, second, [])
  let assert Ok(Some(head)) = decisions_postgres.inspection().head(env.db, id)
  assert head == second
  let assert Ok([_]) = port.load(env.db, id)
  // No record and no entries: nothing to replace, nothing written.
  let absent = kit.tag("absent")
  let assert Ok(Nil) = port.append(env.db, absent, first, [])
  let assert Ok(None) = decisions_postgres.inspection().head(env.db, absent)
}

/// G7: an application role that does not own the tables, with the grants
/// the README lists, runs the verbs; it cannot change an entry, and it
/// cannot switch the append-only trigger off.
pub fn an_application_role_cannot_rewrite_the_record_test() {
  let #(name, store) = kit.store()
  use env <- kit.run(name, store, kit.options(), [], [])
  let role = "decisions_app_" <> int.to_string(kit.unique())
  list.each(
    [
      "CREATE ROLE " <> role <> " LOGIN",
      "GRANT SELECT, INSERT, UPDATE, DELETE ON decisions_occurrences,
         decisions_awaiting, decisions_wakes, decisions_settled TO " <> role,
      "GRANT SELECT, INSERT ON decisions_entries TO " <> role,
    ],
    fn(sql) {
      let assert Ok(_) = pog.query(sql) |> pog.execute(env.db)
    },
  )
  let assert Ok(started) = kit.pool_config(2) |> pog.user(role) |> pog.start
  let app = started.data
  let spec = kit.Spec(..kit.spec("app_role"), execute: fn(_, _) { Ok(Nil) })
  let desk = kit.desk(store, spec)
  let assert Ok(waiting) =
    decisions_postgres.transaction(app, decisions.recommend(
      desk,
      _,
      kit.proposal(spec.name, kit.ana),
    ))
  let assert Ok(released) =
    decisions_postgres.transaction(app, kit.open_and_decide(
      desk,
      _,
      waiting.id,
      kit.finance("bia"),
      Approve,
    ))
  let assert occurrence.Released(..) = released.status
  let refused = fn(sql) {
    case pog.query(sql) |> pog.execute(app) {
      Error(pog.PostgresqlError(code: "42501", ..)) -> True
      _ -> False
    }
  }
  assert refused("UPDATE decisions_entries SET event = '{}'")
  assert refused("DELETE FROM decisions_entries")
  assert refused(
    "ALTER TABLE decisions_entries DISABLE TRIGGER decisions_entries_append_only",
  )
  process.unlink(started.pid)
  process.kill(started.pid)
}

/// G10: a real deadlock (40P01) and a real serialization failure (40001)
/// are both `Contended`: nothing was written, run it again.
pub fn a_deadlock_and_a_serialization_failure_are_contention_test() {
  let #(name, store) = kit.store()
  let spec = kit.spec("contended")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let port = decisions_postgres.port(store)
  let make = fn() {
    let assert Ok(made) =
      kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
    made.id
  }
  let x = make()
  let y = make()
  // Two transactions lock the two occurrences in opposite orders.
  let load = fn(tx, id) {
    port.load(tx, id) |> result.map_error(decisions.StoreFailed)
  }
  // Each takes its first lock, says so, and goes for its second only
  // when both hold their first: the deadlock is certain, not timed.
  let locked = process.new_subject()
  let outcomes = process.new_subject()
  list.each([#(x, y), #(y, x)], fn(order) {
    let #(first, second) = order
    process.spawn(fn() {
      let outcome =
        decisions_postgres.transaction(env.db, fn(tx) {
          use _ <- result.try(load(tx, first))
          let go = process.new_subject()
          process.send(locked, go)
          let _ = process.receive(go, 10_000)
          load(tx, second)
        })
      process.send(outcomes, outcome)
    })
  })
  let assert Ok(one) = process.receive(locked, 5000)
  let assert Ok(other) = process.receive(locked, 5000)
  process.send(one, Nil)
  process.send(other, Nil)
  let assert Ok(a) = process.receive(outcomes, 10_000)
  let assert Ok(b) = process.receive(outcomes, 10_000)
  let results = [a, b]
  let deadlocked =
    list.filter_map(results, fn(result) {
      case result {
        Error(Contended(detail)) -> Ok(detail)
        _ -> Error(Nil)
      }
    })
  let assert [detail] = deadlocked
  assert string.contains(detail, "40P01")
  // A real serialization failure: a repeatable-read transaction updates a
  // row another transaction changed after its snapshot (40001). The port
  // itself refuses repeatable read (see `isolation_test`), so the failure
  // is produced on an application row and classified as the port would.
  let row = kit.tag("row")
  let assert Ok(_) =
    pog.query(
      "INSERT INTO test_effects (point, occurrence, key) VALUES ('rr', $1, 'v1')",
    )
    |> pog.parameter(pog.text(row))
    |> pog.execute(env.db)
  let gates = process.new_subject()
  let outcomes = process.new_subject()
  process.spawn(fn() {
    let outcome =
      pog.transaction(env.db, fn(tx) {
        let assert Ok(_) =
          pog.query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
          |> pog.execute(tx)
        let assert Ok(_) = pog.query("SELECT 1") |> pog.execute(tx)
        let go = process.new_subject()
        process.send(gates, go)
        let _ = process.receive(go, 10_000)
        pog.query("UPDATE test_effects SET key = 'v3' WHERE occurrence = $1")
        |> pog.parameter(pog.text(row))
        |> pog.execute(tx)
      })
    process.send(outcomes, outcome)
  })
  let assert Ok(go) = process.receive(gates, 5000)
  let assert Ok(_) =
    pog.query("UPDATE test_effects SET key = 'v2' WHERE occurrence = $1")
    |> pog.parameter(pog.text(row))
    |> pog.execute(env.db)
  process.send(go, Nil)
  let assert Ok(Error(pog.TransactionRolledBack(error))) =
    process.receive(outcomes, 10_000)
  let assert store.Contended(detail) = sql.store_error(error)
  assert string.contains(detail, "40001")
}
