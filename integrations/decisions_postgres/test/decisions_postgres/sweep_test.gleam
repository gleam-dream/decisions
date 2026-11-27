//// `sweep` over many pending rows: its cost is a few reads per batch of
//// rows, not reads per row, and it still finds every row without a job.

import decisions
import decisions_postgres
import gleam/dynamic/decode
import gleam/list
import gleam/option.{Some}
import gleam/time/duration
import kit
import pog

/// Six hundred awaiting occurrences, each with a pending wake-up whose
/// Grind job is scheduled, and two rows, the last ones, whose job was
/// never recorded. The sweep admits a job for those two only, and the
/// statements it sends grow with the batches, not with the rows.
pub fn sweep_reads_pending_rows_in_batches_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("swept"), validity: Some(duration.hours(1)))
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  list.each(kit.int_range(600), fn(_) {
    let assert Ok(_) =
      kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  })
  let assert Ok(_) =
    pog.query(
      "UPDATE decisions_wakes SET job_id = NULL
       WHERE id IN (SELECT id FROM decisions_wakes WHERE point = $1
                    ORDER BY id DESC LIMIT 2)",
    )
    |> pog.parameter(pog.text(spec.name))
    |> pog.execute(env.db)
  let assert Ok(_) =
    pog.query("CREATE EXTENSION IF NOT EXISTS pg_stat_statements")
    |> pog.execute(env.db)
  let assert Ok(_) =
    pog.query("SELECT 1 FROM (SELECT pg_stat_statements_reset()) AS reset")
    |> pog.execute(env.db)
  let assert Ok(swept) = decisions_postgres.sweep(store, env.pool)
  let statements =
    kit.scalar(
      env.db,
      "SELECT coalesce(sum(calls), 0)::bigint FROM pg_stat_statements
       WHERE query NOT ILIKE '%pg_stat_statements%'",
      [],
      decode.int,
    )
  assert swept
    == decisions_postgres.Swept(wakes: 2, notices: 0, left_uncertain: [])
  // Before batching: two Grind reads for each of the 600 rows.
  assert statements < 100
}
