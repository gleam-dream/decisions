# `decided_by` has no answer for an expired occurrence

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: Term Account and term Decider (record context).

## Behaviour wanted

`occurrence.decided_by` is `None` for an expired occurrence, because nobody decided. An application that must attribute every settled outcome (a reviewer's name for an audit) invents its own string for that case.

## Evidence

`gleam-dream/oversight/apps/payout_desk/src/payout_desk/jobs.gleam`: on `None` it uses `"decisions:" <> occurrence.status_name(known.status)`.

## Done when

- A settled occurrence names who or what is responsible for its outcome in every settled status, or the library documents one value applications use for "nobody decided".
- The payout desk no longer builds that name itself.

## Out of scope

Changing who is responsible for any other status.

## Blocked by

None.
