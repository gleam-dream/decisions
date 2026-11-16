# `isolated.recommend` can never return `Skipped`, yet its caller must match it

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: Runtime context, "Isolated model calls".

## Behaviour wanted

`decisions_otp/isolated.recommend` and `recommend_when` share the result type `Attempted`. Only `recommend_when` can produce `Skipped`, but a caller of `recommend` must still handle it, with a branch that never runs.

## Evidence

`/code/gleam-dream/decisions/integrations/decisions_otp/src/decisions_otp/isolated.gleam`, `Attempted` and `recommend`; `gleam-dream/oversight/apps/moderation_desk/src/moderation_desk/models.gleam` matches `Superseded(_) | Skipped(_)` together.

## Done when

- A caller of `recommend` handles only the outcomes `recommend` can produce, or the documentation states why the shared type is kept.
- The moderation desk's match has no branch that cannot run.

## Out of scope

Changing `recommend_when`'s outcomes.

## Blocked by

None.
