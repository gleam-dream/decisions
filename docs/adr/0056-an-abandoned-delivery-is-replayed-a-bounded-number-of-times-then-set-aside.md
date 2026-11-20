# An abandoned delivery is replayed a bounded number of times, then set aside

<a id="adr-0056"></a>

Amends [ADR-0045](0045-a-pending-row-always-has-a-job.md#adr-0045): `sweep` no longer takes every job that is not finished for live work.

## Decision

- `decisions_postgres` depends on Grind 0.2 (`>= 0.2.0 and < 0.3.0`). Its two workers, `decisions.wake` and `decisions.settlement`, keep `ReplayAfterLeaseExpiry(10)` and each declares a Grind settlement (`worker.with_settlement`) for the job Grind holds uncertain once those replays are used up. Grind calls this deciding what becomes of an abandoned job a settlement; it is not a decision's settlement or its notice, and the package names nothing after it.
- The settlement reads the job's row in Grind's transaction, does database work only, and decides by a closed rule:
  - the row is no longer pending: `ConfirmSuccess("nothing pending")`, what a delivery that finds it gone returns;
  - the row is pending and a cancellation of the job is requested: `ConfirmFailure`, since Grind declines a replay then; the row stays pending for `sweep`;
  - the row is pending and fewer than `authorized_replay_limit` (3) replays were authorised for the job: `AuthorizeReplay`;
  - otherwise: the row is set aside with the reason, in the same transaction, and `ConfirmFailure` carries the same reason.
  - A storage failure is an `Error`, which Grind tries again later.
- `sweep` reads each pending row's recorded job into a closed classification: no job (never admitted, pruned, or not this row's), live (waiting or running), awaiting its settlement (held uncertain with its settlement mark due), left uncertain (held uncertain with no settlement to come), or ended. It admits a new job for no job, ended and left uncertain, leaves live and awaiting settlement alone, and reports the left-uncertain jobs it replaced in `Swept.left_uncertain`. A failure to read a job, Grind's included, is an `Error` of the sweep, never a row taken for one without a job.

## What changes for consumers

- Take Grind 0.2 and apply Grind's schema version 14 before running it, by whatever owns Grind's schema in the application (`grind.migrate`, `grind.with_startup_migration`, or Grind's migration file in its tool). This package's own tables do not change.
- `Swept` has a third field, `left_uncertain`; code that builds a `Swept` or matches it positionally changes.
- A delivery abandoned past the bound ends set aside, as a delivery that keeps failing does; this one setting aside emits no `telemetry.set_aside` event.

## Rationale and alternatives

- The hole: once a job's replays were used up, Grind held it uncertain, and `sweep` asked only whether the job was finished. An uncertain job is not, so `sweep` took it for live work that would finish by itself, and the wake-up or notice row stayed pending with nothing to deliver it. A PostgreSQL test reproduced it on Grind 0.1.1.
- Delivery is idempotent: the row is checked and removed, or marked delivered, in the delivering transaction, so a replay of a delivery that committed finds nothing to do. That makes `AuthorizeReplay` the right first answer, and it makes the row, not the job, the authority on whether work remains, which every branch of the rule uses.
- **Replaying without a bound.** Ten expired leases and then more mean the delivery itself kills or hangs its node; replaying it for ever takes nodes down for ever. Three more single deliveries cover a crash loop that outlasts the first replays, such as a bad deploy, and then stop.
- **Making the bound a store setting.** No consumer has asked for another number; a constant can become a setting later without breaking anyone.
- **`LeaveUncertain` past the bound.** It hands the job to Grind's uncertain list, whose decisions do not map onto the record: confirming the job would end it while its row stays pending, and the next sweep would deliver it again; only setting the row aside stops it. Setting the row aside is already this package's answer to work that keeps failing (`with_wake_attempts`, `with_settlement_attempts`, `with_snooze_limit`): it blocks nothing and keeps the reason on the row.
- **`ConfirmFailure` past the bound without setting the row aside.** The job would end and the row stay pending, so the next sweep would replay the poison.
- **Emitting `telemetry.set_aside` from the settlement.** The settlement may run more than once and a try may roll back after it returned, so the event could report a setting aside that never committed. Grind reports the settlement itself, and the reason is kept on the row and on the job.
- **`LeaveUncertain` under a requested cancellation.** It would wait for a person, while the row, which says the work remains, would only be served again by a sweep. A Grind cancellation never stopped this package's work, which stops through the record; ending the job failed says what happened: the abandoned attempt delivered nothing.
- **`sweep` admitting a job for every uncertain job.** A job whose settlement is still due will be decided within a settler's poll; replacing it would deliver twice for nothing and, for a poison delivery, restart its replays around the bound.
- **`sweep` leaving a job left for a person and only reporting it.** The row would stay pending until someone acts in Grind, which is the hole again with a report attached; [ADR-0045](0045-a-pending-row-always-has-a-job.md#adr-0045) promises every pending row a job that will act.
- **`sweep` resolving the uncertain job itself.** The lease that expired does not prove its handler stopped, so `sweep` cannot know the job delivered nothing; replacing the job and leaving the old one to a person decides nothing it cannot know, and any later decision on it is safe because its row is the authority.
- **A wider Grind range, such as `< 1.0.0`.** Below 1.0 a Grind minor version may change the API and the schema, as 0.2 did with `admin.JobSummary` and schema version 14; this package also keeps its `pog` and `pgo` ranges equal to Grind's, which a new Grind minor may move.

## Evidence

- `integrations/decisions_postgres/test/decisions_postgres/abandoned_test.gleam` abandons jobs through Grind's own `quarantine_expired`, settles them through `admin.settle_due`, and holds each branch of the rule for the wake-up worker, the bound for both workers, and the sweep's three uncertain cases.
