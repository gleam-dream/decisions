# Time and the record decide, never the delivery of a job

<a id="adr-0008"></a>

## Decision

- Every verb reads the store clock after `load` has taken the lock, and never uses a time earlier than its last entry.
- A deadline is fixed on the recommendation entry. Every verb that shows or writes on an undecided occurrence (`open`, `resume`, `note`, `expand`, `decide`, `inform`) refuses once the deadline has passed by that clock, whether or not the wake-up that expires it was delivered. `happened` on a lapsed occurrence records the deadline as the cause.
- `withdraw` is refused once the hold has ended by the clock, whether or not the wake-up that releases it was delivered.
- `wake` acts only on what is due and otherwise answers `NotDue(until)` with a future time, or `NothingDue`; `waker` turns that into "deliver again at `until`" or "done".
- The port's `now` is the wall clock at the moment of the call: in PostgreSQL `clock_timestamp()`, never the transaction's start.

## Rationale and alternatives

- The PostgreSQL build found three defects with one cause, trusting delivery instead of the record: a verdict was accepted after the deadline because the expiry wake-up had not arrived (defect 1); the clock read before the lock let entries be stored out of order, so a read "as known at T" could skip one (defect 2); and an early wake-up, with the job queue's clock ahead of the store's, succeeded and left the occurrence held forever (defect 3). The independent review found the same pattern in `withdraw` (C3), in `open`, `note` and `expand` (C4), and in a consulting step that answered `NotDue` with a past time (C2).
- Relying on exactly-once, on-time delivery was rejected: Grind cannot cancel a job and delivers at least once, and clocks disagree.

## Evidence and history

- `/code/gleam-dream/decision-point-lab/FINDINGS-2.md`, items 1 to 3; `ledger_postgres/test/core_observations_test.gleam`, `core_a_verdict_after_the_deadline_is_accepted_until_the_wake_up_arrives_test`, `core_a_wake_up_that_waited_for_the_lock_is_stamped_before_the_entry_it_follows_test`, `core_a_wake_up_delivered_early_is_snoozed_not_lost_test`.
- In this repository: `test/defects_test.gleam` (`defect_1_…`, `defect_2_…`, `defect_3_…`), `test/corrections_test.gleam` (`c2_…`, `c3_…`, `c4_…`, `c8_the_clock_is_read_after_the_lock_test`), and `integrations/decisions_postgres/test/decisions_postgres/behaviour_test.gleam` (`a_verdict_after_the_deadline_is_refused_before_any_wake_up_test`, `a_store_clock_behind_the_job_queue_is_waited_for_test`, `the_store_clock_is_the_database_clock_test`). Core review dated 2026-11-15.
