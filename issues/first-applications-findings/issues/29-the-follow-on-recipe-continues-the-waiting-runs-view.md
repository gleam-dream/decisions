# Does a follow-on run start from the world as it is, or from the handed-over run's history?

Status: done
Category: bug

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0052; the root design's recipe for a Fabric agent; the record context's term "Follow-on".

## Behaviour wanted

The design says two things about the run that follows a settled occurrence, and they disagree.

- The term "Follow-on" says it "builds its context from the world as it is, never from the waiting run's view", and the root design says what comes after an occurrence "must build its context from the world as it is".
- The recipe for an agent's gated call (ADR 0052) continues the ended run's history with the recorded outcome as the call's result. Fabric's `input.continuation` takes that history as the whole input, so the follow-on run sees every read the waiting run made, however stale it has become.

A case: Ana asks on Monday for an invoice while her address is Rua A; an operator changes it to Rua B that evening; the invoice is approved on Tuesday. The recipe's follow-on run reads Rua A from Monday's history unless the model chooses to read again.

dash-crm, the first consumer, ruled on 16 November 2026 that its follow-on run is a fresh run from the current world, with the outcome recorded on the customer's conversation, and that it does not use the recipe (dash-crm ADR-0062, on its branch `design/decision-points-on-typst-layer`). The package should say one thing.

## Evidence

- `docs/design/record/CONTEXT.typ`, the term `term-follow-on`.
- `docs/design/design.typ`, the row "The follower of each point and the follow-on run" and the recipe for a Fabric agent (the paragraph that cites ADR 0052).
- `docs/adr/0052-a-gated-agent-call-is-handed-over-and-told-in-a-follow-on-run.md`, the third decision bullet.

## Done when

- The design states one rule for a follow-on run's input, in the term, the root design, and the recipe alike.
- Either the recipe starts its follow-on from the world as it is, for example by refreshing the context the run reads, or the term and the root design say that the recipe continues the waiting run's view and what an application must do about the drift.
- If Fabric must change to accept a fresh context beside a continuation, the request is made there.

## Out of scope

Whether the follow-on is a run at all; the handover itself.

## Blocked by

None.

## Comments

AI-assisted contribution. Resolved by ADR 0053: the follow-on run starts fresh from the world as it is, and the recipe in the root design says so. `payout_desk` in Oversight still continues the history and needs its own change.
