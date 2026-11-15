# The head says who may not decide

<a id="adr-0023"></a>

## Decision

- `store.Head` carries `may_not_decide`: who may not decide the occurrence whatever sets they hold. Under `SomeoneElseHolding` it is the requester and a person who recommended as their own act; under `Several`, whoever already approved the standing output; under `Either`, only who every alternative excludes. It is empty unless the occurrence awaits.
- `occurrence.head` derives it with the same rule the desk uses for eligibility, and the invariant check compares it like every other field of the head (I8).
- Every queue read leaves the card out for those validators: the memory store's `queue_for`, the OTP store's `queue_for` and `queue_page_for`, and the PostgreSQL `queue.page`, whose schema keeps the list on `decisions_occurrences` and `decisions_awaiting`.

## Rationale and alternatives

- The head already carried `approved` so that a queue would not hand a card back to someone who approved it (ADR 0005). It did not say that the person who asked for a refund may not approve it, so the queue offered Felipe his own request and the desk then refused him with `NotEligible`.
- Computing exclusions in each adapter's query was rejected: the rule lives in the core, and an adapter that reimplements it can disagree with the desk.

## Evidence and history

- Decided 2026-11-15 (`core-review/PUBLIC-CHANGES.md`, "A later round, driven by the adapters").
- `src/decisions/occurrence.gleam`, `head`; `src/decisions/store.gleam`, `Head`; `test/adapter_feedback_test.gleam`; `integrations/decisions_postgres/test/decisions_postgres/queue_test.gleam`, `a_page_orders_by_due_time_and_leaves_out_what_is_not_mine_test`; the conformance check "the head comes back as written".
