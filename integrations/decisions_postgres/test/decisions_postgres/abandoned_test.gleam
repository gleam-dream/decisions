//// A wake-up or notice whose Grind job an abandoned attempt left
//// `uncertain`: the workers' declared settlement replays it a bounded
//// number of times and then sets its row aside, and `sweep` tells a job a
//// settlement will still decide from one left for a person.
////
//// An attempt is abandoned by claiming the job for a node that never runs
//// it, with a lease already expired on the database's clock, and letting
//// Grind's own `quarantine_expired` apply the worker's abandonment policy,
//// as Grind's tests do. Settlements run through `admin.settle_due`, since
//// these runtimes have no consumers. No test waits for a lease.

import decisions
import decisions_postgres
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, Some}
import gleam/string
import gleam/time/duration
import grind
import grind/admin
import kit
import pog

/// The replays `ReplayAfterLeaseExpiry` gives both workers: the job is
/// held uncertain when the attempt after the last replay is abandoned.
const replays = 10

/// The replays the workers' settlement authorises before it gives up.
const authorized = 3

/// Claim `job` for a node that never runs it, with its lease already
/// expired, and let Grind move the attempt to its abandonment outcome.
fn abandon(env: kit.Env, job: Int) -> Nil {
  let schema = "\"" <> env.schema <> "\""
  let assert Ok(pog.Returned(count: 1, ..)) =
    pog.query("UPDATE " <> schema <> ".grind_jobs
       SET state = 'executing',
           attempt_id = nextval('" <> schema <> ".grind_attempts_id_seq'),
           attempt_epoch = attempt_epoch + 1,
           attempt_owner = 'a node that died',
           lease_expires_at = clock_timestamp() - interval '1 millisecond',
           attempt_count = attempt_count + 1,
           delivery_count = delivery_count + 1
       WHERE id = $1 AND state IN ('queued', 'scheduled', 'retryable')")
    |> pog.parameter(pog.int(job))
    |> pog.execute(env.db)
  let assert Ok(_) = admin.quarantine_expired(env.jobs, limit: 100)
  Nil
}

/// Abandon `job` until its replays are used up and Grind holds it
/// uncertain.
fn abandon_for_good(env: kit.Env, job: Int) -> Nil {
  list.each(kit.int_range(replays + 1), fn(_) { abandon(env, job) })
  assert job_state(env, job) == "uncertain"
}

/// One settlement try for each due job of the store's queue.
fn settle(env: kit.Env) -> Nil {
  let assert Ok(_) =
    admin.settle_due(
      env.jobs,
      queue: decisions_postgres.default_queue,
      limit: 100,
    )
  Nil
}

/// End the job's settlement mark, as a settlement that left the job for a
/// person, or one Grind declined, does.
fn leave_for_a_person(env: kit.Env, job: Int) -> Nil {
  let assert Ok(pog.Returned(count: 1, ..)) =
    pog.query("UPDATE \"" <> env.schema <> "\".grind_jobs SET settle_at = NULL
       WHERE id = $1 AND state = 'uncertain'")
    |> pog.parameter(pog.int(job))
    |> pog.execute(env.db)
  Nil
}

/// Waiting to be delivered again: queued, or scheduled for the wake-up's
/// time.
fn replayed(state: String) -> Bool {
  state == "queued" || state == "scheduled"
}

fn job_state(env: kit.Env, job: Int) -> String {
  kit.scalar(
    env.db,
    "SELECT state FROM \"" <> env.schema <> "\".grind_jobs WHERE id = $1",
    [pog.int(job)],
    decode.string,
  )
}

/// The job's stored error, or its description.
fn job_reason(env: kit.Env, job: Int) -> String {
  kit.scalar(env.db, "SELECT COALESCE(error #>> '{}', failure_description, '')
     FROM \"" <> env.schema <> "\".grind_jobs WHERE id = $1", [pog.int(job)], decode.string)
}

/// The wake-up row of an occurrence: its job and its set-aside reason.
fn wake_row(env: kit.Env, occurrence: String) -> #(Int, Option(String)) {
  row(
    env,
    "SELECT job_id, set_aside_reason FROM decisions_wakes
     WHERE occurrence_id = $1",
    occurrence,
  )
}

/// The undelivered notice row of an occurrence: its job and its set-aside
/// reason.
fn notice_row(env: kit.Env, occurrence: String) -> #(Int, Option(String)) {
  row(
    env,
    "SELECT job_id, set_aside_reason FROM decisions_settled
     WHERE occurrence_id = $1 AND delivered_at IS NULL",
    occurrence,
  )
}

fn row(
  env: kit.Env,
  sql: String,
  occurrence: String,
) -> #(Int, Option(String)) {
  let assert Ok(pog.Returned(rows: [found], ..)) =
    pog.query(sql)
    |> pog.parameter(pog.text(occurrence))
    |> pog.returning({
      use job <- decode.field(0, decode.int)
      use reason <- decode.field(1, decode.optional(decode.string))
      decode.success(#(job, reason))
    })
    |> pog.execute(env.db)
  found
}

/// A point with a wake-up an hour away, whose job no consumer runs.
fn held_spec() -> kit.Spec {
  kit.Spec(
    ..kit.spec("abandoned_wake"),
    policy: kit.proceed(),
    hold: Some(duration.hours(1)),
  )
}

/// A held occurrence, its desk's waker, and its wake-up's job.
fn with_wake_up(
  body: fn(kit.Env, decisions_postgres.Store, String, Int) -> a,
) -> a {
  let #(name, store) = kit.store()
  let spec = held_spec()
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [decisions.waker(desk)], [])
  let assert Ok(waiting) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let #(job, _) = wake_row(env, waiting.id)
  body(env, store, waiting.id, job)
}

/// A settled occurrence of a followed point, and its notice's job.
fn with_notice(
  body: fn(kit.Env, decisions_postgres.Store, String, Int) -> a,
) -> a {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("abandoned_notice"), policy: kit.proceed())
  let store = decisions_postgres.following(store, spec.name)
  let desk = kit.desk(store, spec)
  let follower = #(spec.name, fn(_tx, _id) { Ok(Nil) })
  use env <- kit.run(name, store, kit.options(), [], [follower])
  let assert Ok(released) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let #(job, _) = notice_row(env, released.id)
  body(env, store, released.id, job)
}

// -- The settlement ---------------------------------------------------------------

/// Delivery is idempotent, so an abandoned wake-up whose row is still
/// pending is delivered again: the settlement authorises a replay.
pub fn an_abandoned_wake_up_is_replayed_test() {
  use env, _store, occurrence, job <- with_wake_up
  abandon_for_good(env, job)
  settle(env)
  assert replayed(job_state(env, job))
  assert wake_row(env, occurrence) == #(job, option.None)
}

/// After the bounded number of authorised replays, the next abandonment
/// sets the wake-up's row aside, in the settlement's transaction, and
/// ends the job failed with the same reason.
pub fn a_wake_up_abandoned_past_the_bound_is_set_aside_test() {
  use env, _store, occurrence, job <- with_wake_up
  abandon_for_good(env, job)
  list.each(kit.int_range(authorized), fn(_) {
    settle(env)
    assert replayed(job_state(env, job))
    // No replay is left under the abandonment policy: one abandonment
    // holds it uncertain again.
    abandon(env, job)
    assert job_state(env, job) == "uncertain"
  })
  settle(env)
  assert job_state(env, job) == "business_failed"
  let assert #(_, Some(reason)) = wake_row(env, occurrence)
  assert string.contains(reason, "abandoned")
  assert string.contains(job_reason(env, job), "abandoned")
}

/// The same bound for a settlement notice.
pub fn a_notice_abandoned_past_the_bound_is_set_aside_test() {
  use env, _store, occurrence, job <- with_notice
  abandon_for_good(env, job)
  list.each(kit.int_range(authorized), fn(_) {
    settle(env)
    assert job_state(env, job) == "queued"
    abandon(env, job)
    assert job_state(env, job) == "uncertain"
  })
  settle(env)
  assert job_state(env, job) == "business_failed"
  let assert #(_, Some(reason)) = notice_row(env, occurrence)
  assert string.contains(reason, "abandoned")
}

/// A row no longer pending (here: the wake-up was cancelled) leaves
/// nothing to deliver: the job ends succeeded, as a delivery that finds
/// nothing pending does.
pub fn an_abandoned_wake_up_with_nothing_pending_succeeds_test() {
  use env, _store, occurrence, job <- with_wake_up
  abandon_for_good(env, job)
  let assert Ok(_) =
    pog.query("DELETE FROM decisions_wakes WHERE occurrence_id = $1")
    |> pog.parameter(pog.text(occurrence))
    |> pog.execute(env.db)
  settle(env)
  assert job_state(env, job) == "succeeded"
}

/// Grind declines a replay under a pending cancellation, so the
/// settlement does not ask for one: the job ends failed, the row stays
/// pending, and `sweep` gives it a new job, since the row is the authority.
pub fn a_cancelled_abandoned_wake_up_ends_and_sweep_replaces_it_test() {
  use env, store, occurrence, job <- with_wake_up
  abandon_for_good(env, job)
  let assert Ok(handle) =
    grind.bind(env.jobs, decisions_postgres.wake_worker(store, []), job)
  let assert Ok(grind.AlreadyUncertain) = grind.cancel(env.jobs, handle)
  settle(env)
  assert job_state(env, job) == "business_failed"
  assert string.contains(job_reason(env, job), "cancellation")
  assert wake_row(env, occurrence) == #(job, option.None)
  let assert Ok(_) = decisions_postgres.sweep(store, env.db)
  let #(replacement, _) = wake_row(env, occurrence)
  assert replacement != job
  assert job_state(env, replacement) == "scheduled"
}

// -- The sweep --------------------------------------------------------------------

/// A job held uncertain whose settlement is still due is left alone: the
/// declared settlement decides it.
pub fn sweep_leaves_a_job_its_settlement_will_decide_test() {
  use env, store, occurrence, job <- with_wake_up
  abandon_for_good(env, job)
  let assert Ok(swept) = decisions_postgres.sweep(store, env.db)
  assert wake_row(env, occurrence) == #(job, option.None)
  assert !list.contains(swept.left_uncertain, job)
  assert job_state(env, job) == "uncertain"
}

/// A wake-up whose job is held uncertain for a person is not live work:
/// nothing would deliver it again, so `sweep` gives its pending row a new
/// job and reports the uncertain one.
pub fn sweep_replaces_a_wake_up_job_left_for_a_person_test() {
  use env, store, occurrence, job <- with_wake_up
  abandon_for_good(env, job)
  leave_for_a_person(env, job)
  let assert Ok(swept) = decisions_postgres.sweep(store, env.db)
  let #(replacement, _) = wake_row(env, occurrence)
  assert replacement != job
  assert job_state(env, replacement) == "scheduled"
  assert list.contains(swept.left_uncertain, job)
}

/// The same for a settlement notice of a followed point.
pub fn sweep_replaces_a_notice_job_left_for_a_person_test() {
  use env, store, occurrence, job <- with_notice
  abandon_for_good(env, job)
  leave_for_a_person(env, job)
  let assert Ok(swept) = decisions_postgres.sweep(store, env.db)
  let #(replacement, _) = notice_row(env, occurrence)
  assert replacement != job
  assert job_state(env, replacement) == "queued"
  assert list.contains(swept.left_uncertain, job)
}
