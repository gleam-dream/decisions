# The port's contract is an executable suite, with the multi-process clauses in a stress suite

<a id="adr-0006"></a>

## Decision

- `decisions/conformance` states each clause one process can observe as a named check (twenty today). Every adapter runs it against a fresh store per check; the memory store, the OTP store and the PostgreSQL adapter all do.
- The core's own tests break an in-memory adapter in each clause in turn and show that the check naming it fails.
- The clauses one process cannot check honestly are listed in the module comment and proved by `decisions_otp/stress`: a load of an absent or present id waits for the holder; uncommitted writes are invisible; a kill inside a transaction or a savepoint leaves nothing; concurrent `happened` and `decide` do not deadlock; wake-ups and notices survive a restart; `now` is the wall clock; `schedule` leaves a delivered wake-up alone.
- `decisions/testing.check` checks I1 to I8 over any store after any scenario.

## Rationale and alternatives

- A contract written only as prose drifts: the independent review found a broken `waiting`, a frozen clock and an unchecked savepoint that all passed an earlier, shorter suite. A check that names its clause, and a broken adapter that fails it, keep the contract and the adapters together.
- Claiming the multi-process clauses inside the one-process suite was rejected: a frozen clock and a moving one look the same from one process, so such a check would pass falsely.

## Evidence and history

- `/code/gleam-dream/decisions/test/conformance_test.gleam`: `each_check_catches_its_broken_adapter_test`, `a_clock_that_moves_on_every_read_passes_test`. `integrations/decisions_otp/test/conformance_test.gleam` (a stopped and a wall clock) and `test/stress_test.gleam`; `integrations/decisions_postgres/test/decisions_postgres/conformance_test.gleam`.
- The core review of 2026-11-15, corrections C8 to C10 (conformance holes, the clock, the checker).
