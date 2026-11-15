# `recommend_when`'s precondition cannot report a store failure

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0034 (the superseding window), term Superseding window (record context).

## Behaviour wanted

`decisions_otp/isolated.recommend_when` turns every `Error` from its precondition into `Skipped(reason)`. A precondition that could not run because the store failed is reported the same way as one that ran and decided to skip, so the caller cannot tell "skip this trigger for good" from "try again later".

## Evidence

`/code/gleam-dream/worktrees/oversight-decisions/apps/clinic_registration/src/clinic_registration/jobs.gleam`, function `attempt`: on `Skipped` the job re-reads the store (`store.is_latest`) to find out whether the skip was real or a store failure, and the precondition `still_latest` folds a store error into its `Error(String)`. Test: `/code/gleam-dream/worktrees/oversight-decisions/apps/clinic_registration/test/clinic_registration/delivery_test.gleam`, `a_newer_message_supersedes_the_waiting_recommendation_test`.

## Done when

- A precondition can state that it could not be evaluated, as distinct from deciding to skip, and the result of `recommend_when` shows which happened.
- A caller can decide on redelivery from the result alone, without reading the store again.
- A test shows both outcomes, and the runtime's handling of each matches the disposition rules.

## Out of scope

Changing how `happened` supersedes; the superseding-window recipe itself (ADR 0034).

## Blocked by

None.
