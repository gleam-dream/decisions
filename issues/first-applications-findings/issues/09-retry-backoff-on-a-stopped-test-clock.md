# The OTP store's retry backoff never ends under a stopped test clock

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: Term Store clock (storage context).

## Behaviour wanted

`decisions_otp/store` schedules a failed job's next delivery on the store's clock (`Config.retry_backoff`). With the `Stopped` clock a test uses, a job whose handler failed never becomes due again unless the test advances the clock.

## Evidence

`gleam-dream/oversight/apps/moderation_desk/src/moderation_desk/app.gleam` sets `retry_backoff` to 20 ms for its tests; `gleam-dream/oversight/apps/moderation_desk/test/cascade_test.gleam`, `a_raising_classifier_is_set_aside_after_three_attempts_test`.

## Done when

- A test with a stopped clock can see a failed job delivered again, or the documentation states plainly how a test must move the clock, and the moderation tests follow it.
- The behaviour is stated in the store's documentation and in the runtime design.

## Out of scope

Changing the wall-clock clause of the storage port.

## Blocked by

None.
