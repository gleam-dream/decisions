# `Unsure` at a hold's wake-up was not watched to fail with the fix removed

Status: done
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0037.

## Behaviour wanted

A guard, release check or executor that answers `Unsure` when a hold ends must leave the occurrence held and fail the wake-up with `ToolUnsure`, so it is delivered again. The test exists, but nobody put the defect back and watched it fail, so it is not known to guard against the regression.

## Evidence

`/code/gleam-dream/decisions/test/final_review_test.gleam`, `r10_an_unsure_guard_at_a_wake_up_is_tried_again_test`; the final core review's finding R10.

## Done when

- With the fix removed (an `Unsure` at the wake-up ends the occurrence `Refused`), the test fails; with it restored, it passes.
- The same holds through `decisions_postgres.wake_worker`, where the job is counted toward `with_wake_attempts`.

## Out of scope

Changing the `Stop` type (ADR 0037).

## Blocked by

None.

## Comments

AI-assisted contribution. Partly answered on 2026-11-16: `/code/gleam-dream/decisions/integrations/decisions_postgres/test/decisions_postgres/delivery_test.gleam`, `a_wake_up_that_meets_an_unsure_tool_is_retried_and_releases_once_test`, covers `Unsure` at a hold's wake-up through `wake_worker`, counted. No record shows the first criterion: the core's test watched failing with the fix removed. The issue stays open until that is done.

AI-assisted contribution. Closed as `done` on 2026-11-16. Both criteria are now shown. With the fix removed in a scratch copy of the core, `final_review_test.r10_an_unsure_guard_at_a_wake_up_is_tried_again_test` and the two new tests `r10_an_unsure_tool_at_a_wake_up_is_tried_again_test` and `r10_an_unsure_release_check_at_a_wake_up_is_tried_again_test` fail (122 passed, 3 failures); with it restored they pass. The PostgreSQL wake worker is covered by `a_wake_up_that_meets_an_unsure_tool_is_retried_and_releases_once_test`.
