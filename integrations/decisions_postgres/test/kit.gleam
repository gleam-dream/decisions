//// Test support: the throwaway cluster `scripts/test-postgres.sh` starts,
//// a Grind runtime per test in a Grind schema of its own, a desk builder
//// over the PostgreSQL port, a gated tool that writes an effect row, real
//// processes and the invariant checker.

import decisions.{type Desk, type Gated, type Released, Gated}
import decisions/policy.{type Policy, AnyoneHolding, Never, Proceed}
import decisions/store
import decisions/testing
import decisions/vocabulary.{
  type Subject, type Validator, Manifest, OwnAct, Person, Recommendation,
  RuleFired, Rules, Subject, Trigger, Validator,
}
import decisions/wire
import decisions_postgres.{
  type Follower, type Pool, type Store, type Tx, type Waker,
}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp
import grind
import grind/queue
import grind/worker
import pog
import support/policies

@external(erlang, "kit_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "kit_ffi", "unique")
pub fn unique() -> Int

@external(erlang, "kit_ffi", "monotonic_us")
pub fn monotonic_us() -> Int

/// The reductions `pid` has run so far: a measure of its work.
@external(erlang, "kit_ffi", "reductions")
pub fn reductions(pid: process.Pid) -> Int

@external(erlang, "kit_ffi", "ensure")
fn ensure(body: fn() -> a, cleanup: fn() -> b) -> a

@external(erlang, "kit_ffi", "read_file")
pub fn read_file(path: String) -> Result(String, Nil)

/// True the first time it is called with `key` on this node.
@external(erlang, "kit_ffi", "once")
pub fn once(key: String) -> Bool

@external(erlang, "kit_ffi", "write_file")
pub fn write_file(path: String, text: String) -> Nil

@external(erlang, "kit_ffi", "quiet_pool_shutdown")
fn quiet_pool_shutdown() -> Nil

@external(erlang, "kit_ffi", "rescue")
pub fn rescue(body: fn() -> a) -> Result(a, String)

/// The throwaway cluster's URL. These tests run only through
/// `scripts/test-postgres.sh`, which sets it; without it they fail rather
/// than pass untested.
pub fn url() -> String {
  case getenv("DECISIONS_TEST_DATABASE_URL") {
    Ok(url) -> url
    Error(Nil) ->
      panic as "DECISIONS_TEST_DATABASE_URL is unset: run these tests with scripts/test-postgres.sh"
  }
}

/// A name no other test uses, for points, sets, keys and subjects.
pub fn tag(prefix: String) -> String {
  prefix <> "-" <> int.to_string(unique())
}

// -- The runtime -------------------------------------------------------------------

pub type Options {
  Options(
    pool_size: Int,
    /// `False`: nothing delivers jobs.
    consumers: Bool,
    concurrency: Int,
    /// Grind's storage deadline; the attempt lease is four times it.
    deadline: Duration,
  )
}

pub fn options() -> Options {
  Options(
    pool_size: 20,
    consumers: False,
    concurrency: 10,
    deadline: duration.seconds(4),
  )
}

pub fn delivering() -> Options {
  Options(..options(), consumers: True)
}

pub type Env {
  Env(
    jobs: grind.Grind,
    name: process.Name(grind.Message),
    /// The pool, for the package's transactions and reads.
    pool: Pool,
    /// The same pool as a pog connection, for the tests' own statements.
    db: pog.Connection,
    store: Store,
    config: pog.Config,
    schema: String,
  )
}

/// A Grind handle valid before its runtime starts, and a store over it, so
/// desks and their wakers can be built first.
pub fn store() -> #(process.Name(grind.Message), Store) {
  let name = process.new_name("decisions_test_grind")
  #(name, decisions_postgres.new(grind.named(name)))
}

pub fn pool_config(size: Int) -> pog.Config {
  let assert Ok(config) =
    pog.url_config(process.new_name("decisions_test_pool"), url())
  // A checkout waits in line instead of being dropped when every
  // connection is busy.
  config |> pog.pool_size(size) |> pog.queue_target(20_000)
}

/// Start a Grind runtime (which owns the pool) with the workers for these
/// wakers and followers, migrate, run `body`, and stop the runtime.
pub fn run(
  name: process.Name(grind.Message),
  store: Store,
  options: Options,
  wakers: List(Waker),
  followers: List(Follower),
  body: fn(Env) -> a,
) -> a {
  let env = start(name, store, options, wakers, followers, None)
  ensure(fn() { body(env) }, fn() { stop(env) })
}

/// `run` without the cleanup, in a Grind schema that may be reused, for a
/// restart.
pub fn start(
  name: process.Name(grind.Message),
  store: Store,
  options: Options,
  wakers: List(Waker),
  followers: List(Follower),
  schema: Option(String),
) -> Env {
  start_in(
    name,
    store,
    pool_config(options.pool_size),
    options,
    wakers,
    followers,
    schema,
    None,
  )
}

/// `start` with the package's tables in a schema of their own: the pool's
/// `search_path` names it, and it is created before `migrate` runs.
pub fn start_with(
  name: process.Name(grind.Message),
  store: Store,
  tables: String,
  options: Options,
  wakers: List(Waker),
  followers: List(Follower),
) -> Env {
  let config =
    pool_config(options.pool_size)
    |> pog.connection_parameter("search_path", tables)
  start_in(name, store, config, options, wakers, followers, None, Some(tables))
}

fn start_in(
  name: process.Name(grind.Message),
  store: Store,
  config: pog.Config,
  options: Options,
  wakers: List(Waker),
  followers: List(Follower),
  schema: Option(String),
  tables: Option(String),
) -> Env {
  quiet_pool_shutdown()
  let schema = option.unwrap(schema, "grind_" <> int.to_string(unique()))
  let lease =
    duration.milliseconds(4 * duration.to_milliseconds(options.deadline))
  let configured =
    grind.new(config)
    |> grind.with_schema(schema)
    |> grind.with_statement_deadline(options.deadline)
    |> grind.with_unique_lock_wait(duration.milliseconds(100))
    |> grind.with_worker(
      decisions_postgres.wake_worker(store, wakers)
      |> worker.with_retry_policy(fn(_, _) {
        worker.RetryAfter(duration.milliseconds(50))
      }),
    )
    |> grind.with_worker(
      decisions_postgres.settlement_worker(store, followers)
      |> worker.with_retry_policy(fn(_, _) {
        worker.RetryAfter(duration.milliseconds(50))
      }),
    )
    |> grind.with_queue(
      queue.new(decisions_postgres.default_queue)
      |> queue.with_concurrency(options.concurrency)
      |> queue.with_poll_interval(duration.milliseconds(50))
      |> queue.with_lease(lease)
      |> queue.with_shutdown_grace(duration.seconds(2)),
    )
    |> grind.with_startup_migration
    |> grind.without_pruner
  let configured = case options.consumers {
    True -> configured
    False -> grind.without_consumers(configured)
  }
  let assert Ok(jobs) = grind.start(configured, name)
  let db = grind.connection(jobs)
  case tables {
    Some(tables) -> {
      let assert Ok(_) =
        pog.query("CREATE SCHEMA IF NOT EXISTS \"" <> tables <> "\"")
        |> pog.execute(db)
      Nil
    }
    None -> Nil
  }
  let pool = decisions_postgres.pool(config.pool_name)
  let assert Ok(Nil) = decisions_postgres.migrate(pool)
  let assert Ok(_) =
    pog.query(
      "CREATE TABLE IF NOT EXISTS test_effects (
         point text NOT NULL, occurrence text NOT NULL, key text NOT NULL,
         written_at timestamptz NOT NULL DEFAULT clock_timestamp())",
    )
    |> pog.execute(db)
  Env(jobs:, name:, pool:, db:, store:, config:, schema:)
}

/// The jobs of a worker in this runtime's Grind schema, as
/// `#(state, delivery_count)`, oldest first.
pub fn jobs(env: Env, worker_id: String) -> List(#(String, Int)) {
  let assert Ok(returned) =
    pog.query(
      "SELECT state, delivery_count FROM \""
      <> env.schema
      <> "\".grind_jobs WHERE worker_id = $1 ORDER BY id",
    )
    |> pog.parameter(pog.text(worker_id))
    |> pog.returning({
      use state <- decode.field(0, decode.string)
      use count <- decode.field(1, decode.int)
      decode.success(#(state, count))
    })
    |> pog.execute(env.db)
  returned.rows
}

pub fn stop(env: Env) -> Nil {
  let _ = grind.stop(env.jobs)
  Nil
}

// -- Desks -------------------------------------------------------------------------

pub const ana = Subject(kind: "person", id: "ana")

pub fn finance(subject: String) -> Validator {
  Validator(subject:, holds: ["finance"])
}

pub fn ask() -> Policy {
  policies.checked(version: 1, rules: [], otherwise: AnyoneHolding("finance"))
}

pub fn proceed() -> Policy {
  policies.checked(
    version: 1,
    rules: [policy.When(policy.Always, Proceed(sample: Never, hold: None))],
    otherwise: policy.AnyoneHolding("nobody"),
  )
}

pub type Spec {
  Spec(
    name: String,
    policy: Policy,
    hold: Option(Duration),
    validity: Option(Duration),
    superseded_by: List(String),
    /// What the gated tool's executor does.
    execute: fn(Tx, Released(String)) -> Result(Nil, vocabulary.Stop),
  )
}

/// A point that asks finance, with no hold and no validity, whose tool
/// records one effect row per release.
pub fn spec(prefix: String) -> Spec {
  Spec(
    name: tag(prefix),
    policy: ask(),
    hold: None,
    validity: None,
    superseded_by: [],
    execute: record_effect,
  )
}

pub fn desk(store: Store, spec: Spec) -> Desk(String, Tx) {
  desk_over(decisions_postgres.port(store), spec)
}

/// A desk over a port a test changed, such as one with a skewed clock.
pub fn desk_over(port: store.Port(Tx), spec: Spec) -> Desk(String, Tx) {
  let point = decisions.point(spec.name, wire.text())
  let point = case spec.hold {
    Some(hold) -> decisions.with_hold(point, hold)
    None -> point
  }
  let point = case spec.validity {
    Some(validity) -> decisions.valid_for(point, validity)
    None -> point
  }
  let point =
    list.fold(spec.superseded_by, point, fn(point, event) {
      decisions.superseded_by(point, event)
    })
  decisions.desk(
    point,
    drives: fn(_) { tool(spec) },
    under: fn(_) { Ok(spec.policy) },
    over: port,
  )
}

fn tool(spec: Spec) -> Gated(String, Tx) {
  Gated(name: "test_tool", guard: fn(_, _) { Ok([]) }, execute: spec.execute)
}

/// The executor of most test points: one row in `test_effects`.
pub fn record_effect(
  tx: Tx,
  released: Released(String),
) -> Result(Nil, vocabulary.Stop) {
  pog.query(
    "INSERT INTO test_effects (occurrence, key, point) VALUES ($1, $2, $3)",
  )
  |> pog.parameter(pog.text(decisions.occurrence_of(released)))
  |> pog.parameter(pog.text(decisions.key(released)))
  |> pog.parameter(pog.text(point_of_key(released)))
  |> pog.execute(decisions_postgres.connection(tx))
  |> result.replace(Nil)
  |> result.map_error(fn(error) {
    vocabulary.Refuse(decisions_postgres_describe(error))
  })
}

fn point_of_key(released: Released(String)) -> String {
  // The output text carries the point name in these tests.
  case string.split_once(decisions.output(released), "@") {
    Ok(#(point, _)) -> point
    Error(Nil) -> ""
  }
}

fn decisions_postgres_describe(error: pog.QueryError) -> String {
  string.inspect(error)
}

/// A proposal whose output names the point, so the tool can file its
/// effect under it.
pub fn proposal(
  point: String,
  about subject: Subject,
) -> decisions.Proposal(String) {
  decisions.proposal(
    trigger: Trigger("test", tag("trigger")),
    about: subject,
    context: Manifest(refs: [], renderer: "test-1"),
    recommending: Recommendation(
      output: point <> "@" <> tag("output"),
      by: Rules("test", "1"),
      explanation: RuleFired("test"),
      signals: [],
      reads: [],
    ),
  )
}

/// A proposal that is `person`'s own act, so they may withdraw it while
/// it is held.
pub fn own_act(
  point: String,
  by person: String,
  about subject: Subject,
) -> decisions.Proposal(String) {
  decisions.proposal(
    trigger: Trigger("test", tag("trigger")),
    about: subject,
    context: Manifest(refs: [], renderer: "test-1"),
    recommending: Recommendation(
      output: point <> "@" <> tag("output"),
      by: Person(person),
      explanation: OwnAct,
      signals: [],
      reads: [],
    ),
  )
}

/// How many effect rows a point's tool wrote.
pub fn effects(db: pog.Connection, point: String) -> Int {
  let assert Ok(pog.Returned(rows: [count], ..)) =
    pog.query("SELECT count(*) FROM test_effects WHERE point = $1")
    |> pog.parameter(pog.text(point))
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(db)
  count
}

/// The effect rows of one occurrence.
pub fn effects_of(db: pog.Connection, occurrence: String) -> Int {
  let assert Ok(pog.Returned(rows: [count], ..)) =
    pog.query("SELECT count(*) FROM test_effects WHERE occurrence = $1")
    |> pog.parameter(pog.text(occurrence))
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(db)
  count
}

/// I1 to I8 over these desks, counting each point's effect rows.
pub fn check(env: Env, desks: List(Desk(String, Tx))) -> testing.Summary {
  let audits =
    list.map(desks, fn(desk) {
      let point = decisions.name(decisions.point_of(desk))
      testing.audit(desk, effects: fn(tx) {
        Ok(effects(decisions_postgres.connection(tx), point))
      })
    })
  let checked =
    decisions_postgres.transaction_with(env.pool, fn(tx) {
      testing.check(tx, decisions_postgres.inspection(), audits)
      |> result.map_error(decisions_postgres.Own)
    })
  case checked {
    Ok(summary) -> summary
    Error(failed) -> panic as string.inspect(failed)
  }
}

/// Run `body` in a transaction on the pool.
pub fn tx(
  env: Env,
  body: fn(Tx) -> Result(a, decisions.Refusal),
) -> Result(a, decisions_postgres.Failure) {
  decisions_postgres.transaction(env.pool, body)
}

/// Open and decide in one transaction.
pub fn open_and_decide(
  desk: Desk(String, Tx),
  tx: Tx,
  id: String,
  validator: Validator,
  verdict: vocabulary.Verdict(String),
) {
  use card <- result.try(
    decisions.open(desk, tx, occurrence: id, by: validator, latest: fn(ref) {
      ref.revision
    }),
  )
  decisions.decide(desk, tx, card, verdict)
}

/// Run `work` in `count` processes started at once, and collect their
/// results in any order, waiting at most `within` milliseconds for each.
pub fn race(count: Int, within: Int, work: fn(Int) -> a) -> List(a) {
  let results = process.new_subject()
  let ready = process.new_subject()
  list.each(int_range(count), fn(n) {
    process.spawn(fn() {
      let go = process.new_subject()
      process.send(ready, go)
      let _ = process.receive(go, 60_000)
      process.send(results, work(n))
    })
  })
  let gates =
    list.map(int_range(count), fn(_) {
      let assert Ok(go) = process.receive(ready, 10_000)
      go
    })
  list.each(gates, fn(go) { process.send(go, Nil) })
  list.map(gates, fn(_) {
    let assert Ok(result) = process.receive(results, within)
    result
  })
}

/// 0, 1, ..., count - 1.
pub fn int_range(count: Int) -> List(Int) {
  int.range(from: 0, to: count, with: [], run: fn(acc, n) { [n, ..acc] })
  |> list.reverse
}

/// Wait until `ready` holds, checking every 20 ms, at most `within` ms.
pub fn eventually(within: Int, ready: fn() -> Bool) -> Bool {
  until(monotonic_us() + within * 1000, ready)
}

fn until(deadline_us: Int, ready: fn() -> Bool) -> Bool {
  case ready() {
    True -> True
    False ->
      case monotonic_us() >= deadline_us {
        True -> False
        False -> {
          process.sleep(20)
          until(deadline_us, ready)
        }
      }
  }
}

/// Wait until the store's clock (`port.now`) reaches `at`: the positive
/// observation a test makes before a hold or a deadline is over, instead
/// of sleeping for a guessed time.
pub fn wait_for_store_clock(env: Env, at: timestamp.Timestamp) -> Nil {
  let port = decisions_postgres.port(env.store)
  let assert True =
    eventually(10_000, fn() {
      let assert Ok(now) = within(env, port.now)
      timestamp.compare(now, at) != order.Lt
    })
  Nil
}

/// Wait until every job of `worker_id` has left the pending states
/// (Grind acknowledges a job after the handler's own transaction
/// committed), then return them.
pub fn finished_jobs(env: Env, worker_id: String) -> List(#(String, Int)) {
  let finished = fn(state) {
    state == "succeeded"
    || state == "discarded"
    || state == "cancelled"
    || state == "business_failed"
    || state == "runtime_failed"
  }
  let assert True =
    eventually(10_000, fn() {
      list.all(jobs(env, worker_id), fn(job) { finished(job.0) })
    })
  jobs(env, worker_id)
}

/// One scalar from a query.
pub fn scalar(
  db: pog.Connection,
  sql: String,
  parameters: List(pog.Value),
  decoder: decode.Decoder(a),
) -> a {
  let query =
    list.fold(parameters, pog.query(sql), fn(query, value) {
      pog.parameter(query, value)
    })
  let assert Ok(pog.Returned(rows: [value], ..)) =
    query |> pog.returning(decode.at([0], decoder)) |> pog.execute(db)
  value
}

/// A lock timeout of `milliseconds`, at least one.
pub fn lock_timeout(milliseconds: Int) -> store.LockTimeout {
  let assert Ok(timeout) = store.lock_timeout(milliseconds:)
  timeout
}

/// The store's clock (`port.now`), read in a transaction of its own.
pub fn now(env: Env) -> timestamp.Timestamp {
  let port = decisions_postgres.port(env.store)
  let assert Ok(now) = within(env, port.now)
  now
}

/// Run `body` in a transaction of its own and return what it returned: a
/// port call or an inspection a test makes outside a verb.
pub fn within(env: Env, body: fn(Tx) -> a) -> a {
  let assert Ok(value) =
    decisions_postgres.transaction(env.pool, fn(tx) { Ok(body(tx)) })
  value
}

/// Run `body`, whose error is the test's own, in a transaction on the
/// pool: commit on `Ok`, roll back on `Error`.
pub fn own(
  env: Env,
  body: fn(Tx) -> Result(a, e),
) -> Result(a, decisions_postgres.Failed(e)) {
  decisions_postgres.transaction_with(env.pool, fn(tx) {
    body(tx) |> result.map_error(decisions_postgres.Own)
  })
}
