# A follow-on run starts fresh from the world as it is

<a id="adr-0053"></a>

Recorded on 2026-11-16. Supersedes [ADR-0052](0052-a-gated-agent-call-is-handed-over-and-told-in-a-follow-on-run.md#adr-0052) in its follow-on run only; the handover stands.

## Decision

- When an occurrence that an agent's handed-over call became settles, the follower starts a fresh run. Its input is built from the world as it is, with the recorded outcome in it. It does not continue the handed-over run's history (`fabric.handover_history`, `input.continuation`).
- The follow-on run's policy still denies the gated call, so a model that proposes it again is not handed over a second time.
- The handed-over run stays the occurrence's explanation (`RunAction`) and is never continued.
- One rule now holds in the term "Follow-on", the root design's follow-on row, and the recipe for a Fabric agent.

## Rationale and alternatives

- ADR-0052's follow-on continued the ended run's history, which Fabric's continuation takes as the whole input. Every read the waiting run made reached the follow-on run, however stale, while the term "Follow-on" and the root design said a follow-on builds its context from the world as it is. An occurrence can wait for days: a customer's address changed overnight would be told from Monday's read.
- Continuing the history and refreshing the context beside it was considered. Fabric's continuation takes no input beside the history, so it would need a change to Fabric for a gain this rule does not need.
- Keeping the continuation and documenting the drift was rejected: every application would have to handle stale reads, and the first consumer, dash-crm, ruled for a fresh run (its ADR-0062).
- The cost is that the follow-on run loses the waiting run's reasoning; the outcome and the occurrence's record carry what it needs.

## Evidence and history

- Tracker issue 29 of `issues/first-applications-findings`.
- `gleam-dream/oversight/apps/payout_desk` still continues the history (`src/payout_desk/jobs.gleam`); converting it is its own change in Oversight.
