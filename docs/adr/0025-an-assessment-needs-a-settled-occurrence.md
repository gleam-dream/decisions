# An assessment needs a settled occurrence

<a id="adr-0025"></a>

## Decision

- `assess` is refused with `NotSettled` on an occurrence that has not settled. Every settled status is accepted: released, rejected, expired, withdrawn and refused.
- Each call appends one assessment; repeating it records the finding again.

## Rationale and alternatives

- An assessment says whether the final output proved right. Before settlement there is no final output, and an assessment appended to a waiting occurrence would be scored against whatever it later became.
- Accepting assessments only on released occurrences was rejected: a rejection or an expiry can prove right or wrong later too.

## Evidence and history

- Found while writing the design layer on 2026-11-15, when the first pass recorded that `assess` accepted any status (`core-review/PUBLIC-CHANGES.md`, "Another round, from writing the design layer").
- `src/decisions.gleam`, `assess`; `test/design_feedback_test.gleam`.
