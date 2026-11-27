# decisions_otp

[![CI](https://github.com/gleam-dream/decisions/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/decisions/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

> **Breaking:** decisions_otp 0.2.0 requires Sinal 0.2, which detaches a
> handler when the process that attached it exits. See the
> [migration guide](https://github.com/gleam-dream/decisions/blob/main/docs/MIGRATION.md).

The BEAM around [`decisions`](https://github.com/gleam-dream/decisions/blob/main/README.md): everything that needs
processes, and nothing that keeps the truth. The record stays in the store.
Every process this package starts acts on rows and keeps none, so each can be
killed at any instant and its replacement carries on.

| Module                    | What it gives                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `decisions_otp/store`     | A process-safe in-memory store: the storage port with real transactions, a lock per occurrence (also on an id that does not exist yet), deadlocks and lock waits refused as `Contended`, rollback when the holder dies, savepoints, wake-ups, notices and triggers as rows, indexed queue reads, paged reads of a point's occurrences for export (`occurrences_of`, `settled_since`), and a clock. A supervised child with `supervised` and `named`. Everything is lost when its owner process stops.                            |
| `decisions_otp/runtime`   | The supervised runtime: a sweeper for wake-ups, a dispatcher that delivers each settlement to its follower (handed the record as `decisions.Begun` or `decisions.NotBegun`, so a record that ended before it began reaches it too), and a bounded pool of workers for triggers, each trigger worked once. Followers and `work` return `decisions.HandlerFailure`. A `Control` pauses and resumes delivery; `supervised_from` configures it from the store's current handle at every start. Generic over `decisions_otp/backlog`. |
| `decisions_otp/backlog`   | The contract a store implements so the runtime can deliver its jobs.                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `decisions_otp/isolated`  | A model call in a process of its own with a deadline it cannot ignore, which dies with its caller; the failed attempt on the record; and `recommend_when`, a precondition checked inside the recommending transaction.                                                                                                                                                                                                                                                                                                           |
| `decisions_otp/replay`    | A replay spread over processes, with the same tally as the sequential one.                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `decisions_otp/live`      | Subscriptions to an occurrence, a point, a queue or a point's review queue: a hint after each commit that changed it, and `Missed(count)` as soon as a subscriber that fell behind has room again.                                                                                                                                                                                                                                                                                                                               |
| `decisions_otp/telemetry` | The Sinal events the runtime and isolated calls emit, each with its `source`, including `[decisions, job, dropped]` for a job removed as done.                                                                                                                                                                                                                                                                                                                                                                                   |
| `decisions_otp/stress`    | Conditions A and B (twenty-five race and crash scenarios) as scenarios any store can run.                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `decisions_otp/scale`     | Condition H and use case 12 as workloads any store can run.                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |

## What a kill loses

| Process     | Killed: what is lost                                                                                                      |
| ----------- | ------------------------------------------------------------------------------------------------------------------------- |
| Sweeper     | Nothing: a wake-up leaves the backlog only in the transaction that acts on it.                                            |
| Dispatcher  | Nothing: a notice is marked delivered in the transaction that runs the follower.                                          |
| Worker      | Nothing: its claim dies with it, another worker takes the trigger, and `recommend_once` makes a second delivery harmless. |
| Store owner | Everything: the tables live in its memory. The runtime goes down with it to the application's supervisor.                 |

Put the store first under a `RestForOne` supervisor and the runtime after it:
a restarted store is empty and every earlier handle fails, so the runtime must
restart with it and take a fresh handle. `test/wiring_example.gleam` holds this
tree as compiled code (region `otp-runtime`).

A follower or `work` returns `decisions.HandlerFailure`, and the runtime acts
on `decisions.handling` of it alone: `Redeliver` for contention or an
unavailable store, not counted; `Backoff` for an application failure, a raising
handler, a conflict, an unreadable policy, a failed consult or a tool that
answered `Unsure`, counted; `SetAside` for what needs an operator; `Drop` for a
job whose occurrence moved on. A runtime transaction that crashes, or a commit
whose outcome is unknown, is delivered again uncounted. After 20 counted
failures by default the job is set aside. Every commit is seen whole by every
reader, and `restart` keeps every acknowledged commit; `named` and `subscribe`
return an `OwnerError` instead of failing silently.

## Admitting a trigger

Admit a trigger in one transaction: `decisions.happened` with the point's
superseding event, then `decisions.expect` with the trigger's key, in that
order. `happened` takes the core's subject lock (an id this store locks
like any other and keeps nothing for), so two admissions about one subject
run one after the other and the later one supersedes the earlier key. The
other order can deadlock; this store refuses one of the two transactions
with `Contended`, and the runtime delivers it again.

## The two adapters compared

The two packages share the classification; their timing, live notifications,
setting aside and paging differ.

| Concern            | `decisions_otp`                                                                                                                                     | `decisions_postgres`                                                                                                             |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Classification     | `decisions.handling`, 20 attempts by default                                                                                                        | `decisions.handling`, 20 attempts by default                                                                                     |
| `Redeliver`        | Delivered again two looks later (about two `poll`s), not counted; the jobs behind it go on                                                          | Snoozed for 2 seconds, which uses no attempt; set aside after `with_snooze_limit` snoozes (1 000 unless set)                     |
| `Backoff`          | Waits `store.Config.retry_backoff`, doubled after each failure, at most 64 times                                                                    | Retried after Grind's backoff (15 seconds doubling, unless the registered worker sets a retry policy)                            |
| Live notifications | Topics for one occurrence, one point, one decision set's queue and one point's review queue; a subscriber that falls behind is sent `Missed(count)` | Everything, one point, or one occurrence; no `Missed`; `subscribe` is acknowledged and returns the listener's process to monitor |
| Setting aside      | Acts on a job of the backlog (a wake-up, a notice or a trigger)                                                                                     | `set_aside` acts on an occurrence; the workers set aside a wake-up row or a notice row                                           |
| `occurrences_of`   | Commit order                                                                                                                                        | Id order                                                                                                                         |
| `settled_since`    | Commit order                                                                                                                                        | Order of the admitting transactions, never passing one still running                                                             |
| Restart            | In the VM only: `restart` keeps every acknowledged commit; a stopped owner loses everything                                                         | Durable in the database                                                                                                          |

## Run the checks

From this directory, in the repository's development shell:

```sh
nix develop ../.. --command bash -c 'gleam format --check src test bench/src && gleam build --warnings-as-errors && gleam test'
```

The scale run (condition H and use case 12 against the in-memory store)
prints its load and the machine with every number; the retained capture is in
[`docs/BENCHMARKS.md`](https://github.com/gleam-dream/decisions/blob/main/docs/BENCHMARKS.md):

```sh
cd bench && nix develop ../../.. --command gleam run
```

The design of this package is in the runtime and storage contexts of the
[design layer](https://github.com/gleam-dream/decisions/blob/main/docs/design/design-layer.pdf).
