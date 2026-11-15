# A parked agent run can wake on an expired approval and act on a decision made elsewhere

An agent run that is waiting for an approval resumes when the approval expires. The model then reads the expiry as a rejection and takes another turn. Nothing in Fabric lets a tool end the run instead, so an application that hands the decision to another system cannot stop the run from going on.

## Motivation

We are building `decisions`, a Gleam library for decision points: a model recommends an output, a policy proceeds or asks a person, the person approves, rejects or corrects, and the final output reaches a gated tool once. When a Fabric agent calls a gated tool mid-loop, the call becomes an occurrence in that library and a person decides it, possibly days later. The run that asked must not continue on its own: what the customer is told has to follow the person's verdict, not the model's guess about it.

With Fabric as published, the only way to keep the run from performing the call is to park it on an approval that no approver can give, and the only way to end it is a final answer from the model. The approval has an expiry (seven days by default, `agent.with_approval_expiry`), and an expired approval is an answer the model is given. A parked run that the application failed to end therefore wakes later and acts on stale context.

The other way available today, a tool body that files the decision and returns a result such as "filed for review, not refunded", lets the run continue at once, and what it says next is the model's choice.

## Example

The test `uc13_an_unclosed_parked_run_continues_when_its_approval_expires_test` in our prototype (`decision-point-lab/ledger_fabric/test/uc13_gated_tool_call_test.gleam`) shows it with a scripted model:

1. A support agent reads Ana's fee history and calls `refund_fee` with an amount of 80.00. A Fabric policy answers `refund_fee` with `RequireApproval`, the agent has no approvers, and the approval expiry is set to 50 ms.
2. The run is `Suspended` with one pending approval, after two model calls.
3. Nobody ends the run. After the expiry, the next read of the run expires the request and the model gets a third turn.
4. The run finishes `Completed` with the answer "Pronto, Ana: estornei os 80.00." ("Done, Ana: I refunded the 80.00.").
5. The refund itself never ran: the tool body was not called and no refund row exists.

In the companion test `uc13_bia_corrects_an_agents_gated_refund_test`, the same parked call is recorded as an occurrence, the run is ended, and a person corrects the refund to 60.00, which is released once; a fresh run then tells Ana that 60.00 was refunded. Had that run not been ended, step 4 would have told Ana a different amount, while the refund she actually gets is the one the person decided.

Expected: once the application has taken over the call, the run cannot continue, whatever happens to the approval. Observed: the run continues when the approval expires, and the customer is told something the record contradicts.

A second case, from an application rather than a prototype: the `payout_desk` example application parks a payout agent's `propose_payout` call the same way. In its test `the_trap_an_expired_approval_never_tells_the_seller_done_test` (`apps/payout_desk/test/payout_desk/truth_test.gleam` on Oversight's branch `decisions-examples`), the approval expires after one second, Fabric rejects the call, the model takes another turn, and the run answers "Done, Dora: 80.00 is on its way." while the decision is still waiting. Finance later corrects the payout to 60.00. The application does not end the parked run: it resumes the same run once the decision point has recorded the outcome. Only the decision point answers the approval, the gated tool returns the recorded outcome instead of its own arguments, and the seller hears a reply only when its outcome and amount match the record; otherwise the application sends its own message built from the record and keeps the model's text for review.

Setting the expiry to `run.Infinity` avoids the expiry, and both the prototype and the application do that. The prototype then ends the parked run and starts a fresh one; the application resumes the parked run from the record. Either way the run's safety rests on application code around Fabric, because no tool outcome can end the run when the call is handed over.

Is a run that a tool has handed to another system something Fabric should be able to express? If so, what must stay true about the run's record and its pending approvals when it ends that way?
