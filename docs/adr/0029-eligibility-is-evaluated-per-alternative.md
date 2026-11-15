# Eligibility is evaluated per alternative, and an approval records the sets its validator held

<a id="adr-0029"></a>

## Decision

- Each `decided` entry records `holds`, the decision sets its validator held when they gave the verdict. An approval is credited with those sets.
- `occurrence.is_met(occurrence, eligible)` evaluates an eligibility over the approvals of the standing output, per alternative: `Several(count, of)` needs `count` different approvers each admitted by `of`, and `Either(list)` is met when any one alternative is. `Either([Several(2, AnyoneHolding("finance")), AnyoneHolding("head")])` accepts on two finance approvals or one by the head, never on one finance approval.
- `occurrence.admits` says whether one validator may decide: any alternative admits them. `policy.approvals(Either)` is the fewest approvals any alternative needs.
- Stored `decided` entries without the field decode with no sets.

## Rationale and alternatives

- The payout desk's policy asks for four eyes from 500.00, with the head of finance eligible after an hour. Written as `Either` around `Several`, it was accepted on a single approval, because the earlier rule asked an `Either` for one approval whatever its alternatives needed, so the second pair of eyes was never required. "Two from finance, or one senior" must mean what it says.
- Reading the validator's current sets at evaluation time was rejected: sets are a fact of the session, so they must be captured when the verdict is given.
- "One from finance and one from legal" (an `All` eligibility) is not built; the core's builder recommends it as a small addition, and it is pending in the record context.

## Evidence and history

- Application round, 2026-11-15 (`core-review/PUBLIC-CHANGES.md`, "The application round"). Driven by `/code/gleam-dream/worktrees/oversight-decisions/apps/payout_desk` (`test/payout_desk/robustness_test.gleam`, `a_restart_with_an_escalation_pending_lets_the_head_of_finance_decide_test`).
- `src/decisions/occurrence.gleam`, `admits`, `is_met`, `approvals`; `examples/usage/src/decisions_usage/two_or_one_senior.gleam` (region `either-several`) and its test.
