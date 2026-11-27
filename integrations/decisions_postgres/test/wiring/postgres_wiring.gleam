//// How an application wires `decisions_postgres`, as the repository
//// README quotes it (region `postgres-wiring`). `wiring_test` runs it
//// against the test cluster.

import decisions
import decisions/policy.{AnyoneHolding}
import decisions/wire
import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import gleam/result
import grind
import pog

// snips-start: postgres-wiring
import decisions_postgres

/// The running pieces an application keeps.
pub type Wired {
  Wired(
    db: pog.Connection,
    refunds: decisions.Desk(String, pog.Connection),
    store: decisions_postgres.Store,
  )
}

/// At deploy time, with a role that may own DDL: bring the tables up to
/// date before any worker polls. Here on a pool of its own, closed after.
pub fn migrate_at_deploy(pool: pog.Config) -> Result(Nil, String) {
  let pool = pog.Config(..pool, pool_name: process.new_name("migrate"))
  use started <- result.try(
    pog.start(pool) |> result.replace_error("no database to migrate"),
  )
  let migrated =
    decisions_postgres.migrate(started.data)
    |> result.map_error(decisions_postgres.describe_migrate_error)
  process.unlink(started.pid)
  process.kill(started.pid)
  migrated
}

/// Start-up, after the migration: (1) a Grind handle by name, valid before
/// Grind runs; (2) the store over it and the desks over the store's port;
/// (3) Grind's configuration with the wake and settlement workers, which
/// must be registered before Grind starts; (4) Grind in the application's
/// supervision tree; (5) `sweep`, so every pending wake-up and notice has
/// a job.
pub fn start(pool: pog.Config) -> Result(Wired, String) {
  let name = process.new_name("app_grind")
  let jobs = grind.named(name)
  let store =
    decisions_postgres.new(jobs)
    |> decisions_postgres.with_name("billing")
    |> decisions_postgres.following("billing.fee_refund")
  let refunds =
    decisions.desk(
      decisions.point("billing.fee_refund", wire.text()),
      drives: refund_tool,
      under: fn(_) {
        policy.new(version: 1, rules: [], otherwise: AnyoneHolding("finance"))
        |> result.replace_error("the policy is malformed")
      },
      over: decisions_postgres.port(store),
    )
  let config =
    grind.new(pool)
    |> grind.with_worker(
      decisions_postgres.wake_worker(store, [decisions.waker(refunds)]),
    )
    |> grind.with_worker(
      decisions_postgres.settlement_worker(store, [
        #("billing.fee_refund", notify_customer),
      ]),
    )
    |> grind.with_startup_migration
  use _ <- result.try(
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(grind.supervised(config, name))
    |> supervisor.start
    |> result.replace_error("the supervision tree did not start"),
  )
  let db = grind.connection(jobs)
  use _ <- result.try(
    decisions_postgres.sweep(store, db)
    |> result.replace_error("the sweep could not read the store"),
  )
  Ok(Wired(db:, refunds:, store:))
}

// snips-end: postgres-wiring

fn refund_tool(_output: String) -> decisions.Gated(String, pog.Connection) {
  decisions.Gated(
    name: "refund_fee",
    guard: fn(_, _) { Ok([]) },
    execute: fn(_, _) { Ok(Nil) },
  )
}

fn notify_customer(
  _tx: pog.Connection,
  _occurrence: String,
) -> Result(Nil, decisions.HandlerFailure) {
  Ok(Nil)
}
