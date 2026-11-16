# Whether a held occurrence is superseded is open; it is not superseded until the owner rules

<a id="adr-0018"></a>

## Decision

- Open. The owner has not decided whether a superseding event that arrives during a hold should stop the release.
- Until the owner rules, `happened` supersedes only undecided occurrences (recommended or awaiting). A held occurrence is already accepted, keeps its hold, and is released or refused when the hold ends; its guard is checked again then.

## Rationale and alternatives

- For superseding during a hold: a reply drafted for an older message and held for withdrawal is exactly what a newer message should stop, and the hold exists so that something can still stop it.
- Against: a hold is the decider's window, not the world's; the guard checked at the hold's end can already refuse on any world fact, including "a newer message exists".
- A third option is to let the point declare which events also stop a hold. Each option changes `happened`, the `waiting` clause of the port (which returns only recommended and awaiting occurrences) and I3.

## Evidence and history

- Core review of 2026-11-15, correction C15: document that a held occurrence is not superseded and ask the owner, without changing the behavior.
- `src/decisions.gleam`, `superseded_by` and `happened`; `test/corrections_test.gleam`, `c15_documented_behaviour_holds_test`. Pending ruling in the record context.

## Note, 2026-11-16

- Decided by the owner: a held occurrence is superseded. See [ADR-0049](0049-a-held-occurrence-is-superseded.md#adr-0049).
