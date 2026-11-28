# A worker's settlement joins Grind's transaction

<a id="adr-0074"></a>

Recorded on 2026-11-28.

## Decision

- `decisions_postgres.with_settlement(worker, settle)` wraps `grind/worker.with_settlement`. Grind settles a job that an abandoned attempt left `uncertain` in a transaction it opened on the runtime's pool, with the job's row locked; `with_settlement` hands that transaction to `settle` as a `Tx`. A verb, the application's own writes on `connection(tx)`, a `grind.submit_in` and Grind's decision then commit together, or none of them does.
- `Tx` is still made only by this package: by its transaction helpers, its workers and `with_settlement`. There is no way to turn an arbitrary `pog.Connection` into a `Tx`.

## Why

- An application whose payment job is abandoned past its replays wants its settlement to tell the decision record that the outcome is uncertain, and to queue the lookup that settles it. Since ADR 0063 a verb needs a `Tx`, which only a transaction on the pool gave, so the report ran in a second transaction. When the settlement then failed and Grind rolled its decision back, the report stayed: a test that reported and then failed the first settlement try found `Some(Uncertain(..))` on the record while Grind still held the job uncertain. Each later try reported again.
- The package already ran its own two workers' settlements in Grind's transaction (the wake-up and notice rows are set aside with Grind's decision); an application's worker could not do the same.

## Alternatives

- **A general `join(connection, body)` that wraps any `pog.Connection` as a `Tx`.** It would cover any runtime that opens a transaction, but a pool passed by mistake would bring back what ADR 0063 removed: `load` locking for one statement and the release committing apart from its entry. Telling a pool from a transaction's connection at run time is possible, but ADR 0063 rejected run-time refusal for exactly this shape: the misuse would surface only in production. `with_settlement` can only be handed Grind's settlement transaction.
- **Leave it to the application.** Its settlement would keep two transactions, and each retried try would add a report.

## What changes for consumers

- `decisions_postgres` (next release): a worker whose settlement runs verbs uses `decisions_postgres.with_settlement` in place of `worker.with_settlement`, and runs the verbs on the `Tx` it is given. Grind's rules for `settle` apply: short writes, no commit or rollback, and it may run again. The transaction holds the job's row before a verb locks the occurrence, so a transaction that locked the occurrence must not resolve the same job.
