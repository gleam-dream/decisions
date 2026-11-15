# Release at most once rests on the store, never on the value

<a id="adr-0007"></a>

## Decision

- `Released(output)` is opaque. Only the desk constructs it, after the guard allowed the release, inside the transaction that appends the `released` entry. A gated tool's executor accepts nothing else and cannot hand it on.
- "Once" is held by the store: the occurrence's lock orders writers, and `append` refuses a second `released` entry (in PostgreSQL the unique index `decisions_entries_one_release`).
- The executor runs inside the verdict's or the wake-up's transaction, in a savepoint, so the database effect and the release commit together or not at all.
- An effect outside the database is bounded by the release key (`release:` and the occurrence id): the outside system deduplicates by it, `report` records performed, not performed or uncertain, and an uncertain effect is settled only by looking it up by the key.

## Rationale and alternatives

- Gleam has no linear types, so a value cannot be made usable once. A store constraint is the only place "once" can hold under concurrent processes.
- Running the executor after the verdict committed was rejected: Loom does that and a kill between them leaves a committed verdict with no release and no way to give another.
- Retrying an uncertain outside effect was rejected: it is how a payout happens twice.

## Evidence and history

- `/code/gleam-dream/decision-point-lab/FINDINGS.md`, "How gated tools are enforced": eight racing wake-ups ran the executor once, and a direct insert of a second `released` entry failed on the index. `FINDINGS-2.md`, "The database, and outside it".
- Fixtures `fixtures/negative/build_a_released_value.gleam` and `execute_with_a_bare_output.gleam`. Payouts: `test/uc14_payout_test.gleam` (`a_worker_lost_after_the_provider_accepted_pays_once_test`, `an_unknown_outcome_is_recorded_and_settled_by_looking_test`) and `integrations/decisions_postgres/test/decisions_postgres/payout_test.gleam`. Races: `races_test.gleam`, `forty_verdicts_eight_wakes_and_a_supersession_test`. Decided 2026-11-15.
