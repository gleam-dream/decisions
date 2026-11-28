# An application reads a committed head without a lock

<a id="adr-0075"></a>

Recorded on 2026-11-28.

## Decision

- `decisions_otp/store.head(store, id)` and `decisions_postgres.head(db, occurrence:)` return the committed head of one record, `None` when there is none. Each takes the `Store` or the `Pool`, as the other reads outside a verb do (ADR 0063), takes no lock and waits for none.
- The inspection stays what it was: what an adapter supplies to `decisions/conformance` and `decisions/testing`. The port's documentation names the committed reads as the application's way to look.
- No verb takes a `Head`. A verb loads and locks the record itself, so a head that is out of date by the time a verb runs cannot be decided on; it only routes a card, shows a queue, or tells a screen whether an occurrence still waits.

## Why

- An application routed cards, checked whether an occurrence still awaited a verdict and drew change hints from `inspection().head(tx, id)`, which the library marks as test-only. The supported reads were the whole list (`decisions_otp/store.heads`, which reads every head), the queue reads, or `decisions.read`, which locks the occurrence and so waits behind a verdict in progress and holds the lock for the rest of the reader's transaction.
- In PostgreSQL the inspection runs in the caller's transaction; read for a screen, it kept that transaction open across the screen's other reads.

## Alternatives

- **Promote the inspection to an application API.** It takes a transaction, so an application would open one to read a head, and every adapter would owe applications a surface that exists for the conformance suite.
- **A lock-free read in the port and a core `decisions.peek(desk, tx, id)` returning the decoded record.** Every adapter and the conformance suite would grow a function, and a decoded `Occurrence` read without a lock invites deciding on it; the head answers what was needed (status, the sets it waits for, who may not decide).

## What changes for consumers

- `decisions_otp` and `decisions_postgres` (next release): replace `inspection().head(tx, id)` outside tests with `store.head(store, id)` or `decisions_postgres.head(pool, occurrence: id)`. In `decisions_otp` it returns `Option(Head)`; in `decisions_postgres`, `Result(Option(Head), StoreError)`.
