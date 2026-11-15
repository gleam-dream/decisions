# The stress scenarios are written once and run against every store

<a id="adr-0026"></a>

## Decision

- `decisions_otp/stress` holds the race and crash scenarios (A1 to A4, one key, the multi-process clauses of the port, B1, B2 and B4 to B7) against a `Target`, and `decisions_otp/scale` holds the H workloads and moderation at volume against the same target.
- Every store runs them: the OTP store in `decisions_otp`, and PostgreSQL in `decisions_postgres`, which depends on `decisions_otp` only as a dev-dependency. The PostgreSQL target drives the OTP runtime over its own tables through a test-only backlog; production delivery there stays Grind's.
- `gleam test` runs the scenarios at the light load (B5 at the default load, because the light load settles before five kills); `scripts/test-postgres.sh stress` runs them all at the default load.

## Rationale and alternatives

- The prototypes wrote their races twice, once per store, and the PostgreSQL copy found the admission race the in-memory copy could not. One copy run against both stores keeps the clauses that need several processes (ADR 0006) proved the same way everywhere.
- Keeping PostgreSQL's own race and kill tests only was rejected: they covered A1, one key, A3, the deadlock case, B1, B2 and B4, and left A2, A4 and B5 unproved against the database.
- Not covered: the PostgreSQL `NOTIFY` listener's reconnection after its connection drops; it is pending in the runtime context.

## Evidence and history

- Decided 2026-11-15. `integrations/decisions_otp/src/decisions_otp/stress.gleam`; `integrations/decisions_postgres/test/stress_target.gleam` and `test/decisions_postgres/stress_test.gleam`, `the_shared_scenarios_pass_against_postgres_test`; `integrations/decisions_otp/test/stress_test.gleam`, `every_scenario_is_run_test`.
- Later on 2026-11-15 the listener gained a connection check and a test: `integrations/decisions_postgres/test/decisions_postgres/live_test.gleam`, `the_listener_reconnects_and_polling_shows_what_was_missed_test`.
