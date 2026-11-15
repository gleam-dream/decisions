# An application's own telemetry needs `source` passed by hand

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: Runtime context, "Telemetry".

## Behaviour wanted

Both runtimes name themselves in every event with `source`. An application that emits its own events beside them passes the same name by hand to each place that emits, so that a collector can count only its own application's events.

## Evidence

`/code/gleam-dream/worktrees/oversight-decisions/apps/moderation_desk/src/moderation_desk/telemetry.gleam` and `src/moderation_desk/desk.gleam`, which threads `source` through its state; `src/moderation_desk/app.gleam` makes the name.

## Done when

- An application can obtain the name its runtime or store emits with, and use it for its own events, without threading it through every process.
- The moderation desk's own events still carry the same `source` as the runtime's.

## Out of scope

Changing the event families of either package.

## Blocked by

None.
