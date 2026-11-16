# A release check sees the output and records its evidence; the guard still does not

<a id="adr-0031"></a>

## Decision

- `decisions.checking(desk, with: check)` adds a release check: a function of the transaction and the released output that runs inside the release's savepoint, after the guard and before the executor. It returns the evidence it relied on, which the `released` entry records beside the guard's, or a reason; a refusal is a tool refusal like the guard's.
- `decisions.context_of(released)` gives the check and the executor the occurrence's context, never more than references.
- The guard keeps its type, a function of the transaction and the subject: it still never sees the output.

## Rationale and alternatives

- The payout desk must refuse a release the balance does not cover, at release, with the evidence of the balance on the record. That compares a fact of the world with the output, which neither the guard (no output) nor the policy (no world) can do.
- Handing the guard the output was rejected: the guard's blindness is what keeps thresholds on the output in the policy, where they are data, versioned and checked against declared facts (ADR 0013). Putting the check inside the executor was rejected: the record would not show what the release relied on.

## Evidence and history

- Application round, 2026-11-15. Driven by `gleam-dream/oversight/apps/payout_desk` (`test/payout_desk/policy_test.gleam`, `a_release_the_balance_does_not_cover_is_refused_and_kept_test`, `a_release_refused_after_the_hold_is_told_as_refused_test`).
- `src/decisions.gleam`, `checking`, `context_of` and the release; the fixture `fixtures/negative/a_guard_that_reads_the_output.gleam` still fails to compile.

## Note, 2026-11-15

- The title's claim that the guard does not see the output is withdrawn. A guard's parameters are the transaction and the subject, and carry no output; but a `drives` function receives the output and can close over it when it builds the gated tool, so the guard is not prevented from seeing it. The fixture is renamed to what it proves, `a_guard_is_handed_no_output`.
- What stays true: a check that needs the output belongs in the release check, where its evidence is recorded, and a threshold on the output alone belongs in the policy. The release check now receives a `ToRelease` value that no executor accepts (ADR 0038). Final review of the core, finding R11.
