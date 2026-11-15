# Three packages in one repository, around a pure core

<a id="adr-0003"></a>

## Decision

- `decisions` (the repository root) is the pure core: declaration, policy, entries, fold, desk, view, learning, the storage port, its memory adapter and its conformance suite. It starts no process, performs no I/O, and depends on `gleam_stdlib`, `gleam_json`, `gleam_time` and `json_blueprint` only. It builds for Erlang and JavaScript.
- `decisions_otp` (`integrations/decisions_otp`) holds what only processes can do: the process-safe store, the supervised runtime, isolated model calls, parallel replay, live hints and the stress suite. It may depend on `decisions`, `gleam_otp`, `gleam_erlang` and `sinal`.
- `decisions_postgres` (`integrations/decisions_postgres`) holds the port over PostgreSQL, its migrations, the Grind workers for wake-ups and settlements, `NOTIFY` and the queue queries. It may depend on `decisions`, `pog`, `grind` and `sinal`, with the `pog` and `pgo` ranges equal to Grind's.
- Each integration depends on the root by path while unpublished. The core never depends on an integration.

## Rationale and alternatives

- Round one used no processes and the core still should not (ADR 0002). Round two showed that what only the BEAM gives (a model call that cannot take its caller down, parallel replay, live cards, supervision, rollback when a process dies inside a transaction) belongs in its own package, so a page or a test that only folds a record never pulls in OTP.
- One package with optional modules was rejected: a dependency on `pog` or `gleam_otp` would reach every consumer of the core.
- The packaging follows Oversight's ADR 0003: a core package and its adapters in one repository, joins to other libraries as application recipes (ADR 0004).

## Evidence and history

- `/code/gleam-dream/decision-point-lab/FINDINGS-2.md`, "The answer" point 1 and "The recommended shape, revised". The pure half compiling for JavaScript was checked by building in round two; the core now runs one scenario there (`scripts/check_javascript.sh`).
- Owner decision 2 of the build brief, 2026-11-15.
