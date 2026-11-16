# A trigger is admitted before the model runs, and superseding takes a subject lock

<a id="adr-0050"></a>

Recorded on 2026-11-16. Settles the open question of [ADR-0034](0034-the-superseding-window-is-closed-by-a-recipe-and-a-precondition.md#adr-0034).

## Decision

- `decisions.expect(desk, tx, key:, trigger:, about:)`, called in the transaction that receives a trigger, records that a recommendation is expected under the key: an `expected` entry and a head with status `pending` (the status formerly named `attempted`).
- `happened` supersedes a record that has not begun (expected, or holding only failed attempts) like a waiting occurrence. The `recommend_once` or `record_failure` that follows for that key is refused with `SupersededBefore(event)` and writes nothing.
- Before it reads which records wait, `happened` loads a lock id for the point and the subject through the port's `load` (`decisions.subject_lock`, under the reserved prefix `decisions.subject-lock:`). No entry is stored under it, and no port function was added. Two `happened` calls about one subject therefore run one after the other, and the second sees what the first committed.
- A key that was not expected first is still open to the superseding window.

## Rationale and alternatives

- The window was closed by an application recipe (a latest-trigger row per subject) and `recommend_when`'s precondition. Each application wrote the recipe again. Admitting the trigger before the model runs puts the expectation on the record itself, where `happened` already looks.
- A per-subject marker kept by the port, tracker issue 15, was not needed: the subject lock is an ordinary `load` of an id that has no entries, which every adapter already locks.

## Evidence and history

- The owner's ruling, 2026-11-15 and 2026-11-16. `src/decisions.gleam`, `expect`, `happened`, `subject_lock`, `SupersededBefore`; the conformance check "a subject lock stores nothing and orders two admissions"; the stress scenario "expect", which shows the same sequence without `expect` leaving a stale occurrence; `examples/usage/src/decisions_usage/expect_then_recommend.gleam` (region `expect-then-recommend`).
- `gleam-dream/oversight/apps/clinic_registration` expects each message in the transaction that receives it and lists pending messages at `/pending`.

## Note, 2026-11-16

- Order inside one transaction: call `happened` before `expect`. Locks are taken in one order, the subject lock and then the records in `waiting`'s order; the other order could deadlock with a later transaction and would supersede the key just expected.
- The subject lock relies on READ COMMITTED: each statement takes a new snapshot, so the read of `waiting` after the lock is granted sees what the lock's previous holder committed. Under REPEATABLE READ or SERIALIZABLE the read would use the transaction's first snapshot, and two admissions could miss each other. `decisions_postgres`'s `load` therefore refuses a transaction at another level with `store.Conflict` ("decisions requires READ COMMITTED; ..."). This ADR owns that rule; the storage context and the PostgreSQL README cite it.
- Evidence: `test/subject_lock_test.gleam`; the conformance check "a subject lock stores nothing and orders two admissions"; the shared stress scenario "concurrent admissions about one subject leave one key pending", run against both stores.
