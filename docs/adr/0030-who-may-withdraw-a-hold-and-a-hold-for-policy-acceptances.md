# A point names who may withdraw a hold, and may hold only what the policy accepted

<a id="adr-0030"></a>

## Decision

- `decisions.withdrawn_by(point, set)` lets holders of `set` withdraw a held occurrence besides its decider, through `withdraw_as(desk, tx, occurrence:, by: validator)`. Without it only the decider may.
- `decisions.with_policy_hold(point, duration)` holds only what the policy accepted on its own: an undo window on autonomous decisions. An output a validator accepted is released at once unless `with_hold` also applies; when both are declared, a policy acceptance waits for the policy hold.
- Open: the core's builder recommends moving the policy hold into the policy outcome (`Proceed` with a hold), so that a policy version decides which autonomous acceptances wait. It is recorded as a pending ruling, not decided.

## Rationale and alternatives

- The decider of an output the policy accepted from a model is nobody, so `with_hold` alone gave an undo window no one could use. Holding every acceptance also delayed outputs a person had already approved, which the payout desk did not want.
- Letting anyone holding the decision set withdraw was rejected: withdrawing is a separate authority from deciding, and the point names it.

## Evidence and history

- Application round, 2026-11-15. Driven by `/code/gleam-dream/worktrees/oversight-decisions/apps/payout_desk` (`test/payout_desk/robustness_test.gleam`, `withdraw_during_the_hold_and_after_it_test`, `a_restart_with_a_hold_pending_releases_after_it_test`).
- `src/decisions.gleam`, `with_policy_hold`, `withdrawn_by`, `withdraw_as`; `examples/usage/src/decisions_usage/undo_window.gleam` (region `undo-window`) and its test.

## Note, 2026-11-16

- The open point is settled: the policy hold moved into the policy outcome, `Proceed(sample:, hold:)`, and `with_policy_hold` is removed. See [ADR-0048](0048-the-hold-belongs-to-the-policy.md#adr-0048). `withdrawn_by` and `withdraw_as` are unchanged.
