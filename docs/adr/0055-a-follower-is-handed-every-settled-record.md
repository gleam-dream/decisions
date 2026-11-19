# A follower is handed every settled record, begun or not

<a id="adr-0055"></a>

Recorded on 2026-11-18. Settles tracker issue 27 of `issues/first-applications-findings`. Amends the follower sentence of [ADR-0054](0054-an-occurrence-may-carry-its-own-deadline.md#adr-0054)'s "What changes for consumers" for the OTP runtime.

## Decision

- Every settlement notice reaches the point's follower in both runtimes, including the notice of a record that ended before it began: superseded ([ADR-0050](0050-a-trigger-is-admitted-before-the-model-runs.md#adr-0050)) or lapsed at its own deadline ([ADR-0054](0054-an-occurrence-may-carry-its-own-deadline.md#adr-0054)). "The same notices" is the rule; the two runtimes still hand them over differently.
- In `decisions_otp`, `runtime.point(desk, settled:)` hands the follower the record as `decisions.read_record` returns it when the notice is delivered: `decisions.Begun(occurrence)` or `decisions.NotBegun(pending)`. The follower's type becomes `fn(tx, decisions.Record(o)) -> Result(Nil, HandlerFailure)`; `runtime.nothing_follows` takes the same type. The runtime no longer drops such a notice before the follower runs.
- A notice exists only once its record has ended, so the outcome of a `NotBegun` handed to a follower is final: its cause is in `pending.ended`. A superseded record never begins; a lapsed one may still receive a late recommendation, recorded expired, which admits no second notice, so the follower is not called again. Do not wait for it; the follower's own work may still fail and is handled like any other failure.
- The record is read when the notice is delivered, not when it was admitted. A record that lapsed at its own deadline and then received a late recommendation is handed over as `Begun` with the occurrence `Expired(DeadlinePassed)`, so a follower that reacts to a deadline matches the cause in both branches.
- In `decisions_postgres`, nothing changes: the follower is handed the occurrence id and reads the record itself. Reading it with `decisions.read_record` gives the same `Begun` or `NotBegun` the OTP runtime hands over; `decisions.read` refuses a record not begun.
- The shared stress suite holds the rule for the OTP runtime over both stores, and a PostgreSQL test holds it for the Grind settlement worker.

## What changes for consumers

- `decisions_otp`: every follower written for `runtime.point` matches `Begun` and `NotBegun`; the compiler finds each one. A caller that passes `runtime.nothing_follows` changes nothing. A follower that ignores its argument (`fn(_, _)`) or destructures it with `let assert Begun(..)` still compiles and is now also called for records not begun: it must handle them without raising, or the notice is retried and set aside.
- `decisions_otp`: a notice for a record not begun is delivered to the follower and reported as delivered, no longer as `[decisions, job, dropped]`.
- `decisions_postgres`: none.

## Rationale and alternatives

- The two runtimes disagreed: PostgreSQL called the follower, which read `SupersededBefore` or `DeadlinePassedBefore`; the OTP runtime read the occurrence first, met the same refusal, and dropped the notice without calling the follower. An application behaved differently in tests over the in-memory store and in production over PostgreSQL.
- Documenting the difference was rejected: a follower that must clear an operator's queue when a trigger's work is moot, or tell a customer that a reply window closed, needs the notice on both stores.
- Keeping the follower's `Occurrence` type and adding a second handler for records not begun was rejected: a point wired without it would keep dropping those notices, which is the defect.
- Handing the OTP follower the occurrence id, as PostgreSQL does, was rejected: `runtime.point` already binds the point's typed desk, so it reads the record once, with its output type, instead of leaving every follower to read it again and to know which read refuses what.
- The cost is a change to `decisions_otp`'s follower type before its first release.

## Evidence and history

- Tracker issue 27; the owner's ruling of 2026-11-18 to fix it before `decisions_otp` is first published.
