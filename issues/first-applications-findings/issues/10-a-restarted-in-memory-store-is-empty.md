# A restarted in-memory store is empty and every application seeds it

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: Storage context, "Adapters" (OTP store).

## Behaviour wanted

Under a supervisor, a restarted `decisions_otp/store` owner starts empty. An application with policies and reference rows adds a child that seeds the store when it holds no policy, after the store and before the runtime.

## Evidence

`/code/gleam-dream/worktrees/oversight-decisions/apps/moderation_desk/src/moderation_desk/app.gleam`, the `platform` child, and `src/moderation_desk/intake.gleam`, `seed`. Test: `/code/gleam-dream/worktrees/oversight-decisions/apps/moderation_desk/test/supervision_test.gleam`, `the_store_owner_killed_restarts_the_tree_on_an_empty_store_test`.

## Done when

- An application can declare what an empty store must hold so that a restarted store is usable, without its own seeding child, or the documentation states that seeding child as the supported way.
- The moderation desk's supervision test still passes.

## Out of scope

Persisting the in-memory store across a restart (use `decisions_postgres`).

## Blocked by

None.
