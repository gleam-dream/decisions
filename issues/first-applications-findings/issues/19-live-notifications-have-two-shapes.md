# Live notifications have two shapes across the two packages

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: Runtime context, "Live hints" and "The two adapters compared".

## Behaviour wanted

`decisions_otp/live` offers topics for an occurrence, a point, a queue and a point's review queue, with `Missed(count)` for a subscriber that fell behind. `decisions_postgres/live` offers everything, a point or an occurrence, with no `Missed`, and an acknowledged `subscribe` that returns the listener's process. A page or a desk written against one cannot move to the other without rewriting its subscription code.

## Evidence

`/code/gleam-dream/decisions/integrations/decisions_otp/src/decisions_otp/live.gleam` and `/code/gleam-dream/decisions/integrations/decisions_postgres/src/decisions_postgres/live.gleam`; both READMEs, "The two adapters compared".

## Done when

- An application can subscribe to the same kinds of change, and learn the same way that it missed some, on either store, or the difference is a decision recorded in an ADR.
- The comparison table in both READMEs and the runtime design agrees with the code.

## Out of scope

The delivery guarantee: a hint remains a reason to read again, never a durable event.

## Blocked by

None.
