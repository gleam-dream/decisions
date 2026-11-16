# The payout desk starts a fresh Fabric run per retry and cancels a parked run itself

Status: done
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0017, ADR 0050.

## Behaviour wanted

The payout desk drives a new Fabric run for each failed attempt of a request, and when a newer event supersedes the payout while the agent works, it cancels the parked run itself on `SupersededBefore`. Both are application code around Fabric that a tool outcome ending a run would make unnecessary.

## Evidence

`gleam-dream/oversight/apps/payout_desk/src/payout_desk/jobs.gleam`: `payout_agent.run_id(request.id, failed)` names a new run per attempt; on `SupersededBefore` the handler calls `cancel_run`. The request to Fabric's maintainers is `/code/gleam-dream/decisions/docs/requests/fabric-tool-outcome-that-ends-a-run.md`.

## Done when

- The application can admit an agent's gated call and stop the run without writing its own cancellation, or the recipe documents the cancellation as the supported way until Fabric changes.
- The outcome is recorded against the request in ADR 0017 or its successor.

## Out of scope

Changing Fabric from this repository (ADR 0004, ADR 0017).

## Blocked by

None.

## Comments

AI-assisted contribution. Closed as `done` on 2026-11-16. Fabric 0.3.0 hands a gated call over by policy and ends the run, so `payout_desk` no longer parks a run and cancels nothing on `SupersededBefore`: the run has already ended when the payout is admitted. Recorded in ADR 0052, which supersedes ADR 0017, and in Oversight's ADR 0039. The fresh run for each failed attempt stays. A failed run has ended and cannot continue, so the handover does not make it unnecessary; the comparison in "Behaviour wanted" was wrong on that half.
