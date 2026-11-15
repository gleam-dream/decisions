# Two desks that consult each other need mutually recursive constructors

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: Term Consulting and term Consultation (record context).

## Behaviour wanted

A point whose policy consults another point needs a consult handler that recommends at the consulted desk, and the consulted desk's gated tool calls `inform` on the first desk. Each desk's constructor therefore builds the other, and the application writes mutually recursive functions to wire them.

## Evidence

`/code/gleam-dream/worktrees/oversight-decisions/apps/payout_desk/src/payout_desk/desks.gleam`: `payout` builds the `risk` assessment through `consulting`, and `risk`'s gated tool (`inform_payout`) builds the payout desk again.

## Done when

- Two desks that consult each other can be wired without mutually recursive constructors.
- The payout desk's consulting test still passes: `a_seller_with_chargebacks_is_assessed_by_risk_first_test`.

## Out of scope

Adding a registry of points or an engine process (ADR 0001).

## Blocked by

None.
