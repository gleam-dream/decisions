# `occurrence.account` does not carry the release key

Status: done
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: Term Account and term Release key (record context), ADR 0007.

## Behaviour wanted

`occurrence.account` returns `Done(final, effect)` for a released occurrence. A follower that must send an effect under the release key still matches `occurrence.status` to obtain it, so the account does not replace the status match it was meant to replace.

## Evidence

`/code/gleam-dream/worktrees/oversight-decisions/apps/clinic_registration/src/clinic_registration/jobs.gleam`, function `follower`: it matches `occurrence.Released(final:, key:, ..)` to build the confirmation job.

## Done when

- A follower can obtain the final output and the release key from one value that states what really happened.
- The clinic's follower no longer matches the status.

## Out of scope

Changing the release key's form (`release:` and the occurrence id).

## Blocked by

None.

## Comments

AI-assisted contribution. Closed as `done` on 2026-11-16. `occurrence.Account.Done(final, key, effect)` carries the release key. Code: `/code/gleam-dream/decisions/src/decisions/occurrence.gleam`, `Account`.
