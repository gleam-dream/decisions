# A held occurrence is superseded

<a id="adr-0049"></a>

Recorded on 2026-11-16. Supersedes [ADR-0018](0018-whether-a-held-occurrence-is-superseded-is-open.md#adr-0018).

## Decision

- A declared superseding event ends every record of the point about the subject that has released nothing, a held occurrence included: the hold's wake-up is cancelled, the occurrence expires as superseded, and nothing is released.
- A released occurrence is untouched.
- The port's `waiting` returns held records too (`store.is_waiting` covers pending, recommended, awaiting and held).

## Rationale and alternatives

- A reply drafted for an older message and held for withdrawal, or a payout held while the seller was suspended, is exactly what a newer event should stop. Releasing it at the hold's end, and relying on the guard to refuse, put the outcome on whichever check the application remembered to write.
- Letting each point choose was rejected: no application wanted a held output to survive a declared superseding event.

## Evidence and history

- The owner's ruling, 2026-11-16, on ADR 0018 and tracker issue 14. `src/decisions.gleam`, `happened`; `src/decisions/store.gleam`, `is_waiting`; the stress scenario "held superseded" in `integrations/decisions_otp/src/decisions_otp/stress.gleam`, run against both stores.
- `/code/gleam-dream/worktrees/oversight-decisions/apps/payout_desk`: a seller's suspension supersedes pending payouts, held or waiting.
