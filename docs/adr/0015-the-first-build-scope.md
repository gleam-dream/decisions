# The first build holds the round-one verbs and round two's additions, except the blind path, shadow, links and generic clients

<a id="adr-0015"></a>

## Decision

- In: every round-one verb; `recommend_once`, `ticket` and `resume`; `report` and `Effect`; `Either` and `Several`; time as a fact (`waited_minutes`, timelines, escalation); guards that return evidence; consulted points; superseding, withdrawing and waking; the card as a document with the same context the model had; typed facts and `publishable`; learning and replay.
- Out, for a second build: the blind path (`AskBlind`, `open_blind`, `decide_blind`, `review_blind`), `shadow`, links on a proposal, and generic clients (`Served`).
- The types are shaped so the second build is additive: `Outcome`, `Eligible`, `Condition`, `Event`, `Status` and `Refusal` are documented as gaining variants in a minor release, and the card document already carries the output's JSON Schema.
- All ten defects of round two and the smaller items under them, except `Served`, are designed out, each with a test that would fail without it.

## Rationale and alternatives

- Nineteen verbs is a large surface for a first user. Registration in dash-crm needs `recommend`, `decide` and release in the verdict's transaction, with no hold, no sampling and no nesting; the other in-scope verbs are what the second decision point (replies) and the stress conditions need.
- Building the blind path now was considered: the design asks for unanchored review before automation is granted. It waits because no first user needs it and its types fit beside the open path.

## Evidence and history

- `/code/gleam-dream/decision-point-lab/FINDINGS-2.md`, "The recommended shape, revised", "What is still uncertain" (the surface) and "The next step". Owner decisions 6 and 7, 2026-11-15.
- The defect tests: `test/defects_test.gleam`, one per defect. The unbuilt items are build entries in the record context's pending ledger.
