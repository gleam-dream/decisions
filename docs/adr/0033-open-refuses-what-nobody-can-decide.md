# `open` refuses an occurrence nobody can give a verdict on

<a id="adr-0033"></a>

## Decision

- `open` records a showing only for an occurrence a verdict can be given on: one awaiting verdicts, to a holder of a set it waits for, or one released and sampled, for its review.
- Any other is refused with what a card would run into: `AlreadyDecided(by)` when someone's verdict settled it, `NotSampled` when the policy released it unsampled, and `NotAwaiting` otherwise.
- To send a verdict again after a lost reply, the caller resumes the card from its ticket.

## Rationale and alternatives

- `open` used to return a card for anything and record nothing, so a desk page read before the lock showed a card whose verdict then failed. Two moderators working one queue, and a receptionist acting on a page a colleague had just decided, met this as a confusing second step.
- Keeping the permissive `open` and refusing only at `decide` was rejected: the refusal belongs where the validator first meets the occurrence.

## Evidence and history

- Application round, 2026-11-15. Driven by `/code/gleam-dream/worktrees/oversight-decisions/apps/moderation_desk` (`test/desk_test.gleam`, `two_moderators_work_one_queue_without_colliding_test`) and `/code/gleam-dream/worktrees/oversight-decisions/apps/clinic_registration` (`test/clinic_registration/desk_test.gleam`).
- `src/decisions.gleam`, `open`.
