# A refused verdict is recorded once per token; a failed attempt once per call

<a id="adr-0027"></a>

## Decision

- `record_refusal(rollback)` is safe to repeat. The token names one refused verdict (its validator, the verdict and the showing it was given on), and a second call with the same token appends nothing and returns the occurrence.
- `record_failure` records one attempt per call. Two attempts that failed alike look the same, so after an `Unavailable` outcome a caller reads the record (`NotRecommended(attempts)`) and calls again only if the attempt is not there.

## Rationale and alternatives

- A caller that lost the reply to `record_refusal` could not tell whether the refusal was kept; repeating it appended a second `verdict_refused` entry. The token already identifies the refusal, so the desk can find it.
- A failed attempt has no such identity: the trigger, the subject and the failure can repeat exactly. Giving attempts an identity was left open (pending in the record context), so the documented rule is to read before repeating.

## Evidence and history

- Found while writing the design layer on 2026-11-15 (`core-review/PUBLIC-CHANGES.md`, "Another round, from writing the design layer"). This refines ADR 0010.
- `src/decisions.gleam`, `record_refusal` and `record_failure`; `test/design_feedback_test.gleam`.
