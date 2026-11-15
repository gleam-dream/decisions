# Contention is its own store error

<a id="adr-0022"></a>

## Decision

- `store.StoreError` is `Conflict | Contended | Unavailable`.
- `Contended` is a deadlock, a serialization failure or a lock wait that timed out. The store wrote nothing, and running the transaction again from the start is safe.
- `Unavailable` now means only that the outcome is unknown: a lost connection, a query timeout, or a failure in the reply to the commit. The caller reads the record before running again; every verb is safe to repeat on what it finds.
- The PostgreSQL adapter maps SQLSTATE class 23 to `Conflict`, deadlocks, serialization failures and lock timeouts to `Contended`, and every other failure to `Unavailable`. The OTP store reports its deadlock refusal and its lock-wait timeout as `Contended`.

## Rationale and alternatives

- A deadlock and a lost commit reply were both `Unavailable`. A caller could not tell "nothing happened, run it again" from "it may have committed, look first", so it had to treat every contention as possibly committed.
- Folding contention into `Conflict` was rejected: a repeated conflict points at a second writer that does not take the lock, which is a defect, while contention is ordinary under load.

## Evidence and history

- Decided 2026-11-15 (`core-review/PUBLIC-CHANGES.md`, "A later round, driven by the adapters").
- `src/decisions/store.gleam`, `StoreError`; `integrations/decisions_postgres/src/decisions_postgres.gleam` (module comment and `Failure`); `integrations/decisions_otp/src/decisions_otp/store.gleam`, `lock`; `integrations/decisions_otp/test/store_test.gleam`, `a_wait_that_would_deadlock_is_refused_at_once_test` and `a_lock_wait_longer_than_the_timeout_is_refused_test`.
