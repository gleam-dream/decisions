# Paged reads follow commit order in both stores

<a id="adr-0044"></a>

## Decision

- `settled_since` pages a point's settlements in the order they committed, in both stores. In the OTP store the order is a number the owner gives each commit; in PostgreSQL it is the order of the admitting transactions, and a page holds only settlements whose transaction ended before every transaction still running began. A reader that keeps its cursor reads each settlement exactly once.
- The OTP store's `occurrences_of` also follows commit order; PostgreSQL's follows id order. Both cursors are opaque, and a page costs what it returns.

## Rationale and alternatives

- Both stores used a time taken before commit as the cursor, so a settlement that committed after a later-stamped one was skipped for ever by a reader that kept its cursor. The OTP pages also scanned the whole point index per page, so a full export was quadratic.
- Paging by the store clock with an overlap was rejected: it reads some settlements twice and still cannot bound the overlap.

## Evidence and history

- Independent review of both adapters, 2026-11-15, findings O3, O6 and G2 (probes PROBE3 and P2). `integrations/decisions_otp/src/decisions_otp/store.gleam`; `integrations/decisions_postgres/src/decisions_postgres/queue.gleam`, `settled_since` and `Position`.
- A paged export of 10 000 occurrences in the OTP store went from 166 ms to 3.6 ms (`docs/BENCHMARKS.md`). That `occurrences_of` orders differently in the two stores is a tracker issue.
