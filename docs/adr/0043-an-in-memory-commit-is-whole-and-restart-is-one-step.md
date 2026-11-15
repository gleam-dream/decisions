# An in-memory commit is seen whole, and a restart is one step

<a id="adr-0043"></a>

## Decision

- Every read of committed rows in `decisions_otp/store` (queues, `waiting`, pages, the inspection, the backlog) sees each commit entirely or not at all.
- `restart` takes the snapshot and stops the old owner in one step of the owner. Every commit acknowledged before it is kept; a commit that reaches the old owner afterwards fails as "outcome unknown".
- `named` and `subscribe` return an `OwnerError` (`StoreStopped`, `NoAnswerWithin`, `NoSubscriber`), so a slow owner is not reported as stopped.

## Rationale and alternatives

- A commit inserted new rows and then deleted old ones one at a time, and lock-free readers saw the gap: one card appeared twice in a queue read. `restart` copied the rows and then sent an asynchronous stop, so 66 to 159 acknowledged commits were lost in four of six probe runs.
- Making readers take locks was rejected: queue reads would wait on every writer.

## Evidence and history

- Independent review of both adapters, 2026-11-15, findings O1, O2, O7 and O9 (probes PROBE1 and PROBE2). `integrations/decisions_otp/src/decisions_otp/store.gleam`; the stress scenarios "uncommitted writes are invisible" (now also: a commit appears whole) and "wake-ups and notices survive a store restart" (now with commits in flight).
- Cost: the in-memory 5 000-holds workload went from about 336 ms to about 690 ms, because readers can no longer see a commit in part (`docs/BENCHMARKS.md`).
