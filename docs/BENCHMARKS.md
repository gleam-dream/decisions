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

Captured on 2026-11-16 from the final source of the three packages, after the
last code change, on a quiet machine (load average 3 to 4). The repository was
not under Git, so no commit identifies the capture. The OTP figures are one run
of the bench package; the PostgreSQL figures are one run of
`scripts/test-postgres.sh scale`. An earlier capture of the same day, taken
before one fix, is quoted where it explains a change.

Machine: Apple M2 Max, 12 logical cores, 32 GiB of memory, Darwin 27.2.0,
Erlang/OTP 29 with 12 schedulers online. PostgreSQL 16.15 on the same machine,
started by `scripts/test-postgres.sh` with `fsync=off` and
`synchronous_commit=off`, and one pool of 24 connections shared by the workers
and Grind.

| Workload                                                | OTP in-memory store                                                                                       | PostgreSQL                                                      |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| H1, 1 process                                           | 250 ms, 40 039/s                                                                                          | 6 459 ms, 1 548/s; per call median 0.63 ms, p95 0.75 ms         |
| H1, 4 processes                                         | 158 ms, 63 421/s                                                                                          | 2 271 ms, 4 402/s; per call median 0.90 ms, p95 1.05 ms         |
| H1, 16 processes                                        | 125 ms, 79 751/s                                                                                          | 1 398 ms, 7 152/s; per call median 2.21 ms, p95 2.66 ms         |
| H2, queue page of 50 from 10 000                        | 15 µs                                                                                                     | median 0.42 ms, p95 0.85 ms                                     |
| H2, open and decide, 16 validators                      | per verdict median 0.51 ms, p95 0.74 ms; 30 200 verdicts/s                                                | all 10 000 at 4 424/s; per call median 3.58 ms, p95 4.18 ms     |
| H3, 10 / 100 / 1 000 entries                            | 0.06 / 0.25 / 3.46 ms                                                                                     | median 0.34 / 1.0 / 7.67 ms                                     |
| H4, 1 000 superseded by one event                       | 43.3 ms                                                                                                   | 392 ms, one transaction                                         |
| H5, 5 000 holds end together                            | 718 ms with one sweeper, 6 967/s                                                                          | 5.8 s through Grind, 867/s                                      |
| H6, replay of 10 000                                    | 16.7 ms in 1 process, 12.4 ms in 12                                                                       | reading the 10 000 records: 2 084 ms in 1 process, 435 ms in 16 |
| Export, 10 000 occurrences of one point in pages of 100 | `occurrences_of` 3.6 ms, `settled_since` 3.0 ms                                                           | not measured                                                    |
| Use case 12                                             | 144 ms: 9 000 proceeded, 1 000 waited, 179 sampled; agreement unchanged by the appeals, accuracy 20 of 50 | not run                                                         |

Further measurements in the same capture:

- PostgreSQL H1 with 16 processes and the tool run without a savepoint:
  10 074/s against 7 152/s with it. The port requires the savepoint
  ([ADR 0005](adr/0005-the-port-requires-an-absence-lock-a-savepoint-and-a-rich-head.md)).
- `NOTIFY`, from the start of the appending transaction to the subscriber:
  median 0.36 ms, p95 0.44 ms; it arrives before the writer's call returns.
- OTP, beside H4: the port's `waiting` over 10 000 waiting occurrences, 1 000
  of them about the subject, 272 µs in one call.

### What moved, and why

- **In-memory H1 with 16 processes** is about 80 000/s in both captures of
  2026-11-16 (84 200/s and 79 751/s), against 48 736/s retained on 2026-11-15.
  The earlier figure was captured while other work shared the machine. Nothing
  here shows that the code got faster.
- **H4 (1 000 superseded by one event).** The owner's round first made it
  slower: 59.6 ms in memory and 552 ms on PostgreSQL in the earlier capture of
  2026-11-16, because superseding read each occurrence twice through the port.
  That is fixed, with one load per superseded record
  (`happened_loads_each_record_once_test`), and the capture reads 43.3 ms and
  392 ms. The subject lock adds one `load` per `happened`.
- **In-memory H5** reads 718 ms, against 834 ms retained. The adapter's
  builder had measured the 5 000-holds workload going from about 336 ms to
  about 690 ms when every reader began to see a commit whole
  ([ADR 0043](adr/0043-an-in-memory-commit-is-whole-and-restart-is-one-step.md)).
- **A paged export of 10 000 occurrences** reads 3.6 ms, against 4.2 ms
  retained. The builder had measured it going from 166 ms to 3.6 ms when
  pages began to follow commit order from an index
  ([ADR 0044](adr/0044-paged-reads-follow-commit-order.md)).
- **PostgreSQL** H1 to H3, H5 and `NOTIFY` are within a few per cent of the
  retained figures, mostly slightly faster; the capture gives no reason beyond
  run-to-run variation.

### What admission costs in PostgreSQL

The prototype admitted 2 400 recommendations per second at one connection
(median 0.39 ms a call); the adapter admits about 1 550 (median 0.63 ms). The
scale run measures each suspected cost by removing it, from one process:

| Variant                                                    | Per second | Median per call |
| ---------------------------------------------------------- | ---------- | --------------- |
| As shipped, with Grind's consumers on the pool (H1)        | 1 548      | 0.63 ms         |
| As shipped, no Grind consumers on the pool                 | 1 565      | 0.62 ms         |
| and the node's clock instead of a query for the database's | 1 800      | 0.55 ms         |
| and no savepoint around the gated tool                     | 2 476      | 0.40 ms         |
| and no gap-check foreign key                               | 2 516      | 0.39 ms         |

- The savepoint is the largest part, about 0.15 ms a call (two round trips).
  The port's contract requires it.
- The store's clock is a query (`clock_timestamp()`, median 0.06 ms on its
  own), about 0.07 ms a call in admission. The prototype read the node's
  clock, which the contract no longer allows.
- The gap-check foreign key costs about 0.01 ms a call, within the noise, and
  Grind's consumers on the shared pool cost nothing measurable.
- With the savepoint, the clock query and the foreign key removed, a call
  takes 0.39 ms, the prototype's figure: in this capture nothing else remains
  to attribute.

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
