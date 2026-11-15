# Sampling hashes the occurrence id with SHA-256

<a id="adr-0032"></a>

## Decision

- `policy.is_sampled(sample, id)` decides whether a proceeding occurrence is sampled for review from the SHA-256 hash of its id. The same occurrence is always sampled or never, and a replay samples alike.
- `model.digest`, which names evidence by its content, is SHA-256 in lowercase hex as well.

## Rationale and alternatives

- The earlier sample used a short polynomial hash of the id. Applications key occurrences by sequential ids (`message-41`, `message-42`), and over such keys the short hash sampled far from the stated share. A cryptographic hash is uniform whatever the ids look like.
- Random sampling was rejected: a replay or a second read must sample the same occurrences.

## Evidence and history

- Application round, 2026-11-15 (`core-review/PUBLIC-CHANGES.md`). Driven by `/code/gleam-dream/worktrees/oversight-decisions/apps/moderation_desk` (`test/desk_test.gleam`, `a_reviewer_works_the_sampled_queue_test`) and the moderation workload of `decisions_otp/scale`.
- `src/decisions/policy.gleam`, `is_sampled`; `src/decisions/model.gleam`, `digest`.
