# A failed attempt and its occurrence end up under different keys

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0010, ADR 0027 (one attempt per call).

## Behaviour wanted

`record_failure` must be given the key `recommend_once` will use for the same trigger. When the key is known only once an agent calls its gated tool (the run and the action), an attempt that fails before the call is recorded under another key, and the attempts and the occurrence are two records.

## Evidence

`gleam-dream/oversight/apps/payout_desk/src/payout_desk/jobs.gleam`: a stopped run is recorded under `"payout:" <> run id` while the occurrence is admitted under `call_key` (run and action).

## Done when

- An application can keep the failed attempts of one request and the occurrence that follows in one record, or find one from the other, when the occurrence's key is known only later.
- A test shows a failed attempt followed by a recommendation for the same request, read together.

## Out of scope

Changing the key namespace rule (keys are global across points).

## Blocked by

None.
