# One handler-failure type for both runtimes

<a id="adr-0035"></a>

## Decision

- A settlement follower and a job handler return `decisions.HandlerFailure`: `DeskRefused(refusal)` when a verb of a desk refused, `ApplicationFailed(reason)` when the application's own work failed.
- `decisions.handling(failure)` gives the refusal's disposition for `DeskRefused` and `Retry` for `ApplicationFailed`.
- The OTP runtime and the PostgreSQL settlement worker act on it the same way: a `Retry` refusal is delivered again without counting, `Poisoned` is set aside at once, `Final` finishes the job, and an application failure or a raise is counted and set aside after the last attempt. Only the defaults differ: three attempts and the store's doubling backoff in OTP, 20 attempts (`with_settlement_attempts`) and Grind's backoff in PostgreSQL.

## Rationale and alternatives

- Before this, the OTP follower returned text and the PostgreSQL follower returned a refusal, so the same follower behaved differently on the two stores, and an application failure could not be told from a desk refusal. The clinic's confirmation follower calls a messaging provider and verbs of a desk; it needs both kinds.
- One disposition for both kinds was rejected: a provider that is down must eventually set the notice aside for an operator, so an application failure is counted where a transient desk refusal is not.

## Evidence and history

- Application round, 2026-11-15. Driven by `/code/gleam-dream/worktrees/oversight-decisions/apps/clinic_registration` (`test/clinic_registration/confirmation_test.gleam`) and `/code/gleam-dream/worktrees/oversight-decisions/apps/moderation_desk` (`test/supervision_test.gleam`, `the_dispatcher_killed_mid_handler_loses_nothing_test`).
- `src/decisions.gleam`, `HandlerFailure` and `handling`; `integrations/decisions_otp/test/round_test.gleam`, `a_handler_failure_is_acted_on_by_kind_test`; `integrations/decisions_postgres/src/decisions_postgres.gleam`, `settlement_worker`. This refines ADR 0021.

## Later the same day

- `decisions.handling(failure)` now returns its own type, `Handling`: `Redeliver` (a `Retry` refusal, not counted), `Backoff` (an application failure or a raise, counted), `SetAside` (a `Poisoned` refusal) and `Drop` (a `Final` refusal). Both runtimes act on that value alone, so no runtime reads `ApplicationFailed` as `Retry`.
- Both runtimes allow 20 attempts by default (`decisions_otp/runtime.Config.attempts` and `decisions_postgres.with_settlement_attempts`), and both name themselves in telemetry with `source`.
- Evidence: `src/decisions.gleam`, `Handling` and `handling`; `integrations/decisions_otp/src/decisions_otp/runtime.gleam` (module comment, "Failure"); `integrations/decisions_postgres/src/decisions_postgres.gleam`, `wake_worker` and `settlement_worker`.
