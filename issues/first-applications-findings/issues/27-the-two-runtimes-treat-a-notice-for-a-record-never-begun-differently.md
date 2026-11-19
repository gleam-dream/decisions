# The in-memory runtime drops a notice for a record superseded before it began; PostgreSQL hands it to the follower

Status: in-progress
Category: bug

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: Runtime context, "The two adapters compared"; ADR 0050.

## Behaviour wanted

A record superseded before it began admits a settlement notice. `decisions_postgres.settlement_worker` hands it to the point's follower like any other, and a follower that reads it gets `SupersededBefore`. `decisions_otp/runtime` reads the occurrence before it calls the follower, the read is refused with `SupersededBefore`, whose handling is `Drop`, and the follower is never called. The same follower sees the notice on one store and not on the other.

## Evidence

`integrations/decisions_postgres/src/decisions_postgres.gleam`, `settlement_worker` (its doc states the PostgreSQL behaviour); `integrations/decisions_otp/src/decisions_otp/runtime.gleam`, `point`, which reads with `decisions.read` before the follower runs.

## Done when

- A follower sees the same notices on both stores, or both READMEs state the difference in the same words.
- A test in each package shows what a follower receives for a record superseded before it began.

## Build plan

Ruled by the owner: fix before `decisions_otp` is first published. Design: ADR 0055, the runtime context's `runtime.point` paragraph and term Follower. C = created, M = modified.

1. **Failing test, under today's follower type.** M `integrations/decisions_otp/src/decisions_otp/stress.gleam`: a scenario appended last, "every settlement notice reaches the follower, begun or not", with a row in the module's scenario table. Keys: one superseded before it began; one lapsed at its own deadline by its wake-up; one lapsed and then recommended late before the runtime delivers its notice (handed over as `Begun`, `Expired(DeadlinePassed)`); one recommended and rejected by a verdict (an ordinary settlement). The OTP runtime over the target delivers. The follower writes one row per call with `target.add` in the delivery's transaction, with no de-duplication; the scenario asserts one row per key, no undelivered notice and nothing set aside. Today this fails: the first two keys get no row. M `integrations/decisions_otp/test/stress_test.gleam` (count 25, `every_settlement_notice_reaches_the_follower_test`) and `integrations/decisions_postgres/test/decisions_postgres/stress_test.gleam` (count 25, `scenario_24_test`).
2. **Fix.** M `integrations/decisions_otp/src/decisions_otp/runtime.gleam`: `point`'s `settled` takes `decisions.Record(o)` from `read_record`; `nothing_follows` likewise; module and function docs. The scenario's follower then records the variant and cause, and the scenario asserts them per key: `NotBegun` ended by the event; `NotBegun` ended by `DeadlinePassed`; `Begun` expired by `DeadlinePassed`; `Begun` rejected. Custom followers to adapt: `stress.gleam` (`follow` in B5, the failing follower in B6); `integrations/decisions_otp/test/runtime_test.gleam` (the followers near lines 96, 230, 374); `integrations/decisions_otp/test/round_test.gleam` (line 80); `integrations/decisions_otp/test/wiring_example.gleam` (the README snippet's source). Callers passing `nothing_follows` or `fn(_, _)` compile unchanged (`scale.gleam`, `owner_round_test.gleam`, `review_test.gleam`). M `README.md`, regenerated with `nix run .#snips -- --commands deny README.md`.
3. **PostgreSQL.** M `integrations/decisions_postgres/test/decisions_postgres/owner_round_test.gleam`: add `every_notice_reaches_the_follower_as_not_begun_test`: a key superseded before it began and a key expected with its own deadline that Grind expires (wakers given) each reach a follower that reads with `read_record` once, as `NotBegun` with its cause, counted by a row the follower writes in its transaction. Expected green on arrival: it characterises what the Grind worker already does. M `integrations/decisions_postgres/src/decisions_postgres.gleam`, `Follower` and `settlement_worker` docs: read with `read_record` to see the same `Begun` or `NotBegun` the OTP runtime hands over.
4. **Docs.** M `integrations/decisions_otp/README.md` (the follower is handed `Begun` or `NotBegun`; the scenario count, 25). M `integrations/decisions_otp/test/owner_round_test.gleam` (the comment that says the notice is dropped). M the root README's prose on the OTP follower.

## Out of scope

Whether such a record should admit a notice at all.

## Blocked by

None.
