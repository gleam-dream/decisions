# A verdict is bound to the showing it was given on

<a id="adr-0011"></a>

## Decision

- `open` records a showing for an awaiting occurrence, or for a sampled released one, and the card carries its sequence number. A card opened while the occurrence was not waiting for verdicts records nothing and cannot decide.
- `decide` and `review` require a recorded showing to the card's holder at the card's `seen` (`NeverShown`).
- A verdict on a card shown before another validator corrected the output is refused with `OutputChanged`, directly and through `resume`. The validator opens the card again and decides on the output that stands.
- "The same verdict sent again" is the same verdict on the same showing, so a lost reply can be retried and a newly opened card is a new showing.
- The card and its document show the output that stands and the approvals so far beside the recommendation.

## Rationale and alternatives

- The review found that an approval counted for an output the validator never saw: under `Several(2, ..)`, Ana opened and saw 100, Bia corrected to 999, Ana's old card approved, and 999 was released (C1). It also found that a card opened while the occurrence waited for a consulted point was not recorded yet decided later (C6).
- Re-checking only the status at verdict time was rejected: the status was still awaiting in the failing case. Locking the occurrence while a card is open was rejected: a card can stay open across requests for hours.

## Evidence and history

- Core review of 2026-11-15, corrections C1 and C6, with the probe scenarios `a_`, `l_` and `f_` that passed before the correction.
- In this repository: `test/corrections_test.gleam`, `c1_a_stale_card_cannot_approve_a_correction_test` and `c6_only_a_recorded_showing_decides_and_only_the_consulted_point_answers_test`; `test/e_context_test.gleam`, `what_the_validator_opened_and_saw_is_on_the_record_test` (E4: the verdict names its showing).
