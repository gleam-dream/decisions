# Three applications are the consumer evidence, and their friction drives changes

<a id="adr-0036"></a>

## Decision

- Three Oversight applications use the packages end to end and are the evidence that the API serves real work: `clinic_registration` (PostgreSQL, one LLM call, a JSON desk API), `payout_desk` (PostgreSQL, a Fabric agent's gated tool call, Relay, Saga, four eyes, a hold) and `moderation_desk` (the OTP runtime with no database, a cascade, a live desk, replay gates).
- A change to the public API is made when an application hits friction it cannot reasonably work around, and each such change carries a test in the core or an integration and, where it is usage, a compiled example.
- The applications are in `gleam-dream/oversight` under `apps/`. They were merged into its `main` branch on 16 November 2026.

## Rationale and alternatives

- The use cases and stress conditions of the prototypes were written by the library's builders. Applications written against the finished packages found what those missed: eligibility across alternatives (ADR 0029), an undo window nobody could use (ADR 0030), a release check that needs the output (ADR 0031), sampling over sequential keys (ADR 0032), cards nobody could decide (ADR 0033), the superseding window (ADR 0034), two follower types (ADR 0035), and the ownership of the store and runtime in a supervision tree.
- Keeping the applications in this repository was rejected: they depend on Fabric, Relay, Saga and llm_wire, which no package may depend on (ADR 0004).

## Evidence and history

- `gleam-dream/oversight/apps/clinic_registration`, `gleam-dream/oversight/apps/payout_desk`, `gleam-dream/oversight/apps/moderation_desk`, each with its README and tests. Application round, 2026-11-15 (`core-review/PUBLIC-CHANGES.md`, "The application round").
