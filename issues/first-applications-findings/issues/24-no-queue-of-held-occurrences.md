# There is no queue of held occurrences to withdraw from

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0030, ADR 0048; term Withdrawer (record context).

## Behaviour wanted

A point with an undo window lets holders of the `withdrawn_by` set take a held occurrence back. Neither store offers a read of the occurrences currently held for a point, so a person who may withdraw has no list to choose from and must know the occurrence's id.

## Evidence

`gleam-dream/oversight/apps/clinic_registration/src/clinic_registration/web.gleam`: `POST /cards/:occurrence/withdraw` takes an id; the desk has queues for verdicts (`/queue`), reviews (`/reviews`) and pending messages (`/pending`), and none for held registrations. `/code/gleam-dream/decisions/integrations/decisions_postgres/src/decisions_postgres/queue.gleam` has `page`, `page_at`, `review_queue`, `pending`, and no read of held occurrences.

## Done when

- A withdrawer can list the held occurrences of a point, soonest end of hold first, from the store's heads, in both stores.
- The clinic's reception can find a registration to withdraw without knowing its id.

## Out of scope

Changing who may withdraw (ADR 0030).

## Blocked by

None.
