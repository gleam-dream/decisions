# A failed attempt recorded by `recommend_when` carries no evidence

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0010 (failed attempts on the record), term Failed attempt.

## Behaviour wanted

When the model fails inside `isolated.recommend` or `recommend_when`, the attempt is recorded with `record_failure`, never with `record_failure_with`. An application that stored the provider exchange of the failed attempt has no way to point the attempt at it unless the model keeps the exchange on the side and the application records the failure itself.

## Evidence

`/code/gleam-dream/worktrees/oversight-decisions/apps/clinic_registration` keeps each provider exchange as evidence (`src/clinic_registration/llm.gleam`, `capture`) and its tests `/code/gleam-dream/worktrees/oversight-decisions/apps/clinic_registration/test/clinic_registration/model_failure_test.gleam`, `an_undecodable_answer_is_an_attempt_with_its_exchange_kept_test`, show the exchange kept beside an attempt that does not reference it.

## Done when

- An attempt recorded through the isolated recommend step can reference the evidence the failed call produced.
- The record of a failed attempt shows that evidence (`occurrence.Attempt.evidence`).
- A test with an undecodable answer shows the exchange referenced from the attempt.

## Out of scope

Changing `record_failure_with` in the core.

## Blocked by

None.
