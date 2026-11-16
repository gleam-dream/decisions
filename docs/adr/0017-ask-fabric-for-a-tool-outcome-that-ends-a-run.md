# Ask Fabric for a tool outcome that ends a run, and change nothing in Fabric for this build

<a id="adr-0017"></a>

## Decision

- The owner asks Fabric's maintainers for a tool outcome that ends an agent run. The request was filed on 16 November 2026 as [gleam-dream/fabric issue 5](https://github.com/gleam-dream/fabric/issues/5). Its text is retained in `docs/requests/fabric-tool-outcome-that-ends-a-run.md`.
- This build uses Fabric as published. The recipe for an agent's gated tool call parks the run on an approval no approver can give, with an approval that never expires, records the parked call as an occurrence, ends the run, and starts a fresh run when the occurrence settles.

## Rationale and alternatives

- Today only a final answer ends an agent run. Fabric's default approval expiry is seven days, and an expired request reads to the model as a rejection, so a parked run that is not ended can wake and act on stale context. The lab has a test in which such a run tells a customer a refund of 80.00 is done although no refund ran; in the companion test a person corrects the same refund to 60.00.
- A tool body that files the occurrence and returns "not refunded" lets the run continue, and what it then tells the customer is the model's choice; the lab's way-B test shows it claiming the refund is done while the occurrence still waits.
- Round one ranked this request second, behind a pin against pruning; round two moved it first on this evidence. A pin against pruning matters less once reads are recorded as evidence the application owns.

## Evidence and history

- `/code/gleam-dream/decision-point-lab/ledger_fabric/test/uc13_gated_tool_call_test.gleam`: `uc13_an_unclosed_parked_run_continues_when_its_approval_expires_test`, `uc13_bia_corrects_an_agents_gated_refund_test`, `uc13_way_b_a_tool_outcome_lets_the_run_continue_test`.
- `FINDINGS.md` and `FINDINGS-2.md`, "Should Fabric change". Owner decision 8, 2026-11-15.

## Note, 2026-11-15

- The recipe described above, which ends the parked run and starts a fresh run as the follow-on, is the lab's (`decision-point-lab/ledger_fabric`). The application built on the library, `payout_desk` in `gleam-dream/oversight`, does otherwise: it resumes the same parked run once the decision point has recorded the outcome (`apps/payout_desk/src/payout_desk/jobs.gleam`, `resume`). The approval never expires, only the decision point answers it, the gated tool returns the recorded outcome, and a reply is delivered only when it matches the record. Oversight's ADR 0035 records that choice.
- Both ways avoid the trap, and neither can make Fabric end a run from a tool outcome, so the request stands.
