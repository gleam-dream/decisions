# Keep a failed attempt and a refusal that rolled back on the record, each in a transaction of its own

<a id="adr-0010"></a>

## Decision

- A model failure before anything was recommended is recorded by `record_failure(key:, trigger:, about:, failure:)` as an `attempt_failed` entry, in a transaction of its own after the attempt's transaction rolled back. Failed attempts stay at the start of the record when a later attempt recommends.
- A verdict whose release the guard or the gated tool refused fails with `ToolRefused(reason, rollback)`. After its transaction rolled back, `record_refusal(rollback)` appends a `verdict_refused` entry in a transaction of its own. It changes no status.
- The rollback token is opaque and made only by the desk, so the record can only show a refusal that happened, by the validator who gave it, on the showing it was given on.
- `model.Failure` says why: not recorded, read failed, deadline, raised, undecodable or declined; `model.retryable` says whether trying again can help.

## Rationale and alternatives

- The transaction a failure happened in leaves nothing by design, so without a second write the record cannot show that a trigger was tried or that a verdict was refused. Registration in dash-crm already rolls a refused confirmation back and then stores the reason; the occurrence needs the same.
- Taking the refusal's fields from the caller was rejected after review: `record_refusal` once appended whatever it was given, and a validator holding no set could record a rejection on a released occurrence (C5).
- Keeping failures only in logs or telemetry was rejected: they would be outside the data the system learns from.

## Evidence and history

- `/code/gleam-dream/decision-point-lab/FINDINGS.md`, "What is still uncertain" (a refusal that rolls back leaves no trace); `FINDINGS-2.md`, "Smaller" items 1 and 2. `ledger_fabric/test/b7_agent_failures_test.gleam` and `ledger_llm/test/b7_single_call_failures_test.gleam`, `b7_a_failed_attempt_leaves_no_occurrence_and_disturbs_nothing_test`.
- In this repository: `test/defects_test.gleam`, `a_failed_attempt_is_on_the_record_test` and `failures_say_whether_a_retry_can_help_test`; `test/uc3_invoice_test.gleam`, `a_refusal_in_the_verdicts_transaction_rolls_both_back_and_is_recorded_test`; `test/corrections_test.gleam`, `c5_a_refusal_is_recorded_only_from_its_token_test`. Owner decision 5 and correction C5, 2026-11-15.
