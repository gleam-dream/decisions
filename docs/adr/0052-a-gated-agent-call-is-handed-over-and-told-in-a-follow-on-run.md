# A gated agent call is handed over, and its outcome is told in a follow-on run

<a id="adr-0052"></a>

Recorded on 2026-11-16. Supersedes [ADR-0017](0017-ask-fabric-for-a-tool-outcome-that-ends-a-run.md#adr-0017).

## Decision

- The recipe for an agent's gated tool call uses Fabric's handover, released in `fabric` 0.3.0 on 16 November 2026. The agent's policy answers the gated call with `policy.HandOver(reason)`. The tool body never runs, the model takes no further turn, and the run ends as `run.HandedOver(action, tool, arguments_json, reason)`.
- The application records the handed-over call as an occurrence. Its trigger and its explanation name the action in Fabric's text form (`run.action_ref_to_string`, `run.action_id_to_string`).
- When the occurrence settles, the application starts a follow-on run. Its whole input is the handed-over run's history with the recorded outcome as the call's result (`fabric.handover_history`, then `input.continuation`). The handed-over run never continues.
- The follow-on run's policy denies the gated call, so a model that proposes again is not handed over a second time.
- The recipe involves no Fabric approval. Nothing can expire and answer the model, so the trap ADR 0017 describes cannot occur.
- The request in ADR 0017 is closed. Fabric answered it with a policy decision, not with the tool outcome the request asked for, and the owner accepted that answer on 16 November 2026.
- This repository changes nothing in Fabric, and none of the three packages depends on it (ADR 0004). The recipe stays application code.

## Rationale and alternatives

- An approval that no approver can give was the only way to keep a run from performing a gated call. An expired approval reads to the model as a rejection, so both earlier ways had to set an approval that never expires and guard every answer to it. The handover removes the approval.
- Fabric rejected a tool-body outcome that ends the run, for two reasons its ADR 0021 records. A tool body's outcome can be lost with its runner, and settling an effect whose outcome is uncertain continues the run. A policy decision is taken before the tool body and is recorded with the action.
- The follow-on run continues from the call's result, with no user message after it. The first conversion had to invent a follow-on prompt; Fabric added `input.continuation` before the release so that no prompt is invented.
- A fresh run for each failed agent attempt stays. A run that failed has ended and cannot continue, so the handover does not remove it.

## Evidence and history

- [gleam-dream/fabric issue 5](https://github.com/gleam-dream/fabric/issues/5), closed by Fabric's pull request 6 and its ADR 0021. `fabric` 0.3.0 is on Hex; the PostgreSQL adapter that requires it is tagged `fabric_postgres-v0.2.0`.
- `gleam-dream/oversight/apps/payout_desk`, merged into Oversight's `main` on 16 November 2026 (pull request 6) and recorded in Oversight's ADR 0039: `src/payout_desk/agent.gleam` (the policy), `src/payout_desk/jobs.gleam` (filing and telling), `test/payout_desk/truth_test.gleam` (the ended run, no pending approval, and a model that proposes again in the follow-on run).
- The application was converted against Fabric's pull request before the release. That found four gaps Fabric closed before 0.3.0: the invented follow-on prompt, the missing text form of an action, and two undocumented points.
- Not shown: a live provider accepting a follow-on input that ends in tool results (the tests use scripted models), and a run parked by the earlier mechanism, which `fabric.handover_history` refuses (`NotHandedOver`). The lab's recipe (`decision-point-lab/ledger_fabric`) is not converted.
- Tracker issue 26 of `issues/first-applications-findings`.
