# The tally and the replay judge by one rule

<a id="adr-0024"></a>

Supersedes [ADR-0014](0014-each-occurrence-is-judged-once-against-the-recommendation.md#adr-0014).

## Decision

- An occurrence is judged when people let an output through. Walking its verdicts and then its reviews in order, an approval lets through the output that stands, a correction lets through its own output, and a rejection lets nothing through. A person's own act counts as that person's judgment of the output they proposed.
- Each judged occurrence counts once. In `learning.tally` it agrees when the output let through is the recommended output; in `learning.replay` when the candidate's output is `same` as it.
- An occurrence that was only rejected, or whose review rejected it, is judged by neither. Rejections are counted from the record. For the same occurrences `replay(..).tally.judged` equals the recorded tally's `judged`.

## Rationale and alternatives

- ADR 0014's tally judged an occurrence with any verdict and counted a rejection as disagreement, while replay never judged a rejection-only occurrence. The two agreement figures had different denominators, so a candidate's replayed agreement could not be compared with the recorded recommender's.
- Judging rejections in both was considered. A rejection lets no output through, so replay has nothing to compare a candidate's output with; a rejection is better counted directly from the record.

## Evidence and history

- Found while writing the design layer on 2026-11-15 (`core-review/PUBLIC-CHANGES.md`, "Another round, from writing the design layer").
- `src/decisions/learning.gleam`, `tally`, `replay` and `passed`; `test/design_feedback_test.gleam`; `examples/usage/test/decisions_usage_test.gleam`, `a_new_model_is_scored_on_recorded_decisions_test`.

## Note, 2026-11-15

- The final review of the core (finding R9) found that one approval of two followed by expiry counted as judged and agreed, and that a withdrawn acceptance counted as agreed. Both folds now judge only what people let through to acceptance (accepted, held, released, or accepted and then refused by the tool). A partial quorum that expired and a withdrawn occurrence are neither judged nor counted; a rejection is counted in `Tally.rejected`.
