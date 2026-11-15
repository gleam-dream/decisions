# A queue can show a card to someone barred under the only alternative they qualify for

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0040; term May-not-decide list (storage context).

## Behaviour wanted

`Head.may_not_decide` lists who is barred under every alternative of the eligibility. A validator who qualifies under one alternative only and is barred there is not in the list, so the queue shows them the card, and `open` then refuses them with `NotEligible`.

## Evidence

`/code/gleam-dream/decisions/src/decisions/store.gleam`, `Head.may_not_decide`; `/code/gleam-dream/decisions/src/decisions.gleam`, `open` (which applies `decide`'s rule). The final core review's scenario: `Either([SomeoneElseHolding("finance"), AnyoneHolding("head")])` asked by a finance holder.

## Done when

- A queue page never offers a card that `open` would refuse with `NotEligible`, or the documentation of every queue read states that it may, and why.
- A test with the reviewer's scenario shows the chosen behaviour in both stores' queues.

## Out of scope

Changing who `decide` admits (ADR 0029).

## Blocked by

None.
