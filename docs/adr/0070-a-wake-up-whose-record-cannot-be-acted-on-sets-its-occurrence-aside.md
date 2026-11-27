# A wake-up whose record cannot be acted on sets its occurrence aside

<a id="adr-0070"></a>

Recorded on 2026-11-27.

## Decision

- `decisions_otp/backlog.Backlog` gains `set_aside_occurrence(tx, occurrence, reason)`: take the occurrence out of every queue and of the port's `waiting`, and set aside each of its pending wake-ups.
- When a wake-up's delivery fails with the handling `SetAside` (a record that no longer decodes, among others), the OTP runtime sets the wake-up aside and calls `set_aside_occurrence` in the same transaction. A notice or a trigger is set aside alone, as in PostgreSQL.
- The in-memory store keeps the occurrence's head and entries, so the record can still be read.

## Why

- PostgreSQL's wake-up worker already set the occurrence aside (`set_aside_occurrence`): the head is marked, its queue rows go, its wake-ups are set aside, and `waiting` leaves it out. The OTP store set aside only the job, so a poisoned record stayed in every validator's queue and in `waiting`, and each later wake-up for it was set aside again. The two stores refused the same record differently.

## Alternatives

- **Record the difference in the runtime design.** It keeps two rules for one situation, and a supersession in the OTP store keeps meeting a record it cannot read.
- **Let `set_aside` of a wake-up imply the occurrence.** It hides a second effect inside a call whose contract is "one job"; a wake-up set aside for a point that is not wired must not touch its occurrence.

## What changes for consumers

- An implementation of `Backlog` adds `set_aside_occurrence`.
- In the OTP store, a record that no longer decodes leaves the queues and `waiting` when its wake-up meets it.
