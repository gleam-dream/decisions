# Benchmarks: scale

`decisions` records what its verbs cost against the two stores that run them at
scale: the process-safe in-memory store of `decisions_otp` and PostgreSQL. The
measurements are observational evidence. They carry no threshold and never gate
a change; [ADR 0028](adr/0028-benchmarks-are-observational.md) records why. The
design's [verification gates](design/design.typ#verification-gates) and the
runtime context's [stress suite](design/runtime/design.typ#the-stress-suite)
state what the workloads are; this document retains the method, one capture per
store and the limits.

## Run

Both runs live outside `gleam test`. From the repository root, in the
development shell:

```sh
# The OTP in-memory store.
cd integrations/decisions_otp/bench && gleam run

# PostgreSQL, on a throwaway PostgreSQL 16 cluster made by the script.
bash scripts/test-postgres.sh scale
```

Each run prints the machine and the load with every number. Record the date,
the dependency locks, the machine and the system load beside a capture, and
compare captures only on the same machine and method.

## Method

- The workloads are written once, against a `decisions_otp/stress.Target`, in
  `decisions_otp/scale` (H1 to H6 and use case 12). The PostgreSQL run adds the
  cost of the savepoint, the port's `load` alone, one more append, and the delay
  of `NOTIFY` (`integrations/decisions_postgres/test/scale.gleam`).
- Every workload asserts that its work was done as well as timing it: a count
  that does not match is an error, not a number.
- Models are pure functions of the context, and the gated tool writes one row.
  Nothing calls a provider.
- Times are wall-clock milliseconds for a whole workload, or a median and 95th
  percentile per call where the line says so. Each number is one capture.

| Workload    | Load                                                                                                                    |
| ----------- | ----------------------------------------------------------------------------------------------------------------------- |
| H1          | 10 000 recommendations that the policy proceeds, so each releases once, from 1, 4 and 16 processes                      |
| H2          | 10 000 occurrences waiting for one decision set: a queue page of 50, then open and decide from 16 validator processes   |
| H3          | One occurrence of 10, 100 and 1 000 entries: load, decode and fold                                                      |
| H4          | 1 000 waiting occurrences about one subject, superseded by one event in one transaction                                 |
| H5          | 5 000 holds that end at the same moment, released by the deliverer                                                      |
| H6          | 10 000 recorded occurrences replayed through a pure candidate, from one and from many processes                         |
| Use case 12 | 10 000 posts from 8 processes; proceed at a score of 0.9 or more sampling 2 %, otherwise ask; 50 appeals as assessments |

## Retained measurements

Captured on 2026-11-15 from the final source of the three packages, after the
independent reviews and their corrections. The repository was not under Git,
so no commit identifies a capture. The OTP figures are one run of the bench
package; the PostgreSQL figures are the capture retained in the
[adapter's README](../integrations/decisions_postgres/README.md).

Machine: Apple M2 Max, 12 logical cores, 32 GiB of memory, Darwin 27.2.0,
Erlang/OTP 29 with 12 schedulers online. PostgreSQL 16.15 on the same machine,
started by `scripts/test-postgres.sh` with `fsync=off` and
`synchronous_commit=off`, and one pool of 24 connections shared by the workers
and Grind.

| Workload                                                | OTP in-memory store                                                                                       | PostgreSQL                                                  |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| H1, 1 process                                           | 263 ms, 37 955/s                                                                                          | 1 359/s                                                     |
| H1, 4 processes                                         | 210 ms, 47 635/s                                                                                          | 3 741/s                                                     |
| H1, 16 processes                                        | 205 ms, 48 736/s                                                                                          | 6 823/s                                                     |
| H2, queue page of 50 from 10 000                        | 15 µs                                                                                                     | median 0.45 ms, p95 0.90 ms                                 |
| H2, open and decide, 16 validators                      | per verdict median 0.65 ms, p95 1.17 ms; 22 665 verdicts/s                                                | all 10 000 at 4 336/s; per call median 3.64 ms, p95 4.28 ms |
| H3, 10 / 100 / 1 000 entries                            | 0.05 / 0.27 / 3.89 ms                                                                                     | median 0.40 / 1.1 / 7.8 ms                                  |
| H4, 1 000 superseded by one event                       | 41.6 ms                                                                                                   | 420 ms, one transaction                                     |
| H5, 5 000 holds end together                            | 834 ms with one sweeper, 5 993/s                                                                          | 6.2 s through Grind, 808/s                                  |
| H6, replay of 10 000                                    | 18.1 ms in 1 process, 14.9 ms in 12                                                                       | not retained                                                |
| Export, 10 000 occurrences of one point in pages of 100 | `occurrences_of` 4.2 ms, `settled_since` 3.3 ms                                                           | not retained                                                |
| Use case 12                                             | 172 ms: 9 000 proceeded, 1 000 waited, 179 sampled; agreement unchanged by the appeals, accuracy 20 of 50 | not run                                                     |

Further measurements in the same captures:

- PostgreSQL H1 with 16 processes and the tool run without a savepoint:
  9 321/s against 6 823/s with it. The port requires the savepoint
  ([ADR 0005](adr/0005-the-port-requires-an-absence-lock-a-savepoint-and-a-rich-head.md)).
- `NOTIFY`, from the start of the appending transaction to the subscriber:
  median 0.48 ms; it arrives before the writer's call returns.
- OTP, beside H4: the port's `waiting` over 10 000 waiting occurrences, 1 000
  of them about the subject, 282 µs in one call.

### What moved in the in-memory store, and why

- **H5 got slower.** The adapter review's corrections make every reader see a
  commit whole ([ADR 0043](adr/0043-an-in-memory-commit-is-whole-and-restart-is-one-step.md)).
  The sweeper's reads now wait for, or re-read around, a commit in progress.
  The adapter's builder measured the 5 000-holds workload going from about
  336 ms to about 690 ms; this capture measured 834 ms.
- **A paged export got cheaper.** Pages now follow commit order from an
  index and start from their cursor
  ([ADR 0044](adr/0044-paged-reads-follow-commit-order.md)). The builder
  measured a full export of 10 000 occurrences going from 166 ms to 3.6 ms;
  this capture measured 4.2 ms.
- **Admission is slower than in the first capture of the day** (H1 with 16
  processes: 92 925/s, then 62 636/s, now 48 736/s): each occurrence also
  writes index rows for the paged reads and the review queue, and every
  commit is applied whole.

### What admission costs in PostgreSQL

The prototype admitted 2 400 recommendations per second at one connection
(median 0.39 ms a call); the adapter admits about 1 400 (median 0.68 ms). The
adapter's scale run measures each suspected cost by removing it, 3 000
recommendations each from one process:

| Variant                                                    | Per second | Median per call |
| ---------------------------------------------------------- | ---------- | --------------- |
| As shipped, with Grind's consumers on the pool             | 1 416      | 0.68 ms         |
| As shipped, no Grind consumers on the pool                 | 1 404      | 0.68 ms         |
| and the node's clock instead of a query for the database's | 1 641      | 0.60 ms         |
| and no savepoint around the gated tool                     | 2 270      | 0.43 ms         |
| and no gap-check foreign key                               | 2 327      | 0.42 ms         |

- The savepoint is the largest part, about 0.17 ms a call (two round trips).
  The port's contract requires it.
- The store's clock is a query (`clock_timestamp()`), about 0.08 ms a call.
  The prototype read the node's clock, which the contract no longer allows.
- The gap-check foreign key costs about 0.01 ms a call, within the noise, and
  Grind's consumers on the shared pool cost nothing measurable.
- About 0.03 ms a call remains unattributed after the savepoint and the clock
  are removed. The candidates are the PL/pgSQL functions and the array
  parameters of `decisions_append`; they were not measured separately.

The prototype's other figures (`decision-point-lab/FINDINGS-2.md`, "Numbers")
were 9 400/s for H1 with 16 processes, a queue page in 0.23 ms, a load of
1 000 entries in 6.9 ms, H4 in 0.39 s and H5 in 5.7 s through Grind; it took
them with its own workloads, not with `decisions_otp/scale`.

## Limits

- One machine, one node, one capture per store. Nothing here is distributed,
  and no number has a confidence interval.
- The PostgreSQL cluster runs with `fsync=off` and `synchronous_commit=off`, so
  commits cost less than on a durable server. These numbers say nothing about
  durability or a production disk.
- Models are scripted and pure; no number includes a provider's latency, which
  dominates any real recommendation.
- The in-memory figures measure the cost of the verbs and of one owner process
  that grants locks and applies commits, not of a database.
- The prototype found that `pog` dropped a transaction's connection after 5
  seconds, which capped one superseding event at 11 000 to 13 000 waiting
  occurrences in one transaction. These packages did not measure that limit
  again.

## See also

- [`integrations/decisions_otp/README.md`](../integrations/decisions_otp/README.md)
  and [`integrations/decisions_postgres/README.md`](../integrations/decisions_postgres/README.md)
  for the run commands.
- `decision-point-lab/FINDINGS-2.md`, "Numbers", for the prototype's figures.
