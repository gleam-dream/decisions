# `open` and `resume` refuse whoever `decide` would refuse

<a id="adr-0040"></a>

## Decision

- `open` and `resume` apply the eligibility `decide` applies and refuse with `NotEligible` anyone no alternative admits, before a showing is recorded.
- `AlreadyDecided(by)` names only a verdict that settled the occurrence; an occurrence that expired after a partial quorum is `NotAwaiting`.
- `Head.may_not_decide` lists who is barred under every alternative, so a queue may still show a card to someone barred under the only alternative they qualify for; `open` refuses them.

## Rationale and alternatives

- Under `Either([SomeoneElseHolding("finance"), AnyoneHolding("head")])` asked by a finance holder, the head's list did not contain her, `open` recorded a showing, and `decide` refused her: a showing on the record for someone who could never decide.
- Making the head list exact per alternative was rejected for this build: the queue would need to know which alternative a validator qualifies under. The remaining gap is a tracker issue.

## Evidence and history

- Final review of the core, 2026-11-15, findings R5 and R7. `src/decisions.gleam`, `open`, `resume`, `decide`; `src/decisions/store.gleam`, `Head.may_not_decide`. This refines ADR 0033.
