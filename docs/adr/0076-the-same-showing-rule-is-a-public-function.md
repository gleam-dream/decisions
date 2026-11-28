# The "same showing again" rule is a public function

<a id="adr-0076"></a>

Recorded on 2026-11-28. Refines ADR-0066.

## Decision

- `decisions.showing(occurrence, by: validator, latest:) -> Option(Ticket)` is the rule of ADR-0066: the ticket of the validator's latest showing while nothing but showings was recorded after it and every input drifted to the revision it drifted to then; `None` when `open` would record a new showing.
- `open` applies `showing` after its checks (the occurrence can be shown, the validator may look, the validity has not passed), so the rule has one implementation and the public answer is the one `open` gives.
- `showing` is pure and reads only the occurrence it is given. It says nothing about whether `open` would admit the validator. A ticket from an occurrence read without a lock, or out of date, reaches the record only through `resume`, which checks it under the lock (`NeverShown`, `OutputChanged`, `NotAwaiting`).

## Why

- The rule lived in private functions of `open`. An application that needed to know whether the card it would present is the showing already recorded restated the rule, and its copy differed from the library's.

## Alternatives

- **Expose the private helper as it was.** It took the drift as an argument, so the application would still compute the drift itself.
- **No function; the application calls `open` and reads the ticket.** `open` records a showing when the rule says a new one is due, which is what such an application may want to avoid.

## Consequences

- When `open` records a new showing, it asks `latest` for each input twice: once in `showing`, once for the drift it records.

## What changes for consumers

- `decisions` (next release): new function; no call changes.
