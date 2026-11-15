# Benchmarks are observational and gate nothing

<a id="adr-0028"></a>

## Decision

- The scale workloads (H1 to H6 and moderation at volume) run on demand: `cd integrations/decisions_otp/bench && gleam run` for the OTP store and `bash scripts/test-postgres.sh scale` for PostgreSQL. Each prints its load and the machine with every number and asserts that the work was done.
- `docs/BENCHMARKS.md` retains the method, the machine, one capture per store and the limits. No number is a threshold, and no gate runs the workloads.

## Rationale and alternatives

- The numbers depend on the machine, the database settings and the load; a threshold would fail on a slower CI runner and pass a regression on a faster one. The siblings keep their benchmarks the same way (Saga ADR 0011, Grind ADR 0009).
- Measuring inside `gleam test` was rejected: it would slow every run and turn timing noise into failures.

## Evidence and history

- Decided 2026-11-15. `integrations/decisions_otp/src/decisions_otp/scale.gleam`, `integrations/decisions_otp/bench/`, `integrations/decisions_postgres/test/scale.gleam`.
