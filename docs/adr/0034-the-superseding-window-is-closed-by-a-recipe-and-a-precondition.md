# The superseding window is closed by a recipe and a precondition, not by the port

<a id="adr-0034"></a>

## Decision

- `happened` supersedes what waits when it runs. A worker that recommends from an older trigger and commits after `happened` creates an occurrence nothing supersedes.
- The application closes this window inside the transactions the verbs already run in: it keeps the latest trigger per subject in a row of its own, the transaction that calls `happened` updates that row, and the recommending transaction locks it and recommends only if its trigger is still the latest. `decisions.recommend_once` and `decisions.happened` document the recipe.
- `decisions_otp/isolated.recommend_when` runs such a precondition inside the recommending transaction and returns `Skipped(reason)` when it fails.
- Open: whether the port should keep a per-subject marker itself, so every adapter closes the window without application code. It is a pending ruling in the record context.

## Rationale and alternatives

- Both the clinic and the moderation desk met the window: a newer message, or an edit to a post, arrived while the model was still answering the older one.
- Changing the port was deferred: a per-subject marker is a new clause every adapter must meet and the conformance suite must check, and the recipe closes the window today with one row the application already has.

## Evidence and history

- Application round, 2026-11-15. Driven by `/code/gleam-dream/worktrees/oversight-decisions/apps/clinic_registration` (`test/clinic_registration/delivery_test.gleam`, `a_newer_message_supersedes_the_waiting_recommendation_test`) and `/code/gleam-dream/worktrees/oversight-decisions/apps/moderation_desk` (`test/followers_test.gleam`, `an_edit_supersedes_a_waiting_recommendation_test`).
- `src/decisions.gleam`, `recommend_once` and `happened`; `integrations/decisions_otp/src/decisions_otp/isolated.gleam`, `recommend_when`; `integrations/decisions_otp/test/round_test.gleam`, `a_precondition_that_fails_recommends_nothing_test`.

## Note, 2026-11-16

- The open question is settled without a port change: a trigger is admitted with `decisions.expect` before the model runs, and `happened` takes a subject lock through `load`. See [ADR-0050](0050-a-trigger-is-admitted-before-the-model-runs.md#adr-0050). The recipe and `recommend_when` remain for a key that was not expected first.
