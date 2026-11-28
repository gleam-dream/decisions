# A tool can say it was contended

<a id="adr-0073"></a>

Recorded on 2026-11-28.

## Decision

- `vocabulary.Stop` gains `Contended(detail)`: the guard, the release check or the executor wrote nothing and may be sent again at once, because a lock of its own waited too long or deadlocked, or a verb it ran was contended. The savepoint rolls back, nothing is recorded, and the verb fails with `StoreFailed(store.Contended(detail))`, disposition `Transient`: a runtime delivers it again uncounted, `decisions_postgres` reports `Contended`.
- `decisions.stop_for(refusal)` is the one mapping from a refusal to a `Stop`, for a tool that runs a verb of another desk or a store call of its own (`stop_for(StoreFailed(error))`): `StoreFailed(Contended)` is `Contended`, any other `Transient` or `Retry` refusal is `Unsure`, and a `Poisoned` or `Final` refusal is `Refuse`.

## Why

- A tool could answer only `Refuse` or `Unsure`. A tool that took an application lock (`decisions_otp/store.lock`, a `SELECT ... FOR UPDATE`) or ran a verb on another occurrence, and was contended, had to answer `Unsure`. The verdict then failed with `ToolUnsure`, disposition `Retry`: a runtime counted the attempt toward setting the job aside, and an application told its user that the tool could not tell, when in fact nothing was written and the same verdict could be sent again at once. A test showed it: a guard contended on its lock failed the verdict with disposition `Retry`.
- Each application that nested a verb wrote its own mapping from the verb's disposition to a `Stop`, and each mapped contention to `Unsure`.

## Alternatives

- **Carry the application's own error type through the verb (`Stop(e)`, `Refusal(e)`).** The error would come back exactly as the tool built it, but every desk, refusal, runtime handler and port would gain a type parameter, and the port's `atomically` fixes its body's error type, so it would gain one too. The meaning a runtime acts on (deliver again, count, set aside, drop) is what was lost; the classification carries it without the parameter.
- **Carry a `store.StoreError` in `Stop`.** `decisions/store` imports `Stop` for the port's `atomically`, so `Stop` cannot name `StoreError` without moving one of the two types again; only contention needs a meaning `Unsure` lacks.
- **Leave the mapping to applications.** Each already wrote one, and each lost contention.

## What changes for consumers

- `decisions` (next release): a `case` over `vocabulary.Stop` adds the `Contended` branch. A tool that answered `Unsure` for a lock wait or a contended nested verb answers `Contended`, or `decisions.stop_for(refusal)` for a verb's refusal.
