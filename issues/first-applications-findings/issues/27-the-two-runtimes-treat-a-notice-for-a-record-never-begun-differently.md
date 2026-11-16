# The in-memory runtime drops a notice for a record superseded before it began; PostgreSQL hands it to the follower

Status: needs-triage
Category: bug

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: Runtime context, "The two adapters compared"; ADR 0050.

## Behaviour wanted

A record superseded before it began admits a settlement notice. `decisions_postgres.settlement_worker` hands it to the point's follower like any other, and a follower that reads it gets `SupersededBefore`. `decisions_otp/runtime` reads the occurrence before it calls the follower, the read is refused with `SupersededBefore`, whose handling is `Drop`, and the follower is never called. The same follower sees the notice on one store and not on the other.

## Evidence

`/code/gleam-dream/decisions/integrations/decisions_postgres/src/decisions_postgres.gleam`, `settlement_worker` (its doc states the PostgreSQL behaviour); `/code/gleam-dream/decisions/integrations/decisions_otp/src/decisions_otp/runtime.gleam`, `point`, which reads with `decisions.read` before the follower runs.

## Done when

- A follower sees the same notices on both stores, or both READMEs state the difference in the same words.
- A test in each package shows what a follower receives for a record superseded before it began.

## Out of scope

Whether such a record should admit a notice at all.

## Blocked by

None.
