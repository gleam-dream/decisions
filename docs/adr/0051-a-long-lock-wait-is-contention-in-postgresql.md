# A long lock wait is contention by default in PostgreSQL

<a id="adr-0051"></a>

Recorded on 2026-11-16.

## Decision

- `decisions_postgres` sets a lock timeout of 4 seconds when `load` takes an occurrence's lock (`with_lock_timeout`, default `Some(4 s)`). A wait longer than that ends with PostgreSQL's lock-timeout error, which the port reports as `Contended`.
- The setting applies to the rest of the caller's transaction and overrides a timeout the caller set earlier in it; `None` keeps the caller's or the role's setting.

## Rationale and alternatives

- `pog` checks a connection out for at most 5 seconds. A transaction still waiting for a contended occurrence then lost its connection, which reached the caller as `Unavailable`, an unknown outcome, for what was only contention. Below that limit a long wait ends as contention by construction, which a runtime redelivers uncounted (ADR 0039).
- Leaving the timeout to the application was rejected as the default: every application would meet the mislabelled failure first.

## Evidence and history

- The PostgreSQL adapter's round, 2026-11-16. `integrations/decisions_postgres/src/decisions_postgres.gleam`, `with_lock_timeout` and the port's error mapping (ADR 0022).
