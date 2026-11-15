# The bound on key length is enforced by the PostgreSQL adapter, not by the core

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0046.

## Behaviour wanted

An occurrence id and a point name longer than 255 bytes are refused by `decisions_postgres` with `Conflict`, because of PostgreSQL's `NOTIFY` limit. The core and the OTP store accept them. A key that works in tests over the OTP store is refused in production over PostgreSQL, and the refusal is a store conflict rather than a typed refusal the caller can name.

## Evidence

`/code/gleam-dream/decisions/integrations/decisions_postgres/src/decisions_postgres.gleam`, `max_name_bytes`; `/code/gleam-dream/decisions/src/decisions.gleam`, `recommend_once` and `point` (no bound).

## Done when

- A key or point name over the bound is refused the same way on every store, with a refusal whose meaning the caller can branch on, or the core documents the bound and the OTP store enforces it too.
- Tests in the core and both packages show the bound.

## Out of scope

Raising PostgreSQL's payload limit.

## Blocked by

None.
