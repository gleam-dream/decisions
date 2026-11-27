# A failure that wrote nothing is contention, and the store's clock can fail

<a id="adr-0069"></a>

Recorded on 2026-11-27.

## Decision

- The port's `now` returns `Result(Timestamp, StoreError)`. The desk turns its error into `StoreFailed`, as it does for every other port function.
- `decisions_postgres` reports as `Contended` three more failures in which nothing was written: a statement the server cancelled (`57014`, such as a `statement_timeout`), a statement in a transaction an earlier statement aborted (`25P02`), and a pool with no connection to give (`pog.ConnectionUnavailable`, raised before anything is sent).
- A notice delivery locks the notice's row with `FOR UPDATE SKIP LOCKED`. A row another transaction holds is a delivery in progress: the job snoozes. The sweep's re-admission skips such a row too.

## Why

- `Unavailable` tells the caller that the outcome is unknown and to read before retrying. In each of the three cases the transaction rolls back and nothing was committed, so `Contended`, "run it again", is the true answer.
- When the clock query failed, the PostgreSQL adapter returned the node's clock. The transaction was aborted by then, so the next write failed with `25P02`, hiding the first error; and a clock read that failed without aborting would have stamped entries with a time the store never gave.
- A follower that hangs holds its notice's row. Each replay of its job checked out a pool connection and waited on the same row with no lock timeout, so one hung follower could hold many connections of the shared pool.

## Alternatives

- **Keep `now` infallible and mark the transaction failed.** The port has no state to mark, and the desk would still stamp an entry with a time no store gave.
- **Set the store's lock timeout before locking the notice.** It bounds each wait, but a replay still holds a connection for up to the timeout, every time.

## What changes for consumers

- An adapter's `now` returns `Ok(time)`, or the store's error.
- A PostgreSQL caller that retried only `Contended` now also retries the three failures above, which were `Unavailable`.
