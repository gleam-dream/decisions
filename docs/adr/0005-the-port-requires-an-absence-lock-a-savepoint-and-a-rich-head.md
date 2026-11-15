# The storage port requires an absence lock, a savepoint and a head with due time, arrival and approvals

<a id="adr-0005"></a>

## Decision

- `load` locks the occurrence id for the rest of the transaction even when no entry exists, so two deliveries of one trigger cannot both admit it.
- `atomically` runs the guard and the gated tool in a savepoint, so a tool that writes and then refuses leaves nothing behind while the transaction stays usable.
- The head carries `due`, `arrived` and `approved` beside the point, subject, status and awaited sets, so a queue ordered by due time never parses an entry and never hands a card back to someone who already approved it.
- These are clauses of the port every adapter must meet, not options of one adapter.

## Rationale and alternatives

- Each is a safety property that rests on the store and that the core cannot provide alone. The PostgreSQL build found all three as defects 5, 6 and 7.
- A separate `claim(id)` function was considered for the absence lock; making `load` take the lock keeps the port at eight functions and leaves no way to load without locking.
- Leaving the savepoint to adapters that need it was rejected: an in-memory store hides the defect, so only a contract clause and its conformance check make every adapter honest. It cost 23 % of throughput in the spike.

## Evidence and history

- `/code/gleam-dream/decision-point-lab/FINDINGS-2.md`, "What must change in the design", items 5 to 7; `ledger_postgres/NOTES.md`.
- Absence lock: `ledger_postgres/test/b_kill_and_restart_test.gleam`, `b1_without_the_absence_lock_a_loser_sees_a_constraint_and_a_retry_succeeds_test` (175 of 175 losers got an error) and `b1_one_key_from_eight_processes_is_one_occurrence_test`. Savepoint: `ledger_postgres/test/q_open_questions_test.gleam`, `q1_an_executor_that_writes_and_then_refuses_after_a_hold_test`. Head: `q3_a_queue_across_points_ordered_by_due_time_test` and `g_projection_test.gleam`, `g10_four_eyes_keeps_the_card_in_the_queue_after_one_approval_test`.
- In this repository: `test/defects_test.gleam` (`defect_5_…`, `defect_6_…`, `defect_7_…`) and the conformance checks named after each clause. Owner decision 3, 2026-11-15.
