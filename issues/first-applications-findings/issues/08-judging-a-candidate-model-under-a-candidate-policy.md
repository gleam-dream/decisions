# Judging a candidate model under a candidate policy means rebuilding the example

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0024, term Replay and term Example (record context).

## Behaviour wanted

`learning.answer_under(example, policy:, point:)` evaluates the recorded recommendation. To ask what a candidate policy would say about a candidate model's answer, an application runs the model on the example's sources and rebuilds the example with the new recommendation by hand.

## Evidence

`/code/gleam-dream/worktrees/oversight-decisions/apps/moderation_desk/src/moderation_desk/gate.gleam`, function `would_proceed`. Tests: `/code/gleam-dream/worktrees/oversight-decisions/apps/moderation_desk/test/gate_test.gleam`, `a_candidate_that_lets_abuse_through_is_held_test`.

## Done when

- An application can evaluate a candidate policy against a candidate model's answer for a recorded example without editing the example.
- The moderation gate no longer rebuilds examples.

## Out of scope

Changing how `replay` tallies agreement (ADR 0024).

## Blocked by

None.
