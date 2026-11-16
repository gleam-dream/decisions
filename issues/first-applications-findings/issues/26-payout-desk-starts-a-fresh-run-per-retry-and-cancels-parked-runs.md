# The payout desk starts a fresh Fabric run per retry and cancels a parked run itself

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0017, ADR 0050.

## Behaviour wanted

The payout desk drives a new Fabric run for each failed attempt of a request, and when a newer event supersedes the payout while the agent works, it cancels the parked run itself on `SupersededBefore`. Both are application code around Fabric that a tool outcome ending a run would make unnecessary.

## Evidence

`/code/gleam-dream/worktrees/oversight-decisions/apps/payout_desk/src/payout_desk/jobs.gleam`: `payout_agent.run_id(request.id, failed)` names a new run per attempt; on `SupersededBefore` the handler calls `cancel_run`. The request to Fabric's maintainers is `/code/gleam-dream/decisions/docs/requests/fabric-tool-outcome-that-ends-a-run.md`.

## Done when

- The application can admit an agent's gated call and stop the run without writing its own cancellation, or the recipe documents the cancellation as the supported way until Fabric changes.
- The outcome is recorded against the request in ADR 0017 or its successor.

## Out of scope

Changing Fabric from this repository (ADR 0004, ADR 0017).

## Blocked by

None.
