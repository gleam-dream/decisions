# Decisions context map

## Contexts

- [Record](design/record/CONTEXT.typ) — the decision point's declaration, the occurrence and its append-only record, the lifecycle, cards and verdicts, gated tools and release, time, superseding and consulting, policy as data, models and their reads, the card document, and learning.
- [Storage](design/storage/CONTEXT.typ) — the storage port and its contract clause by clause, the head, pending wake-ups and settlement notices as stored, the conformance suite, the invariant check, and the memory, OTP and PostgreSQL adapters.
- [Runtime](design/runtime/CONTEXT.typ) — the processes around the record: the supervised runtime and its backlog, Grind delivery in PostgreSQL, isolated model calls, parallel replay, live hints, telemetry, the stress suite, and the recipes the application owns.

## Relationships

- Storage is the **supplier** and Record the **customer** of the storage port. Record states what it needs (an absence lock, a savepoint, a rich head, a clock read after the lock); Storage defines the port and its contract and every adapter is a **conformist** to it, checked by the conformance suite.
- Runtime is the **customer** of both. It calls Record's verbs (`wake`, `recommend_once`, `record_failure`, `read`), decides what to do after a refusal from Record's disposition, and reads Storage's pending wake-ups, settlement notices and heads; it defines no record semantics of its own.
- A term shared across contexts has one owning context. Record owns occurrence, entry, status, desk, refusal, disposition, stop, release, release check, policy hold, withdrawer, account, wake-up, superseding window, expectation, record not begun, subject lock and follow-on. Storage owns port, head, may-not-decide list, contention, lock timeout, paged read, absence lock, savepoint, store clock, pending wake-up and settlement notice. Runtime owns runtime, sweeper, dispatcher, worker, follower, handler failure, control, backlog, hint and stress suite. The others cite the owner's slug.
- Fabric, llm_wire and Relay are **separate ways**: no package depends on them, and their joins are recipes in the application.
