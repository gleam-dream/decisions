# The in-memory backlog's reads are not consistent across a commit

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: Storage context, "Adapters" (OTP store); ADR 0043.

## Behaviour wanted

`due`, `undelivered` and `claim_trigger` of `decisions_otp/store.backlog` read committed rows raw: a commit seen in part can offer a job that a check under the job's lock then refuses. The store's module comment says every read of committed rows, the backlog included, sees each commit whole, which these three reads do not.

## Evidence

`/code/gleam-dream/decisions/integrations/decisions_otp/src/decisions_otp/store.gleam`, `backlog`: the comments at `due`, `undelivered` and `claim_trigger` ("A raw read ..."); the module comment "Commits are seen whole".

## Done when

- Either the three reads see each commit whole, or the store's documentation states the exception and why the re-check makes it safe.
- A test races commits against `due` or `claim_trigger` and shows no job is acted on twice or lost.

## Out of scope

The atomic commit of the other reads (ADR 0043).

## Blocked by

None.
