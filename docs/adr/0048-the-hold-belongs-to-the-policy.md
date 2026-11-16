# The undo window belongs to the policy's `Proceed`

<a id="adr-0048"></a>

Recorded on 2026-11-16. Settles the open point of [ADR-0030](0030-who-may-withdraw-a-hold-and-a-hold-for-policy-acceptances.md#adr-0030).

## Decision

- A policy outcome `Proceed(sample:, hold: Option(Duration))` may carry a hold: an undo window on what the policy accepted by itself. When the outcome carries one, it is used; otherwise the point's `with_hold` applies.
- `decisions.with_policy_hold` is removed.
- A hold of zero or less is unpublishable (`NonPositiveHold`). The hold is stored as `hold_ms`; a stored policy without it decodes as no hold.
- A new policy version changes the window for new acceptances, not for an occurrence already held: the hold's end is fixed on the `held` entry.

## Rationale and alternatives

- A hold declared on the point applied to every autonomous acceptance of the point. The window is a judgment about autonomy, like the threshold that lets an output proceed, so it belongs with that threshold in the published, versioned policy: one version can hold small refunds for ten minutes and let others through at once.
- Keeping both the point's policy hold and the outcome's was rejected: two homes for one rule.

## Evidence and history

- The owner's ruling, 2026-11-16, on the recommendation recorded in ADR 0030 and tracker issue 13. `src/decisions/policy.gleam`, `Outcome`, `Fault.NonPositiveHold`; `examples/usage/src/decisions_usage/undo_window.gleam` (region `undo-window`) and `autonomy_ladder.gleam`.
- Applications that followed: `gleam-dream/oversight/apps/clinic_registration` (a ten-minute hold in policy version 2) and `gleam-dream/oversight/apps/payout_desk`.
