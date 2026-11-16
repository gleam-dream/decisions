# Decide whether a held occurrence is superseded

Status: done
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0018 (open).

## Behaviour wanted

`happened` supersedes only undecided occurrences; a held occurrence keeps its hold and is released or refused when it ends. Whether a superseding event during a hold should stop the release is an owner decision.

## Evidence

`gleam-dream/oversight/apps/clinic_registration` and `gleam-dream/oversight/apps/moderation_desk` both supersede waiting recommendations when a newer message or an edit arrives (`delivery_test.gleam`, `a_newer_message_supersedes_the_waiting_recommendation_test`; `followers_test.gleam`, `an_edit_supersedes_a_waiting_recommendation_test`); neither holds and supersedes at once today.

## Done when

- The owner's ruling is recorded in a new ADR that supersedes ADR 0018, and the pending ruling "Whether a held occurrence is superseded" is cleared.

## Out of scope

Implementing the change before the ruling.

## Blocked by

None.

## Comments

AI-assisted contribution. Closed as `done` on 2026-11-16. The owner decided: a declared superseding event supersedes a held occurrence too; its wake-up is cancelled and nothing is released. Recorded in ADR 0049, which supersedes ADR 0018.
