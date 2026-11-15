# `occurrences_of` orders by commit in one store and by id in the other

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: Runtime context, "The two adapters compared"; ADR 0044.

## Behaviour wanted

`decisions_otp/store.occurrences_of` pages in commit order, so a reader that keeps its cursor reads each occurrence once, including one committed while it reads. `decisions_postgres/queue.occurrences_of` pages in id order, so an occurrence made during an export whose id sorts before the cursor is not returned. Code written against one store behaves differently on the other.

## Evidence

`/code/gleam-dream/decisions/integrations/decisions_otp/src/decisions_otp/store.gleam`, `occurrences_of`; `/code/gleam-dream/decisions/integrations/decisions_postgres/src/decisions_postgres/queue.gleam`, `occurrences_of` (its doc points to `settled_since` for repeated exports).

## Done when

- Both stores give `occurrences_of` the same ordering guarantee, or both document the difference in the same words and the README of each says which to use for a repeated export.
- A test in each package shows the chosen guarantee.

## Out of scope

`settled_since`, which already follows commit order in both (ADR 0044).

## Blocked by

None.
