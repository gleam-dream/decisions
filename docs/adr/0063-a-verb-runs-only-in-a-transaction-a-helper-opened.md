# A verb runs only in a transaction that a transaction helper opened

<a id="adr-0063"></a>

Recorded on 2026-11-27.

## Decision

- Each integration's port takes a transaction type that only its transaction helpers construct. In `decisions_otp/store`, `Tx` is made only by `transaction`; `handle` and `store_of` are removed. In `decisions_postgres`, `Tx` is opaque and wraps the connection of a transaction the package opened: `transaction`, `transaction_with`, `refusing`, `decide` and the two workers construct it. `connection(tx)` returns that connection for the application's own statements in the same transaction.
- The transaction helpers take only the pool or the store, never a `Tx`. In PostgreSQL that is `Pool`, made by `decisions_postgres.pool(name)` from the pool's registered name, so it is never a transaction's connection. A helper therefore cannot be called inside another helper's body, and none commits an outer transaction early. `migrate`, `sweep`, `deliver_due`, `deliver_notices`, `set_aside` and `decisions_postgres/queue` take the `Pool` too.
- The mode in which each port call commits by itself is removed: `sql.within`, the pool branch of `atomically`, and the clause that a call on the pool or handle commits alone. Reads outside a verb take the store or the pool: the OTP store's queues, pages, `entries`, `heads`, `wakes` and `notices`, and the PostgreSQL queue reads. They see committed rows. The inspection of `decisions/store` stays on the transaction type, because `decisions/testing.check` reads each record through its desk in the same transaction.
- `decisions/conformance.Adapter` has no `handle`. Every check reads and writes inside a transaction that `Adapter.transaction` opened, and `transaction` returns the text its body returned, so a check can pass a value such as a new id out of the transaction.

## Why

- The port's transaction value also stood for "no transaction": a pool in PostgreSQL, the handle in the OTP store. A desk verb type-checked with either. On the pool or handle, `load` locked only for its own statement, `atomically` ran the gated tool in a transaction of its own, and the entry that records the release was a separate commit. Eight processes that raced `recommend_once` on one key all ran the tool: 160 effects for 20 keys in both stores, where 20 are right. Each losing process saw its own append refused and reported a retryable conflict, so its caller believed nothing had happened twice. Release exactly once (ADR-0007) failed silently, under a call shape the port's documentation named as valid.
- `decisions_postgres.transaction` and its siblings accepted any `pog.Connection`. Handed a transaction's connection, `pog.transaction` sent `begin` and later `commit` inside the open transaction, which ended the outer transaction in the middle of its body. A body that wrote a row, called `transaction` for an inner step and then refused kept the row.
- A check that refused these shapes at run time would leave a second, wrong path in the API. Removing the mode makes both shapes fail to compile.

## Alternatives

- **Refuse a pool or a single connection at run time.** `sql.is_pool` could tell them apart, but each misuse would surface only as an error in production, and the pool mode would stay in the port's contract.
- **A separate read-only type in the core for the conformance suite's handle.** The suite then needs two type parameters, and the reads it makes through the port (`load`, `waiting`, `members`, a desk's `read`) still need a transaction. Running every check in a transaction removes the handle without a second type.
- **Take the `Store` in the PostgreSQL helpers.** The store holds the Grind handle, which reaches Grind's pool, but `migrate` runs at deploy time without a Grind runtime, and an application may run the package on a pool Grind does not own.

## What changes for consumers

- `decisions` 0.2.0: `conformance.Adapter` loses `handle`, and its `transaction` returns the body's `Ok` text.
- `decisions_otp` 0.2.0: `store.handle` and `store.store_of` are removed. Run a verb, a port call and `testing.check` in `store.transaction(s, ..)`. The reads `queue`, `queue_page`, `queue_for`, `queue_page_for`, `review_queue`, `review_queue_of`, `occurrences_of`, `settled_since`, `entries`, `heads`, `wakes` and `notices` take the `Store`. Application rows (`get`, `put`, `add`, `remove`, `rows`, `count`) stay on `Tx`.
- `decisions_postgres` 0.3.0: build `Pool` with `decisions_postgres.pool(config.pool_name)` and pass it where a `pog.Connection` pool was passed. The port, the desk, the inspection, a gated tool, a waker and a follower take `Tx`; run the application's own statements on `connection(tx)`, and Grind's `submit_in` on it as well. A verb is no longer called with the application's own `pog.transaction`; use `transaction_with` for a body that also does the application's own work.
