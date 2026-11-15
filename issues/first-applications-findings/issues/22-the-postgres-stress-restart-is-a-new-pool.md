# The PostgreSQL stress target's restart is a new pool, not a server restart

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0026; runtime context, "The stress suite".

## Behaviour wanted

Where a shared stress scenario restarts the store, the PostgreSQL target stops the runtime and its pool and opens a new pool over the same schema. PostgreSQL itself never restarts, so the scenarios do not show that wake-ups and notices survive a database restart.

## Evidence

`/code/gleam-dream/decisions/integrations/decisions_postgres/test/stress_target.gleam`, `restart`; `/code/gleam-dream/decisions/integrations/decisions_postgres/README.md`, "Tests".

## Done when

- A scenario restarts the PostgreSQL server (or the cluster the test script made) with work pending and shows every pending wake-up and notice delivered once afterwards, or the limit stays documented as it is now.
- The test script supports the restart without reaching any other server.

## Out of scope

Power-loss durability: the test cluster runs with fsync off.

## Blocked by

None.
