# Whether schedule and settled fold into the head is open; the port keeps eight functions

<a id="adr-0019"></a>

## Decision

- Open. The independent reviewer proposed that pending wake-ups and the settlement notice be derived from the head that `append` writes, instead of the desk calling `schedule` and `settled`.
- Until the owner rules, the port keeps its eight functions and the desk calls `schedule` when the occurrence's wake times change and `settled` once when it settles.

## Rationale and alternatives

- For folding: one write instead of three per verb; an adapter could not keep the head and the wake-ups out of step, which removes I5 and I6 failures by construction; the port shrinks to six functions.
- Against: the head would have to carry every wake time, not only the next due time, and an adapter would have to diff wake-ups itself; Grind's jobs are admitted per wake-up, so PostgreSQL would still write rows and jobs beside the head.
- The decision touches every adapter and the conformance suite, so it was kept out of the review's corrections.

## Evidence and history

- Core review of 2026-11-15, "Not to change": the shape of the port stays at eight functions and folding is an open question. Pending ruling in the storage context.
