# An occurrence may carry its own deadline

Status: done
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0054 (extends ADR 0008 and ADR 0050); the record context's sections "Admission", "The lifecycle" and "Time"; the terms "Deadline", "Effective deadline", "Lapsed occurrence" and "Expectation"; invariants I3 and I5 in the root design.

## Behaviour wanted

dash-crm, Dash's back office answering customers by WhatsApp, drafts each reply as an occurrence of its point `reply.draft`. A reply may be sent only until 24 hours after the customer's latest message. Each occurrence's deadline is an instant the application knows when it admits the trigger, and it differs per occurrence. dash-crm asks to pass it at admission (on the expectation) and again at recommendation (on the proposal, for a key it did not expect first). Today a point's validity counts from the recommendation, and an expectation has no deadline at all.

A case: Ana writes on Monday at 09:00:00, so her window closes on Tuesday at 09:00:00. dash-crm calls `expect_until(key: "reply:<message id>", about: Subject("party", ana), valid_until: Tuesday 09:00:00)` in the transaction that stores her message. The model answers on Monday at 09:01:30 and dash-crm calls `recommend_once`; nobody reviews. On Tuesday at 09:00:00 the occurrence expires with cause `DeadlinePassed`, and a verdict on Tuesday at 09:00:01 is refused with `NotAwaiting`. If the model keeps failing instead, the record not begun expires on Tuesday at 09:00:00 too, and a later `record_failure` is refused with `DeadlinePassedBefore`; a recommendation that comes after the deadline is recorded and expired at once (the owner's ruling of 2026-11-17).

## Build plan

Test-first, one slice per step; each step leaves every package green. C = created, M = modified.

1. **Core record and verbs.**
   - Files: M `src/decisions/entry.gleam` (`Expected.valid_until`, omitted from JSON when `None`; module doc on what may precede `recommended`); M `src/decisions/occurrence.gleam` (`Pending.valid_until`, `Pending.superseded` renamed `ended`, `pending_head` with `due`, `pending_wake_times`, `pending_has_lapsed`, fold accepting `recommended` after `expired(DeadlinePassed)`, docs); M `src/decisions.gleam` (`expect_until`, `valid_until`, `DeadlinePassedBefore` with its disposition and description, `superseded_before` no longer mapping `DeadlinePassed`, `recommend_once` going on to `begin` after a deadline expiry, `begin` with the effective deadline, the expiry-first shape and `Draft.settled` from the pending record, `append_pending` scheduling when the pending wake times change, `wake` and `supersede` on a record not begun, rounding to milliseconds, docs of `expect`, `Supersession`, `read_record`); M `src/decisions/testing.gleam` (`see_pending` requires `pending_wake_times`, module doc; the I3 exception); M `src/decisions/learning.gleam` (`Coverage.lapsed_before`); M tests that name `superseded` or build `Coverage` (`test/owner_round_test.gleam`).
   - Tests in C `test/deadline_per_occurrence_test.gleam`, which this step owns: the worked case (expires at the deadline, `open` refused before any wake-up); a verdict one second late; a model that keeps failing (early wake-up `NotDue`, expiry, notice, later `record_failure` and `expect_until` refused with nothing written, wake-up again `NothingDue`); `expect` without a deadline on a lapsed record refused; `read` refused and `read_record` `NotBegun` on a lapsed record; the clock deciding without a wake-up; a late recommendation after the wake-up and before it, giving the same entries, status, one notice and no wake-up; a proposal deadline already passed through `recommend`; `expect_until` with a deadline already passed; the point's validity bounding the deadline; a proposal never moving it later and setting it earlier; a repeated expectation keeping the earliest; `happened` before the deadline (superseded, wake-up cancelled) and after it (deadline passed); an expectation without a deadline stored byte for byte as before; a sub-millisecond deadline rounded down; a restart; `testing.check` after each, and a dropped wake-up reported as I5.
2. **Conformance.** M `src/decisions/conformance.gleam`: a port-level check "a pending head keeps its due time and a wake-up", appending a `pending` head with `due` and scheduling a wake-up for it, read back through the inspection. M the storage design's count of checks. It runs against the memory store in `test/conformance_test.gleam` here, and against the OTP and PostgreSQL stores in steps 3 and 4.
3. **OTP.** M `integrations/decisions_otp/src/decisions_otp/isolated.gleam` (`Attempted.Lapsed(deadline)`, documented as growing in a minor release); M `integrations/decisions_otp/src/decisions_otp/stress.gleam` (its match on `Attempted`; a shared scenario "an expected record expires at its own deadline": one key whose model fails and lapses, one recommended that expires, one recommended late, run with the store's wake-up delivery and a restart before the deadline); M `integrations/decisions_otp/test/stress_test.gleam` (count 24 and the new test); M the PostgreSQL package's `test/decisions_postgres/stress_test.gleam` (count 24 and `scenario_23_test`), so both packages stay green; M docs of `runtime.point` and `isolated` on a record lapsed before it began. Test: `isolated.recommend` returns `Lapsed(deadline)` after the deadline.
4. **PostgreSQL.** No migration: `due` is a nullable `timestamptz` with no status constraint. M `integrations/decisions_postgres/src/decisions_postgres.gleam` (docs of `settlement_worker`). Tests in M `integrations/decisions_postgres/test/decisions_postgres/behaviour_test.gleam`: the Grind wake worker snoozes an early wake-up and expires a record not begun at its deadline through `deliver_due`; a late recommendation after that wake-up commits with one notice; `queue.pending` reports the due time.
5. **Usage and README.** C `examples/usage/src/decisions_usage/deadline_per_occurrence.gleam` with a `snips` region and its test in `examples/usage/test`; M `README.md` with the section; `scripts/check_javascript.sh` stays green.

## Done when

- An occurrence with its own deadline expires at that time on both runtimes; one without behaves exactly as before, byte for byte in its stored entries.
- Every existing test passes, and `nix flake check`, the design gate and `scripts/test.sh --require-all` pass.

## Out of scope

Moving a deadline later (a pending ruling in the record context). A deadline on `isolated.Request`: the expectation carries it.

## Blocked by

None.

## Comments

AI-assisted contribution. Review of the design and this plan, 2026-11-17: simplicity, inventive, comprehension, critic, structure and style, readiness and code-match reviewers. The owner ruled on a late recommendation (recorded and expired). Findings settled in the design and this plan; the proposal deadline is kept because dash-crm's request names it.

AI-assisted contribution. Built on branch `claude/deadline-per-occurrence-74ebb9`, 2026-11-17, as local commits awaiting the owner. `scripts/test.sh --require-all`, `nix flake check`, the design gate and the snips check pass. Beyond the plan, `wake` answers `LapsedBefore(pending)` when it expires a record not begun (ADR 0054 lists it for consumers). The in-memory runtime drops a lapsed record's notice while PostgreSQL hands it to the follower, the same split as issue 27.
