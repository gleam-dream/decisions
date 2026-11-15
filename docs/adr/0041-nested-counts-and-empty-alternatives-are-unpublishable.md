# Nested counts and empty alternatives are unpublishable

<a id="adr-0041"></a>

## Decision

- `policy.check` refuses a `Several` anywhere inside another `Several` (`NestedSeveral`) and an `Either` with no alternative (`EmptyEither`). The desk refuses to use such a policy (`Unpublishable`).

## Rationale and alternatives

- Approvals are counted once, by the outer count: `Ask(Several(1, Several(3, finance)))` released on one approval, and the policy was publishable. An `Either([])` left an occurrence waiting in no queue for ever.
- Giving nested counts a meaning was rejected: no application asked for one, and the `All` eligibility pending in the record context covers the real need.

## Evidence and history

- Final review of the core, 2026-11-15, finding R1. `src/decisions/policy.gleam`, `Fault`, `check`.
