# Policy steps apply in order, and standing approvals are evaluated again

<a id="adr-0042"></a>

## Decision

- `wake` applies the passed steps of the timeline in order and stops at the first that proceeds, consults a point not yet consulted, or asks for what the approvals given so far already meet; otherwise it applies the last passed step.
- A step that asks for an eligibility the standing approvals already meet accepts.

## Rationale and alternatives

- With a step at 30 minutes that proceeds and a later step that asks, a wake-up delivered at 61 minutes skipped the proceeding step and the occurrence stayed waiting, while one delivered at 31 released it: the moment a job was delivered decided the outcome, against ADR 0008.
- With `Several(2, finance)` and a step at 60 minutes to `AnyoneHolding(finance)`, one approval at 10 minutes met the new eligibility, but the occurrence stayed waiting and the approver was barred.

## Evidence and history

- Final review of the core, 2026-11-15, findings R2 and R6. `src/decisions.gleam`, `wake`; `src/decisions/policy.gleam`, `timeline`.
