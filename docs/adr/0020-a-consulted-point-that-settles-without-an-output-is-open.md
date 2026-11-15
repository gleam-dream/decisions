# What a consulted point that settles without an output tells its consulter is open

<a id="adr-0020"></a>

## Decision

- Open. A consulted point that is rejected, expires or is withdrawn never reaches its gated tool, so it never calls `inform`, and the consulting occurrence waits until its deadline, or forever without one.
- Until the owner rules, the library does nothing automatically. `inform` with no facts is accepted and lets the consulting policy fall to its default; an application's follower of the consulted point can call it.

## Rationale and alternatives

- Both round-one builders hit this. The proposed fix is to inform with no facts on every settlement of the consulted point, so the policy falls to its default; it is not built.
- Alternatives: give `Consult` a fallback outcome in the policy; or record a distinct "consulted point settled without an output" entry the policy can read as a fact. Each changes the policy language or the entry kinds.

## Evidence and history

- `/code/gleam-dream/decision-point-lab/FINDINGS.md` and `FINDINGS-2.md`, "What is still uncertain" (carried from round one, ended 2026-11-14).
- `test/uc6_nested_review_test.gleam` covers the approving and rejecting review that do inform. Pending ruling in the record context.
