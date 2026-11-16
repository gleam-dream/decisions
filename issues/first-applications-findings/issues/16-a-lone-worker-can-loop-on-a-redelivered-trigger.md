# A lone worker can loop on a trigger that must be delivered again

Status: done
Category: bug

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: Runtime context, "The supervised runtime" and "Handler failures"; ADR 0039.

## Behaviour wanted

A trigger whose delivery ends `Redeliver` is left out of the worker's next look and delivered again two looks later. When it is the only worker, nothing else runs in between, so the worker can spend its time picking the same trigger up and putting it back while the condition that made it `Redeliver` (contention, an unavailable store) persists.

## Evidence

Reported by the builder of `decisions_otp` in the last round. The trigger path is `work` in `/code/gleam-dream/decisions/integrations/decisions_otp/src/decisions_otp/runtime.gleam` (module comment, "Timing"); no test runs one worker against a trigger that stays `Redeliver`.

## Done when

- With one worker and a trigger that keeps ending `Redeliver`, the worker still makes progress on other triggers and the trigger's redeliveries are spaced in time.
- A test with `workers: 1` shows it.

## Out of scope

Changing the handling classification (ADR 0039).

## Blocked by

None.

## Comments

AI-assisted contribution. Closed as `done` on 2026-11-16. A lone worker no longer loops on a trigger that keeps ending `Redeliver`: it leaves the trigger out of its looks for a time and works the others. Test: `/code/gleam-dream/decisions/integrations/decisions_otp/test/owner_round_test.gleam`, `a_lone_worker_does_not_loop_on_a_redelivered_trigger_test`.
