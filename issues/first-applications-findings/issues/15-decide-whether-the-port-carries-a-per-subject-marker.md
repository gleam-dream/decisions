# Decide whether the port carries a per-subject marker for the superseding window

Status: wontfix
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0034 (recorded as open there).

## Behaviour wanted

The superseding window is closed today by an application recipe and the `recommend_when` precondition. Whether the storage port should keep the latest trigger per subject itself, so every adapter closes the window, is an owner decision; it would add a port clause and a conformance check.

## Evidence

`gleam-dream/oversight/apps/clinic_registration/src/clinic_registration/jobs.gleam`, `still_latest`, keeps and locks the latest message per contact in its own row.

## Done when

- The owner's ruling is recorded in a new ADR, and the pending ruling "Whether the port carries a per-subject marker" is cleared or kept with the ruling cited.

## Out of scope

Implementing the change before the ruling.

## Blocked by

None.

## Comments

AI-assisted contribution. Closed as `wontfix` on 2026-11-16. Not needed: `decisions.expect` admits a trigger before the model runs, and `happened` takes a lock per point and subject through the port's existing `load`, so the superseding window is closed for every expected key without a new port clause. Recorded in ADR 0050, which settles ADR 0034's open question.
