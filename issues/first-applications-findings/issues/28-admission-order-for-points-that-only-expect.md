# Do two expectations about one subject need an order when no `happened` runs?

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0050; record context pending ruling "Admission order for points that only expect".

## Behaviour wanted

`happened` loads a lock per point and subject before it reads which records wait, so two `happened` calls about one subject run one after the other. A point whose triggers are admitted with `expect` alone, with no superseding event, has no such order between two expectations about one subject. No application needs that order today; the first one that does should say what it needs.

## Evidence

`/code/gleam-dream/decisions/src/decisions.gleam`, `happened` (loads `subject_lock`) and `expect` (does not).

## Done when

- The first application that admits triggers about one subject with `expect` alone states whether their order matters, and the decision is recorded.
- If it matters, both stores give the order and a test shows it.

## Out of scope

Changing `happened`'s lock.

## Blocked by

None.
