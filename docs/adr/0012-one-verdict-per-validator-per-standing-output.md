# Count I4 as one verdict per validator per standing output

<a id="adr-0012"></a>

## Decision

- I4 is "one deciding verdict per validator per output that stands", not STRESS.md's "per occurrence".
- A correction replaces the standing output and starts a new round of approvals that its author belongs to. Under `Several`, a validator who approved the standing output may not reject or correct it (`NotEligible`); after someone else corrects it, they decide again on the new output.

## Rationale and alternatives

- Four eyes on a corrected amount needs two fresh approvals of the new amount, possibly from someone who approved the old one. "Per occurrence" would forbid that and leave a corrected four-eyes occurrence unable to settle.
- Allowing an approver to reject later was considered and not chosen: it would let one person both count toward and veto the same output.

## Evidence and history

- `/code/gleam-dream/decision-point-lab/STRESS.md`, "The invariants"; `decisions/testing.gleam` module comment.
- `test/uc10_four_eyes_test.gleam`, `a_correction_voids_approvals_of_the_earlier_amount_test`; `test/corrections_test.gleam`, `c10_the_checker_sees_missing_wake_ups_and_a_wrong_head_test` and `c14_interface_corrections_test` (probe `k_`). Core review, corrections C10 and C14, 2026-11-15.
