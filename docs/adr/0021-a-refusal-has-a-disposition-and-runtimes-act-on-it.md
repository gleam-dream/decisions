# A refusal has a disposition, and the runtimes act on it

<a id="adr-0021"></a>

## Decision

- `decisions.disposition(refusal)` classifies every refusal as `Retry`, `Poisoned` or `Final`. `Retry` covers a failed store (`Conflict`, `Contended`, `Unavailable`), an unreadable policy and a consult handler that failed. `Poisoned` is `Unreadable`, a record that does not decode. Every other refusal is `Final`.
- The classification names every variant, so a variant added later fails to compile until it is classified.
- Both runtimes decide from the disposition, never from text. The OTP runtime delivers a `Retry` again without counting it, sets a `Poisoned` job aside at once, and removes a `Final` job as done with the `[decisions, job, dropped]` event; only the application's own handler failing is counted toward setting a job aside. The PostgreSQL workers snooze a `Retry` for 2 seconds, which uses no Grind attempt; set the record aside on `Poisoned`; and finish the job on `Final`.

## Rationale and alternatives

- Before this, the runtimes counted every failed delivery the same way. A contended store or a policy that could not be read for a moment counted toward setting a healthy job aside, and a refusal that would never change was retried until it was set aside as poison.
- Classifying by matching `describe` text was rejected: text is for people, and a reworded message would silently change delivery.
- A disposition per refusal kept by each runtime was rejected: two runtimes would drift. The core owns the refusals, so it owns their classification.

## Evidence and history

- Decided 2026-11-15 in the round driven by the adapters (`core-review/PUBLIC-CHANGES.md`, "A later round, driven by the adapters").
- `src/decisions.gleam`, `Disposition` and `disposition`; `test/adapter_feedback_test.gleam`. `integrations/decisions_otp/src/decisions_otp/runtime.gleam` (module comment, "Failure") and `test/runtime_test.gleam`; `integrations/decisions_postgres/src/decisions_postgres.gleam`, `wake_worker` and `settlement_worker`, and `test/decisions_postgres/delivery_test.gleam`.
