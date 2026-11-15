# An occurrence is a record, not a process

<a id="adr-0002"></a>

## Decision

- Nothing about an occurrence lives in a process. Every verb loads, checks and appends inside the caller's transaction, and the store's row lock orders concurrent writers.
- Processes exist only around the record (sweeper, dispatcher, workers, isolated model calls, subscribers). None keeps state, so each can be killed at any instant and its replacement carries on from rows.

## Rationale and alternatives

- A process per occurrence was built twice and measured. It gave no gain, added a second copy of the truth that must forget what the store undid, a lifetime to manage for an occurrence that can wait for days, and no concurrency the row lock did not already give.
- Three rules made every kill test pass, and none is about processes: admission is idempotent by key, a wake-up leaves the queue in the transaction that acts on it, and a wake-up that finds nothing due does nothing.

## Evidence and history

- `/code/gleam-dream/decision-point-lab/ledger_otp/NOTES.md`, section "I-3. A process per occurrence": 5 000 verdicts took 325 ms on the ordinary path (load, decode and fold on every verb) and 376 ms with one process per occurrence, after 40 ms to start the processes. Loom's version: `loom/test/i_beam_test.gleam`, `i3_a_process_per_occurrence_against_the_ordinary_path_test`, 11.8 s against 5.1 s.
- Kill evidence: `ledger_otp/test/b_crash_test.gleam` (`chaos_while_five_hundred_occurrences_move_test` and the other B tests). `FINDINGS-2.md`, section "The BEAM". Decided 2026-11-15.
