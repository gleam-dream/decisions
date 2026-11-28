//// An application's worker whose abandoned job Grind settles reports to
//// the decision record in Grind's own settlement transaction: the report
//// and Grind's decision commit together, or neither does.
////
//// The job is abandoned as `abandoned_test` does it: claimed for a node
//// that never runs it, with its lease already expired, and moved by
//// Grind's own `quarantine_expired`. Settlements run through
//// `admin.settle_due`.

import decisions
import decisions/occurrence
import decisions/vocabulary.{Uncertain}
import decisions_postgres
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import grind
import grind/abandoned
import grind/admin
import grind/job
import grind/worker
import kit
import pog

const reason = "the pay attempt was abandoned"

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

fn settle(env: kit.Env) -> Nil {
  let assert Ok(_) =
    admin.settle_due(
      env.jobs,
      queue: decisions_postgres.default_queue,
      limit: 100,
    )
  Nil
}

fn job_state(env: kit.Env, job: Int) -> String {
  kit.scalar(
    env.db,
    "SELECT state FROM \"" <> env.schema <> "\".grind_jobs WHERE id = $1",
    [pog.int(job)],
    decode.string,
  )
}

fn pay_worker(
  settle: fn(decisions_postgres.Tx, abandoned.Abandoned(String)) ->
    Result(worker.Settlement(String, String), String),
) -> worker.Worker(String, String, String) {
  let text = worker.codec(worker.infallible(json.string), decode.string)
  worker.responding("test.pay", input: text, output: text, handle: fn(_, _) {
    worker.Succeeded("paid")
  })
  |> worker.with_error_codec(text)
  |> worker.with_queue(decisions_postgres.default_queue)
  |> worker.with_abandonment(worker.ReplayAfterLeaseExpiry(max_replays: 1))
  |> decisions_postgres.with_settlement(settle)
}

/// The first settlement try reports and then fails, so Grind rolls its
/// decision back; the second reports and confirms the failure.
pub fn a_settlement_reports_in_grinds_transaction_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("grind_settlement"), policy: kit.proceed())
  let desk = kit.desk(store, spec)
  let configure = fn(config) {
    grind.with_worker(
      config,
      pay_worker(fn(tx, job) {
        use _ <- result.try(
          decisions.report(
            desk,
            tx,
            occurrence: abandoned.input(job),
            effect: Uncertain(reason),
          )
          |> result.map_error(decisions.describe),
        )
        case abandoned.try_number(job) {
          1 -> Error("the provider cannot be asked yet")
          _ -> Ok(worker.ConfirmFailure(reason))
        }
      }),
    )
  }
  use env <- kit.run_configured(name, store, kit.options(), configure)
  let assert Ok(released) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert Ok(grind.Inserted(handle)) =
    grind.submit(
      env.jobs,
      job.new(pay_worker(fn(_, _) { Error("unused") }), released.id),
    )
  let job = job.id(handle)
  // One replay, then the next abandonment holds the job uncertain.
  abandon(env, job)
  abandon(env, job)
  assert job_state(env, job) == "uncertain"
  let reported = fn() {
    let assert Ok(known) =
      kit.tx(env, decisions.read(desk, _, occurrence: released.id))
    occurrence.effect(known)
  }
  settle(env)
  // Grind kept no decision, so neither does the record.
  assert job_state(env, job) == "uncertain"
  assert reported() == None
  // Grind waits a lease before the next try; make it due now.
  let assert Ok(_) =
    pog.query("UPDATE \"" <> env.schema <> "\".grind_jobs
       SET settle_at = clock_timestamp() WHERE id = $1")
    |> pog.parameter(pog.int(job))
    |> pog.execute(env.db)
  settle(env)
  assert job_state(env, job) == "business_failed"
  assert reported() == Some(Uncertain(reason))
}
