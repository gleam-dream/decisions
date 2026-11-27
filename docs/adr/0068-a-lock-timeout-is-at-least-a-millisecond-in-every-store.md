# A lock timeout is at least a millisecond in every store

<a id="adr-0068"></a>

Recorded on 2026-11-27.

## Decision

- `decisions/store.LockTimeout` is the longest a transaction waits for an occurrence's lock before the store gives up with `Contended`. It is opaque and built only with `store.lock_timeout(milliseconds:)`, which refuses a value below one.
- Both integrations take it: `decisions_otp/store.Config.lock_timeout` and `decisions_postgres.with_lock_timeout(store, Option(LockTimeout))`. `None` still leaves PostgreSQL's connection setting alone.
- `store.default_lock_timeout` is 4 seconds, and both integrations use it unless told otherwise. The OTP store's default was 5 seconds.

## Why

- `decisions_postgres` sent `to_milliseconds(d) <> "ms"`. A duration under one millisecond became `0ms`, which PostgreSQL reads as "no timeout", so the safeguard of ADR 0051 was off and a wait could outlast `pog`'s 5-second checkout. A negative duration made every `load` fail with `22023`, reported as `Unavailable`.
- The OTP store clamped the same durations to 0, which there meant "refuse at once". One value meant three different things depending on the store.
- With a type that holds at least one millisecond, neither store can be asked for a wait that never ends or that ends before it starts.

## Alternatives

- **Clamp in each adapter.** It keeps `Duration` but silently changes what the caller asked for, and each adapter would have to agree on the clamp.
- **Keep two defaults.** The OTP store's 5 seconds had no reason of its own; one default is one fact to document.

## What changes for consumers

- Build a timeout with `store.lock_timeout(milliseconds: n)`; it returns `Error(Nil)` below one.
- An OTP store started with `store.defaults()` waits 4 seconds for a lock, not 5.
