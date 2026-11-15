# `recommend_when` needs an adapter around `decisions_postgres.transaction`

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0003 (three packages), ADR 0022 (contention).

## Behaviour wanted

`isolated.recommend` and `recommend_when` take `in:`, a transaction whose failure is a `Refusal`. `decisions_postgres.transaction` fails with its own `Failure`. An application on PostgreSQL writes its own transaction function that maps a query error to `StoreFailed(Unavailable(..))` to join the two packages.

## Evidence

`/code/gleam-dream/worktrees/oversight-decisions/apps/clinic_registration/src/clinic_registration/jobs.gleam`, function `in_transaction` (14 lines).

## Done when

- An application can pass a PostgreSQL transaction to the isolated recommend step without writing its own mapping.
- Failures keep their classification: contention stays `Contended`, an unknown commit stays `Unavailable`.
- The clinic's adapter can be deleted.

## Out of scope

Making `decisions_otp` depend on `decisions_postgres` or the reverse at run time.

## Blocked by

None.
