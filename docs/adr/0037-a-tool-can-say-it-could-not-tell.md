# A guard, a release check or an executor can say it could not tell

<a id="adr-0037"></a>

## Decision

- Guards, release checks and executors fail with `decisions.Stop`: `Refuse(reason)` refuses this release for good; `Unsure(reason)` says the tool could not tell, such as a lost database connection or a provider timeout.
- `Unsure` rolls the savepoint back, records nothing as refused, and fails the verb with the new refusal `ToolUnsure(reason)`, whose disposition is `Retry`: the caller or a runtime tries again, counted, and sets the job aside when the attempts are used.
- `Refuse` keeps its meaning: with a validator present the verdict rolls back (`ToolRefused`); with nobody waiting the occurrence ends `refused`.

## Rationale and alternatives

- A guard could only return `Error(String)`. A guard that lost its connection at a hold's wake-up therefore refused a held payout permanently: the occurrence ended `refused` although nothing about the payout was wrong.
- Retrying every tool error was rejected: a real refusal ("the account is closed") would then be retried until it was set aside, and the record would never show the refusal.

## Evidence and history

- Final review of the core, 2026-11-15, finding R10 (a transient guard failure at a hold's wake-up ends the occurrence `Refused` for good). `src/decisions.gleam`, `Stop`, `ToolUnsure`, the release; the core's tests of `Unsure` at a verdict and at a hold's wake-up.
- Open: `Unsure` at a hold's wake-up was not watched to fail with the fix removed; it is a tracker issue.
