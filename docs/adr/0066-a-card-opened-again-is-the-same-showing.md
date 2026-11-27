# A card opened again is the same showing, and a sampled release opens only to its possible reviewers

<a id="adr-0066"></a>

Recorded on 2026-11-27. Refines ADR-0011 and ADR-0040.

## Decision

- `open` returns the validator's latest showing, without appending an entry, when nothing but showings was recorded after it and the inputs show the same drift. Otherwise it records a new showing, as before. A card opened again is therefore the same card, with the same ticket.
- `open` of a released, sampled occurrence admits only someone `review` would admit: not whoever decided it, asked for it, recommended it as their own act or reviewed it, and, when the point names reviewers (`reviewed_by`), a holder of that set. It is the rule ADR-0040 states for `decide`, applied to `review`.
- The fold of a record runs in time linear in its entries: entries are gathered newest first and put in order once, and only a policy answer and a verdict, the transitions that read the record so far, are handed it in order.

## Why

- A page that reopened a card on every view, or a script, appended an `opened` entry each time, and every verb folded the whole record with a list append per entry. Reading records of 2 000, 4 000 and 8 000 `opened` entries took 7, 21 and 70 ms on the development machine: quadratic, under the record's lock. After this change the same reads take 4, 8 and 15 ms, and a reopened card adds nothing.
- On a released, sampled occurrence any caller-supplied validator could open the card, and each open grew the record, although `review` would then refuse most of them.

## Alternatives

- **Record every view.** It keeps a full audit of who looked, but the record then grows with every page load. `expand` already records what a validator opened beyond the card.
- **Only the linear fold.** It removes the quadratic cost but leaves the record growing without bound.

## What changes for consumers

- `decisions` 0.2.0: reopening a card with nothing changed returns the same card (its ticket is equal) and records nothing. `open` of a released, sampled occurrence returns `NotEligible` to someone `review` would refuse.
