# Each occurrence is judged once, against what the recommender proposed

<a id="adr-0014"></a>

## Decision

- `learning.tally` counts an occurrence toward agreement once, however many verdicts and reviews it has. It is judged when it has at least one; it agrees when every one approved and the final output equals the recommended output.
- A correction is disagreement. An approval given after another validator's correction approves the correction and does not agree with the recommender. An output the policy accepted with no verdict and no review is not judged.
- Each assessment counts toward accuracy.

## Rationale and alternatives

- The review found that an approval after a correction counted as agreement and that a four-eyes occurrence weighed as many times as it had approvals (C11), which inflated agreement exactly where the policy demanded more scrutiny.
- Counting each verdict was rejected for that reason. Treating a correction as partial agreement was left out: round one recorded the counting of corrections as open, and the review decided disagreement.

## Evidence and history

- `/code/gleam-dream/decision-point-lab/FINDINGS.md`, "What is still uncertain" (counting). Core review, correction C11, 2026-11-15.
- `test/corrections_test.gleam`, `c11_each_occurrence_is_judged_once_test`; `test/uc2_batch_test.gleam` and the moderation test in `integrations/decisions_otp/test/moderation_test.gleam` (agreement does not move when appeals arrive; accuracy does).
