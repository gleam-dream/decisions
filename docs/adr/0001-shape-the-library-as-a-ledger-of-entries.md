# Shape the library as a ledger of appended entries, not an engine and not a Fabric graph

<a id="adr-0001"></a>

## Decision

- An occurrence is the list of everything that happened to it and every input that informed it. Its status is a fold of that list (`occurrence.fold`, `occurrence.apply`).
- One desk per decision point binds the declaration to its gated tool, its current policy and one storage port. There is no engine process and no registry of points.
- The policy is data over facts the declaration names, so publishing a version is a write.
- Three ideas come from the Gate prototype: the model as a first-class value that production and replay share; reads that return their evidence reference with their content; and reads declared once and shared by the model and the card.

## Rationale and alternatives

- **Gate** (an engine on Fabric, Grind and pog) met nearly every condition in memory and owns a real supervision tree. Its policy is a function inside the declaration, so a threshold change is a deploy; its builder ended with a storage port of fourteen functions anyway; and every guard, executor and outside read runs inside the one process that owns the store. It has no PostgreSQL evidence.
- **Loom** (the occurrence hosted inside Fabric) ran all nine round-one use cases on unmodified Fabric and failed the requirement that a verdict and its release share a transaction: a process killed inside a verdict leaves the verdict committed and the occurrence unable to take another. Its cost per verb is two to three orders of magnitude above the others, and its learning record is split across the run and side tables. The three Fabric changes that would fix it each contradict a stated rule of Fabric's design.
- **Ledger** needed no new lifecycle status for eleven further use cases (four eyes, escalation, a payout at a provider, the autonomy ladder, a bulk verdict, a partner validator, a deployment). Two builders working apart both moved to appended entries ("appended entries make _neither overwrites the other_ structural").

## Evidence and history

- Lab: `/code/gleam-dream/decision-point-lab/`. Round one in `FINDINGS.md` ("The answer", "The shapes on the criteria"); round two in `FINDINGS-2.md` ("The three shapes under stress", "The recommended shape, revised"). Both rounds ended 2026-11-14; the owner chose Ledger, as revised, on 2026-11-15.
- Loom's B2 failure: `loom/test/b_crash_test.gleam`, `b2_killed_after_the_executor_wrote_and_before_it_committed_gap_test` and `b2_the_runner_is_killed_inside_the_executor_test`; `loom/NOTES.md`. Gate's B2: `gate/test/b_crash_test.gleam`, `b2_killed_inside_the_verdict_test`. Ledger's B2 in PostgreSQL: `ledger_postgres/test/b_kill_and_restart_test.gleam`, `b2_killed_inside_the_verdict_after_the_executor_wrote_test`.
- Scale (one machine, `FINDINGS-2.md` "Numbers"): recommend and release with 16 processes, Ledger 52 000/s in memory and 9 400/s in PostgreSQL, Gate 20 500/s, Loom 303/s.
