# The policy cannot say "two approvals, one of them by a senior", nor read who recommended

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0029; record context pending rulings.

## Behaviour wanted

An eligibility cannot require approvals from two sets at once (two moderators, one of whom is a senior), and a policy condition cannot read which recommender, or which version, recommended.

## Evidence

`/code/gleam-dream/worktrees/oversight-decisions/apps/moderation_desk/src/moderation_desk/point.gleam`: seniors hold `moderators` too, so a senior counts as a moderator, and the classifier's identity reaches the policy only as a signal the model reports.

## Done when

- A policy can require two approvals of which at least one is by a holder of a second set.
- A policy can condition on the recommender, or the documentation records that this stays a reported signal.
- Both are decided against the pending rulings "One from finance and one from legal" and "A policy condition cannot read who recommended" in the record context.

## Out of scope

Changing `Either` and `Several` semantics (ADR 0029).

## Blocked by

None.
