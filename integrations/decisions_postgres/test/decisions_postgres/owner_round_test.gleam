//// The owner's round against the database: a held occurrence superseded
//// releases nothing and its later wake-up does nothing; an expected key
//// superseded before its recommendation is refused at `recommend_once`
//// and nothing is written; `expect` commits with the application's own
//// row and job; pending records are found by one query and kept out of
//// every validator's queue; a follower that meets `SupersededBefore` ends
//// its job as done; and `refusing` joins a PostgreSQL transaction to a
//// verb-shaped helper.

import decisions
import decisions/occurrence
import decisions/policy.{Never, Proceed}
import decisions/store
import decisions/vocabulary.{Subject, Trigger}
import decisions_postgres
import decisions_postgres/queue
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import grind
import grind/job
import grind/worker
import kit
import pog
import support/policies

fn subject() -> vocabulary.Subject {
  Subject("person", kit.tag("ana"))
}

/// A held occurrence superseded by a newer event: nothing is released, its
/// hold's wake-up row is cancelled, and the job that arrives later finds
/// nothing pending.
pub fn a_held_occurrence_superseded_releases_nothing_test() {
  let #(name, store) = kit.store()
  let spec =
    kit.Spec(
      ..kit.spec("held_superseded"),
      policy: policies.checked(
        version: 1,
        rules: [
          policy.When(
            policy.Always,
            Proceed(sample: Never, hold: Some(duration.milliseconds(300))),
          ),
        ],
        otherwise: policy.AnyoneHolding("nobody"),
      ),
      superseded_by: ["closed"],
    )
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.delivering(), [decisions.waker(desk)], [])
  let about = subject()
  let assert Ok(held) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, about)))
  let assert occurrence.Held(..) = held.status
  let assert Ok(superseded) =
    kit.tx(env, decisions.happened(desk, _, "closed", about:))
  assert list.map(superseded.expired, fn(o) { o.id }) == [held.id]
  let assert Ok(wakes) = decisions_postgres.inspection().wakes(env.db)
  assert !list.any(wakes, fn(w) { w.occurrence == held.id })
  // The hold's job arrives at its time and does nothing.
  let assert [#("succeeded", 1)] = kit.finished_jobs(env, "decisions.wake")
  assert kit.effects_of(env.db, held.id) == 0
  let assert Ok(known) =
    kit.tx(env, decisions.read(desk, _, occurrence: held.id))
  let assert occurrence.Expired(_) = known.status
  kit.check(env, [desk])
}

/// The application's trigger job, as an application would define one.
fn trigger_worker() -> worker.Worker(String, String, Nil) {
  worker.new(
    "test.trigger",
    input: worker.codec(worker.infallible(json.string), decode.string),
    output: worker.codec(worker.infallible(json.string), decode.string),
    perform: fn(key) { Ok(key) },
  )
}

/// `expect` in the transaction that receives the trigger, with the
/// application's own row and its Grind job: all three commit together, or
/// none does.
pub fn expect_commits_with_the_application_row_and_job_test() {
  let #(name, store) = kit.store()
  let spec = kit.spec("expected")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let about = subject()
  let receive = fn(key, commit) {
    pog.transaction(env.db, fn(tx) {
      use Nil <- result.try(
        decisions.expect(
          desk,
          tx,
          key:,
          trigger: Trigger("message", key),
          about:,
        )
        |> result.map_error(decisions.describe),
      )
      let assert Ok(_) =
        pog.query(
          "INSERT INTO test_effects (point, occurrence, key) VALUES ($1, $2, 'trigger')",
        )
        |> pog.parameter(pog.text("app:" <> spec.name))
        |> pog.parameter(pog.text(key))
        |> pog.execute(tx)
      use _ <- result.try(
        grind.submit_in(
          env.jobs,
          tx,
          job.new(trigger_worker(), key) |> job.with_id("trigger:" <> key),
        )
        |> result.map_error(grind.describe_submit_error),
      )
      case commit {
        True -> Ok(Nil)
        False -> Error("the application changed its mind")
      }
    })
  }
  let kept = kit.tag("kept")
  let assert Ok(Nil) = receive(kept, True)
  let assert Ok(Some(head)) = decisions_postgres.inspection().head(env.db, kept)
  assert head.status == store.Pending
  assert kit.effects_of(env.db, kept) == 1
  assert list.length(kit.jobs(env, "test.trigger")) == 1
  // Safe to repeat.
  let assert Ok(Nil) =
    kit.tx(env, decisions.expect(
      desk,
      _,
      key: kept,
      trigger: Trigger("message", kept),
      about:,
    ))
  let assert Ok([_]) = decisions_postgres.port(store).load(env.db, kept)
  // Rolled back: no record, no row, no job.
  let dropped = kit.tag("dropped")
  let assert Error(_) = receive(dropped, False)
  let assert Ok(None) = decisions_postgres.inspection().head(env.db, dropped)
  assert kit.effects_of(env.db, dropped) == 0
  assert list.length(kit.jobs(env, "test.trigger")) == 1
}

/// An expected key superseded while the model runs: `happened` reports it
/// as not begun, and the late `recommend_once` is refused with
/// `SupersededBefore` and writes nothing.
pub fn an_expected_key_superseded_is_refused_at_recommend_once_test() {
  let #(name, store) = kit.store()
  let spec =
    kit.Spec(
      ..kit.spec("superseded_before"),
      policy: kit.proceed(),
      superseded_by: ["closed"],
    )
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let about = subject()
  let key = kit.tag("key")
  let assert Ok(Nil) =
    kit.tx(env, decisions.expect(
      desk,
      _,
      key:,
      trigger: Trigger("message", key),
      about:,
    ))
  // While the model runs, the newer event arrives.
  let assert Ok(superseded) =
    kit.tx(env, decisions.happened(desk, _, "closed", about:))
  assert superseded.not_begun == [key]
  let port = decisions_postgres.port(store)
  let assert Ok(before) = port.load(env.db, key)
  let assert Error(decisions_postgres.Refused(decisions.SupersededBefore(_))) =
    kit.tx(env, decisions.recommend_once(
      desk,
      _,
      key:,
      proposal: kit.proposal(spec.name, about),
    ))
  let assert Ok(after) = port.load(env.db, key)
  assert after == before
  assert kit.effects_of(env.db, key) == 0
  // It settled: one settlement notice, and the invariants hold.
  kit.check(env, [desk])
}

/// Pending records: one query finds those still expected and since when;
/// none is in a validator's queue; the counts name them.
pub fn pending_records_are_found_and_kept_out_of_queues_test() {
  let #(name, store) = kit.store()
  let spec = kit.spec("pending")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let keys =
    list.map(kit.int_range(3), fn(_) {
      let key = kit.tag("expected")
      let assert Ok(Nil) =
        kit.tx(env, decisions.expect(
          desk,
          _,
          key:,
          trigger: Trigger("message", key),
          about: subject(),
        ))
      key
    })
  let assert Ok(waiting) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert Ok([first, second]) =
    queue.pending(env.db, point: spec.name, limit: 2, after: None)
  let assert Ok(rest) =
    queue.pending(env.db, point: spec.name, limit: 10, after: Some(second))
  let found = list.map([first, second, ..rest], fn(r) { r.occurrence })
  assert found == keys
  assert list.all([first, second, ..rest], fn(r) { r.status == store.Pending })
  let validator = kit.finance(kit.tag("bia"))
  let assert Ok(page) =
    queue.page_at(
      env.db,
      point: spec.name,
      for: validator,
      limit: 50,
      after: None,
    )
  assert list.map(page, fn(c) { c.occurrence }) == [waiting.id]
  let assert Ok(counts) = queue.counts(env.db, spec.name)
  assert list.contains(counts, queue.Count(store.Pending, 3))
  kit.check(env, [desk])
}

/// A follower whose verb is refused with `SupersededBefore` has nothing
/// left to do: `handling` says `Drop`, and the notice ends delivered.
pub fn a_follower_that_meets_superseded_before_ends_done_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("before_follow"), policy: kit.proceed())
  let next =
    kit.Spec(..kit.spec("next_step"), policy: kit.proceed(), superseded_by: [
      "closed",
    ])
  let store = decisions_postgres.following(store, spec.name)
  let desk = kit.desk(store, spec)
  let next_desk = kit.desk(store, next)
  let about = subject()
  let next_key = kit.tag("next")
  let follower = #(spec.name, fn(tx, _id) {
    decisions.recommend_once(
      next_desk,
      tx,
      key: next_key,
      proposal: kit.proposal(next.name, about),
    )
    |> result.replace(Nil)
    |> result.map_error(decisions.DeskRefused)
  })
  use env <- kit.run(name, store, kit.delivering(), [], [follower])
  let assert Ok(Nil) =
    kit.tx(env, decisions.expect(
      next_desk,
      _,
      key: next_key,
      trigger: Trigger("message", next_key),
      about:,
    ))
  let assert Ok(_) =
    kit.tx(env, decisions.happened(next_desk, _, "closed", about:))
  let assert Ok(released) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, about)))
  let assert [#("succeeded", 1)] =
    kit.finished_jobs(env, "decisions.settlement")
  assert kit.scalar(
    env.db,
    "SELECT delivered_at IS NOT NULL AND set_aside_at IS NULL
     FROM decisions_settled WHERE occurrence_id = $1",
    [pog.text(released.id)],
    decode.bool,
  )
  kit.check(env, [desk, next_desk])
}

/// Issue 03: `refusing` is `transaction` in the shape of a verb. A refusal
/// comes back as it is; a failure of the transaction keeps its
/// classification.
pub fn refusing_keeps_refusals_and_store_classifications_test() {
  let #(name, store) = kit.store()
  // The store's own lock timeout, short, ends the wait below.
  let store =
    decisions_postgres.with_lock_timeout(store, Some(duration.milliseconds(50)))
  let spec = kit.spec("refusing")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let assert Error(decisions.UnknownOccurrence) =
    decisions_postgres.refusing(env.db, decisions.read(
      desk,
      _,
      occurrence: kit.tag("absent"),
    ))
  let assert Ok(made) =
    decisions_postgres.refusing(env.db, decisions.recommend(
      desk,
      _,
      kit.proposal(spec.name, kit.ana),
    ))
  // A lock held elsewhere, and a lock timeout: contention, kept as such.
  let port = decisions_postgres.port(store)
  let holder = process.new_subject()
  process.spawn_unlinked(fn() {
    let _ =
      pog.transaction(env.db, fn(tx) {
        let _ = port.load(tx, made.id)
        let release = process.new_subject()
        process.send(holder, release)
        let _ = process.receive(release, 10_000)
        Ok(Nil)
      })
      |> result.map_error(fn(_: pog.TransactionError(Nil)) { Nil })
    Nil
  })
  let assert Ok(release) = process.receive(holder, 5000)
  let assert Error(decisions.StoreFailed(store.Contended(detail))) =
    decisions_postgres.refusing(env.db, fn(tx) {
      decisions.read(desk, tx, occurrence: made.id)
    })
  assert string.contains(detail, "55P03")
  process.send(release, Nil)
}

/// A record superseded before it began still settles, so its point's
/// follower is handed its notice like any other. A follower that reads it
/// is refused with `SupersededBefore`; `handling` says `Drop`, so the
/// notice ends delivered and the job succeeds. Nothing is set aside.
pub fn a_notice_for_a_record_that_never_began_ends_done_test() {
  let #(name, store) = kit.store()
  let spec =
    kit.Spec(..kit.spec("never_began"), policy: kit.proceed(), superseded_by: [
      "closed",
    ])
  let store = decisions_postgres.following(store, spec.name)
  let desk = kit.desk(store, spec)
  let seen = process.new_subject()
  let follower = #(spec.name, fn(tx, id) {
    let read = decisions.read(desk, tx, occurrence: id)
    process.send(seen, read |> result.replace(Nil))
    read |> result.replace(Nil) |> result.map_error(decisions.DeskRefused)
  })
  use env <- kit.run(name, store, kit.delivering(), [], [follower])
  let about = subject()
  let key = kit.tag("never")
  let assert Ok(Nil) =
    kit.tx(env, decisions.expect(
      desk,
      _,
      key:,
      trigger: Trigger("message", key),
      about:,
    ))
  let assert Ok(superseded) =
    kit.tx(env, decisions.happened(desk, _, "closed", about:))
  assert superseded.not_begun == [key]
  let assert Ok(Error(decisions.SupersededBefore(_))) =
    process.receive(seen, 10_000)
  let assert [#("succeeded", 1)] =
    kit.finished_jobs(env, "decisions.settlement")
  assert kit.scalar(
    env.db,
    "SELECT delivered_at IS NOT NULL AND set_aside_at IS NULL
     FROM decisions_settled WHERE occurrence_id = $1",
    [pog.text(key)],
    decode.bool,
  )
  kit.check(env, [desk])
}

/// The Grind settlement worker hands the follower every notice, as the OTP
/// runtime does (ADR 0055): a record superseded before it began and one
/// lapsed at its own deadline each reach it once, and `read_record` reads
/// both as `NotBegun` with their cause. Each call writes one row in the
/// delivery's transaction, so a notice dropped or delivered twice shows.
pub fn every_notice_reaches_the_follower_as_not_begun_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("not_begun"), superseded_by: ["closed"])
  let store = decisions_postgres.following(store, spec.name)
  let desk = kit.desk(store, spec)
  // The follower's rows, kept apart from the gated tool's effects.
  let followed = spec.name <> ".followed"
  let follower = #(spec.name, fn(tx, id) {
    use record <- result.try(
      decisions.read_record(desk, tx, key: id)
      |> result.map_error(decisions.DeskRefused),
    )
    let handed = case record {
      decisions.NotBegun(pending) ->
        "not begun, " <> string.inspect(pending.ended)
      decisions.Begun(known) ->
        "begun, " <> occurrence.status_name(known.status)
    }
    pog.query(
      "INSERT INTO test_effects (occurrence, key, point) VALUES ($1, $2, $3)",
    )
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.text(handed))
    |> pog.parameter(pog.text(followed))
    |> pog.execute(tx)
    |> result.replace(Nil)
    |> result.map_error(fn(error) {
      decisions.ApplicationFailed(string.inspect(error))
    })
  })
  use env <- kit.run(name, store, kit.delivering(), [decisions.waker(desk)], [
    follower,
  ])
  let superseded = kit.tag("superseded")
  let lapsed = kit.tag("lapsed")
  let deadline =
    decisions_postgres.port(store).now(env.db)
    |> timestamp.add(duration.seconds(2))
  let assert Ok(Nil) =
    kit.tx(env, fn(tx) {
      use Nil <- result.try(decisions.expect(
        desk,
        tx,
        key: superseded,
        trigger: Trigger("message", superseded),
        about: Subject("person", superseded),
      ))
      use _ <- result.try(decisions.happened(
        desk,
        tx,
        "closed",
        about: Subject("person", superseded),
      ))
      decisions.expect_until(
        desk,
        tx,
        key: lapsed,
        trigger: Trigger("message", lapsed),
        about: Subject("person", lapsed),
        valid_until: deadline,
      )
    })
  let assert True =
    kit.eventually(10_000, fn() { kit.effects(env.db, followed) >= 2 })
  let assert [#("succeeded", 1), #("succeeded", 1)] =
    kit.finished_jobs(env, "decisions.settlement")
  let rows =
    kit.scalar(
      env.db,
      "SELECT coalesce(array_agg(occurrence || ' ' || key ORDER BY occurrence), '{}')
       FROM test_effects WHERE point = $1",
      [pog.text(followed)],
      decode.list(decode.string),
    )
  assert list.sort(rows, string.compare)
    == list.sort(
      [
        superseded <> " not begun, Some(Superseded(\"closed\"))",
        lapsed <> " not begun, Some(DeadlinePassed)",
      ],
      string.compare,
    )
  kit.check(env, [desk])
}
