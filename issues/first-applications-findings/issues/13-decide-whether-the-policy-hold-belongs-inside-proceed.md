# Decide whether the policy hold belongs inside `Proceed`

Status: done
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0030 (recorded as open there).

## Behaviour wanted

`with_policy_hold` is declared on the point, so every autonomous acceptance of the point waits. The core's builder recommends moving the hold into the policy outcome, so a version can hold some autonomous acceptances and not others and the hold is published as data. This is an owner decision.

## Evidence

`/code/gleam-dream/worktrees/oversight-decisions/apps/payout_desk` holds policy acceptances for an undo window (`test/payout_desk/robustness_test.gleam`, `withdraw_during_the_hold_and_after_it_test`).

## Done when

- The owner's ruling is recorded in a new ADR, and the record context's pending ruling "The policy hold belongs inside Proceed" is cleared or kept with the ruling cited.

## Out of scope

Implementing the change before the ruling.

## Blocked by

None.

## Comments

AI-assisted contribution. Closed as `done` on 2026-11-16. The owner decided: the undo window lives in the policy outcome, `Proceed(sample:, hold:)`, and `with_policy_hold` is removed. Recorded in ADR 0048, which settles ADR 0030's open point.
