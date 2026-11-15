# A pending wake-up or notice always has a job, or a sweep finds it

<a id="adr-0045"></a>

## Decision

- `decisions_postgres.sweep(store, db)` admits a job for every pending wake-up and every undelivered notice of a followed point that has none. The application runs it at start, after Grind, and whenever an operator wants to; it is safe beside the workers.
- A waker or follower that raises is caught and counted as an application failure. Reaching `with_snooze_limit` sets the wake-up or notice aside and reports it; no job is dropped silently.
- `deliver_notices` delivers due notices through the settlement worker's code path, as `deliver_due` does for wake-ups.

## Rationale and alternatives

- Only `schedule` and `settled` submitted jobs. A settlement job ended after Grind's default 100 snoozes of redelivery; a raising follower was replayed after lease expiry and then held uncertain, never counted; a point added to `following` after it settled never got a job. Each left a pending row nothing would deliver.
- Submitting a job on every read of a pending row was rejected: the sweep's cost grows with pending rows only, and it runs when asked.

## Evidence and history

- Independent review of both adapters, 2026-11-15, finding G1. `integrations/decisions_postgres/src/decisions_postgres.gleam`, `sweep`, `deliver_notices`, `with_snooze_limit`, `with_wake_attempts`; the package's tests of the snooze limit and a raising follower.
