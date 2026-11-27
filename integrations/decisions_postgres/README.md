# decisions_postgres

[![CI](https://github.com/gleam-dream/decisions/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/decisions/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

> **Breaking:** decisions_postgres 0.3.0 requires Sinal 0.2 and Grind 0.3,
> whose schema version 15 must be applied first. See the
> [migration guide](https://github.com/gleam-dream/decisions/blob/main/docs/MIGRATION.md).

The PostgreSQL store for [`decisions`](https://github.com/gleam-dream/decisions/blob/main/README.md): the storage port over
the application's own transactions, the migrations that create its tables, the
Grind workers that deliver wake-ups and settlement notices, `NOTIFY` on every
append, and queue queries that never decode an entry. The detailed contract is
the module documentation of `decisions_postgres`, `decisions_postgres/queue`,
`decisions_postgres/live` and `decisions_postgres/telemetry`, and the storage
and runtime contexts of the [design layer](https://github.com/gleam-dream/decisions/blob/main/docs/design/design-layer.pdf).

## Wire it

The application owns the pool and the Grind runtime. In this order:

1. Run `migrate(db)` at deploy time with a role that may own DDL, or apply the
   SQL in `priv/migrations` with the application's tool, before any worker
   polls. Choose one migration owner per schema. Grind's own schema is
   Grind's to migrate, and must be at version 15 or later (Grind 0.3):
   `grind.migrate`, `grind.with_startup_migration`, or Grind's migration
   files in the application's tool.
2. Build a store with `decisions_postgres.new(grind.named(name))`; the handle
   is valid before Grind runs. Add `following(point)` for each point whose
   settlements have a follower; without it a settlement is recorded and
   nothing is delivered. `with_name` names the store in its telemetry
   (`source`); `with_wake_attempts`, `with_settlement_attempts` and
   `with_snooze_limit` bound retries; `with_clock_offset` is for tests.
3. Build each desk over `decisions_postgres.port(store)`.
4. Put `wake_worker(store, [decisions.waker(desk), ..])`, with the waker of
   every point that has holds, validity or escalation steps, and
   `settlement_worker` with the follower of every followed point on Grind's
   configuration (`grind.with_worker`). Workers must be registered before
   Grind starts.
5. Start Grind in the application's supervision tree.
6. Run `sweep(store, db)`, so that every pending wake-up and every
   undelivered notice of a followed point has a job.
7. Run each verb in a transaction at `READ COMMITTED`, the PostgreSQL default
   (the port refuses another level with `Conflict`),
   or through `transaction`, `transaction_with` (a body that also fails with
   the application's own error), `decide`, or `refusing` (the same transaction
   in the shape of a verb, for `decisions_otp/isolated.recommend_when`'s
   `in:`). To admit a trigger, call `decisions.happened` and then
   `decisions.expect` in the transaction that receives it: `happened` takes
   the subject's lock, so two admissions about one subject run one after the
   other and the second supersedes the first's expectation. In the other
   order PostgreSQL detects the deadlock between two admissions and one ends
   `Contended`.

`test/wiring/postgres_wiring.gleam` holds this order as compiled code
(region `postgres-wiring`), and `wiring_test` runs it.

The tables are named without a schema and resolved through the connection's
`search_path`. An occurrence id (a `recommend_once` key) and a point name are
at most 255 bytes (`max_name_bytes`); a longer one is refused with
`Conflict`.

### Lock waits and pog's 5-second checkout

`pog.transaction` (pog 4.1) checks a connection out of the pool for at most 5
seconds and offers no other value: a transaction still open then loses its
connection, which reaches the caller as `Unavailable` (outcome unknown).
`transaction`, `transaction_with`, `decide`, `refusing` and the workers use
it. So that a long wait for a contended occurrence ends as `Contended`
(nothing written, safe to retry) instead, the port's `load` sets the
transaction's `lock_timeout` to 4 seconds before it locks
(`with_lock_timeout(store, Some(duration))` changes it, `None` leaves the
connection's own setting). It is set with `SET LOCAL` semantics, so it
applies to the rest of the caller's transaction too, and it overrides a
`lock_timeout` the caller set earlier in that transaction; pass `None` to keep
the caller's. A transaction that does more than wait can still reach the 5
second limit.

### Roles and grants

The append-only rule, the one-release index and the other constraints hold
against every role that does not own the tables; the owner can disable a
trigger or drop a constraint. Run the application as a role that does not own
them, with these grants (the suite runs verbs as such a role and checks that
it cannot rewrite or unprotect an entry):

```sql
GRANT SELECT, INSERT, UPDATE, DELETE
  ON decisions_occurrences, decisions_awaiting, decisions_wakes, decisions_settled
  TO app_role;
GRANT SELECT, INSERT ON decisions_entries TO app_role;
```

The functions `decisions_load`, `decisions_append`, `decisions_at` and
`decisions_ms` are executable by every role unless the schema's owner revoked
that from `PUBLIC`.

## What the database guarantees

| Guarantee                                                     | Mechanism                                                                                                                          |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Two deliveries of one trigger admit one occurrence            | `decisions_load` locks the head row, or takes an advisory lock on an id that has no row yet (the absence lock), then reads entries |
| A tool that writes and then refuses or raises leaves nothing  | `atomically` is a savepoint                                                                                                        |
| At most one release per occurrence                            | Unique index `decisions_entries_one_release`                                                                                       |
| Entries are never changed and follow each other without a gap | Trigger `decisions_entries_append_only`; foreign key `decisions_entries_no_gap`                                                    |
| One settlement notice per occurrence                          | Unique constraint `decisions_settled_once`                                                                                         |
| The store clock                                               | `clock_timestamp()` at the moment of the call, never `now()`, truncated to the millisecond                                         |

The port reports an integrity violation (SQLSTATE class 23) as `Conflict`, a
deadlock, a serialization failure or a lock wait that timed out as
`Contended`, and every other failure as `Unavailable`. `transaction` and
`decide` return `Refused(refusal)`, `RefusedUnrecorded(refusal, detail)` when
the second transaction that keeps a refused verdict on the record failed,
`Conflict`, `Contended` or `Unavailable`; in every case the transaction rolled
back.

## Delivery

One delivery is one transaction. A wake-up job acts only while its row in
`decisions_wakes` is pending, so a cancelled or delivered wake-up does nothing
when its job arrives; a wake-up that came early is snoozed to the time the
waker names. A settlement job runs the follower and marks the notice delivered
in one transaction, so the follower's database writes happen once per notice;
a follower is `#(point name, fn(connection, occurrence id) -> Result(Nil,
decisions.HandlerFailure))`. Every notice reaches it, including one for a
record that ended before it began; reading with `decisions.read_record` gives
the same `Begun` or `NotBegun` the OTP runtime hands its followers, while
`decisions.read` refuses a record not begun.

Both workers act on `decisions.handling(failure)` alone (a wake-up's
refusal as `DeskRefused`, a waker or follower that raises as an application
failure):

- `Redeliver` (a contended or unavailable store) snoozes the job for 2
  seconds, which uses no attempt. After `with_snooze_limit` such deliveries
  without an outcome (1 000 unless set; an early wake-up counts too) the
  wake-up or notice is set aside.
- `Backoff` (an application's own failure, a conflict, an unreadable policy,
  a failed consult, a tool that answered `Unsure`) is counted and retried
  after Grind's backoff (15 seconds doubling, unless the registered worker
  sets a retry policy); after the last attempt (`with_wake_attempts`,
  `with_settlement_attempts`, 20 each unless set) it is set aside.
- `SetAside` (an unreadable record, an unpublishable policy, undeclared
  facts, an output that does not encode, a key another point holds) sets it
  aside at once.
- `Drop` finishes the job.

Setting aside emits `telemetry.set_aside`; no job is dropped silently. An
early wake-up is snoozed by the time left on the store's clock. `sweep(store,
db)` gives a job to every pending wake-up and undelivered notice of a followed
point that has none (run it at start). `deliver_due` and `deliver_notices`
deliver what is due now through the same code paths, for tests with a clock
offset and for an operator; both are safe beside the workers.

### Abandoned deliveries

A delivery whose node dies, or that hangs past its lease, is replayed by Grind
up to 10 times. After that Grind holds the job uncertain and runs the
settlement each worker declares with `worker.with_settlement`. That is Grind's
word for deciding what becomes of an abandoned job; it is unrelated to a
decision's settlement and the settlement notice the `settlement_worker`
delivers. The declared settlement reads the job's row in Grind's transaction:

- Row no longer pending: the job ends succeeded, "nothing pending".
- Row pending, a cancellation of the job requested: the job ends failed and
  the row stays pending, for `sweep` to give a new job. The row, not the Grind
  job, is the authority: stop the work through the record (its desk, or
  `set_aside`), not by cancelling its Grind job.
- Row pending: the delivery is replayed, at most `authorized_replay_limit` (3)
  times per job. Delivery is idempotent, so this is safe.
- Past that bound: the row is set aside with the reason, in the same
  transaction, and the job ends failed with it. This one setting aside emits
  no `telemetry.set_aside`: the settlement may run more than once and keeps to
  database work. Grind reports the committed settlement as
  `[grind, job, resolved]` and keeps the reason on the job.

`sweep` leaves a job held uncertain whose settlement is still due, and gives a
new job to a row whose job is held uncertain with no settlement to come (left
for a person). `Swept.left_uncertain` lists those Grind jobs; resolve each in
Grind with any decision, since a replay finds its row taken.

## Upgrading to 0.3.0

- Take Grind 0.3 (`grind = ">= 0.3.0 and < 0.4.0"`) and Sinal 0.2.
- Apply Grind's schema version 15 before starting a node that runs the
  workers. It builds an index concurrently, so run `grind.migrate` outside a
  transaction, through a session-mode connection.
- Attach handlers on `decisions_postgres/telemetry` from a long-lived
  supervised process: Sinal 0.2 detaches a handler when the process that
  attached it exits.

The [migration guide](https://github.com/gleam-dream/decisions/blob/main/docs/MIGRATION.md)
gives each change with before and after code.

## Upgrading to 0.2.0

- Take Grind 0.2 (`grind = ">= 0.2.0 and < 0.3.0"`), whose workers may
  declare a settlement.
- Apply Grind's schema version 14 before running it, as Grind's own upgrade
  says: `grind.migrate` at deploy time, `grind.with_startup_migration`, or
  Grind's migration file for version 14 mirrored into the application's tool.
  This package's own tables do not change.
- `Swept` has a third field, `left_uncertain`.
- Jobs already held uncertain by lease expiry are marked by each Grind settler
  when it starts, so the declared settlement settles them too.

### Pending records

A record is `pending` when a trigger was expected (`decisions.expect`) or
only failed attempts are recorded. It is never in a validator's queue
(`page`, `page_at`); `queue.counts` reports it under `store.Pending`, and
`queue.pending(db, point:, limit:, after:)` lists the records still
expected, the oldest first, with the time each began (`arrived`). The port's
`waiting` returns pending, recommended, awaiting and held records, so a newer
event supersedes each of them.

## Live hints

`decisions_postgres/live` sends a `Change` for every committed append to the
processes subscribed to everything, a point, or an occurrence. "The two
adapters compared" below sets this beside `decisions_otp/live`.

- `subscribe` is acknowledged and returns the listener's process: monitor it
  to learn that the listener went away, then subscribe again.
- Hints are lost while the listener's connection is down. It checks its
  connection every 500 ms and opens a new one when the server closed it; it
  does not report the gap. A client that must not miss a change polls
  `queue.positions(db, ids)` for the occurrences it holds and reads again any
  whose last sequence number moved.
- Nothing bounds a subscriber's mailbox.

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

## The schema

| Object                                                                                                                               | Holds                                                                                                                                                                                                                        | Serves                                                                       |
| ------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `decisions_occurrences`                                                                                                              | The head of each occurrence: point, subject, status (check `decisions_occurrences_status`), the sets it waits in, who approved, who may not decide, due and arrival times, review flag, last sequence number, set-aside mark | `load`'s row lock; inspection                                                |
| `decisions_occurrences_waiting (point, subject_kind, subject_id, id) WHERE status IN ('pending', 'recommended', 'awaiting', 'held')` |                                                                                                                                                                                                                              | The port's `waiting`, in id order                                            |
| `decisions_occurrences_subject (subject_kind, subject_id, arrived DESC, id DESC)`                                                    |                                                                                                                                                                                                                              | `queue.about`                                                                |
| `decisions_occurrences_status (point, status)`                                                                                       |                                                                                                                                                                                                                              | `queue.counts`                                                               |
| `decisions_occurrences_review (point, arrived, id) WHERE review_pending`                                                             |                                                                                                                                                                                                                              | `queue.review_queue`                                                         |
| `decisions_occurrences_review_all (arrived, id) WHERE review_pending`                                                                |                                                                                                                                                                                                                              | `queue.review_queue_all`                                                     |
| `decisions_occurrences_point (point, id)`                                                                                            |                                                                                                                                                                                                                              | `queue.occurrences_of`                                                       |
| `decisions_occurrences_pending (point, arrived, id) WHERE status = 'pending'`                                                        |                                                                                                                                                                                                                              | `queue.pending`: the triggers still expected, oldest first                   |
| `decisions_occurrences_set_aside (set_aside_at, id) WHERE set_aside_at IS NOT NULL`                                                  |                                                                                                                                                                                                                              | `queue.set_aside`                                                            |
| `decisions_entries`                                                                                                                  | The append-only record: `(occurrence_id, seq)` primary key, `at`, `kind` (check `decisions_entries_kind`), the event's JSON text                                                                                             | `load`                                                                       |
| `decisions_entries_no_gap`                                                                                                           | Foreign key from entry `n` to entry `n - 1`                                                                                                                                                                                  | Refuses a gap                                                                |
| `decisions_entries_one_release`                                                                                                      | Unique index on released entries                                                                                                                                                                                             | Refuses a second release                                                     |
| `decisions_entries_append_only`                                                                                                      | Statement trigger                                                                                                                                                                                                            | Refuses `UPDATE`, `DELETE`, `TRUNCATE` of entries                            |
| `decisions_awaiting`                                                                                                                 | One row per decision set an occurrence waits in, with its due time (`infinity` when none), arrival and who may not decide it                                                                                                 |                                                                              |
| `decisions_awaiting_queue (set_name, due_order, arrived, occurrence_id)`                                                             |                                                                                                                                                                                                                              | `queue.page`                                                                 |
| `decisions_awaiting_point_queue (set_name, point, due_order, arrived, occurrence_id)`                                                |                                                                                                                                                                                                                              | `queue.page_at`                                                              |
| `decisions_wakes`                                                                                                                    | One row per pending wake-up; a delivered one is removed, a poisoned one set aside                                                                                                                                            | The wake-up worker; `decisions_wakes_pending` keeps one pending row per time |
| `decisions_settled`                                                                                                                  | One settlement notice per occurrence (`decisions_settled_once`), delivered or set aside                                                                                                                                      | The settlement worker                                                        |
| `decisions_settled_point (point, admitted_xid, id)`                                                                                  |                                                                                                                                                                                                                              | `queue.settled_since`                                                        |
| `decisions_load(id)`, `decisions_append(...)`                                                                                        | The port's two hot statements, one round trip each                                                                                                                                                                           |                                                                              |
| `decisions_at(ms)`, `decisions_ms(at)`                                                                                               | Time as Unix milliseconds on the wire                                                                                                                                                                                        | Every query                                                                  |

## Tests

From the repository root, in the dev shell:

```sh
nix develop path:/code/gleam-dream/decisions --no-update-lock-file --command bash scripts/test-postgres.sh
```

The script starts a throwaway PostgreSQL 16 cluster, sets
`DECISIONS_TEST_DATABASE_URL`, runs `gleam test` here and removes the cluster.
Plain `gleam test` fails without that URL.

The suite also runs the shared race and crash scenarios of
`decisions_otp/stress` (a dev-dependency) against PostgreSQL, through a
`Target` in `test/stress_target.gleam`. Production delivery of wake-ups and
settlement notices is Grind's (`wake_worker`, `settlement_worker`); the
`Backlog` in that test module, and its test-only trigger table, exist only so
that the shared scenarios can drive `decisions_otp/runtime` over these
tables. Where a scenario restarts the store, the target stops the
runtime and its pool and opens a new pool over the same schema; it does not
restart PostgreSQL. The scenarios at their default load:

```sh
nix develop path:/code/gleam-dream/decisions --no-update-lock-file --command bash scripts/test-postgres.sh stress
```

The scale run is the same script with one argument:

```sh
nix develop path:/code/gleam-dream/decisions --no-update-lock-file --command bash scripts/test-postgres.sh scale
```

## Numbers

From the scale run (`scripts/test-postgres.sh scale`) of 2026-11-16 on an Apple
M2 Max (12 cores, 32 GB) with a load average of 3 to 4, OTP 29 and PostgreSQL
16.15 on the same machine, in the script's throwaway cluster (`fsync` and
`synchronous_commit` off), with one pool of 24 connections shared by the
workers and Grind. The run is observational and gates nothing;
`docs/BENCHMARKS.md` keeps the full table.

| Load                                                                 | Result                                                      |
| -------------------------------------------------------------------- | ----------------------------------------------------------- |
| H1: 10 000 recommendations the policy proceeds, 1 / 4 / 16 processes | 1 548 / 4 402 / 7 152 per second                            |
| H1 at 16 processes without the savepoint                             | 10 074 per second                                           |
| H2: queue page of 50 from 10 000 waiting                             | median 0.42 ms, p95 0.85 ms                                 |
| H2: open and decide 10 000, 16 validators                            | 4 424 per second; median 3.58 ms, p95 4.18 ms               |
| H3: read an occurrence of 10 / 100 / 1 000 entries                   | median 0.34 / 1.0 / 7.67 ms                                 |
| H4: 1 000 waiting about one subject superseded                       | 392 ms, one transaction                                     |
| H5: 5 000 holds ending in one millisecond, released through Grind    | 5.8 s, 867 per second                                       |
| H6: read 10 000 records for replay, 1 / 16 processes                 | 2 084 / 435 ms                                              |
| NOTIFY, from the start of the appending transaction                  | median 0.36 ms; it arrives before the writer's call returns |

### Why admission at one connection is slower than the prototype

The prototype admitted 2 400 recommendations per second at one connection
(median 0.39 ms per call); this package admits about 1 550 (median 0.63 ms).
The scale run measures each suspected cost by removing it, from one process:

| Variant                                                    | Per second | Median per call |
| ---------------------------------------------------------- | ---------- | --------------- |
| As shipped, with Grind's consumers on the pool (H1)        | 1 548      | 0.63 ms         |
| As shipped, no Grind consumers on the pool                 | 1 565      | 0.62 ms         |
| and the node's clock instead of a query for the database's | 1 800      | 0.55 ms         |
| and no savepoint around the gated tool                     | 2 476      | 0.40 ms         |
| and no gap-check foreign key                               | 2 516      | 0.39 ms         |

- **The savepoint is the largest part** (about 0.15 ms a call, two round
  trips). It is part of the port's contract: a tool that writes and then
  refuses must leave nothing.
- **The store's clock is a query** (`clock_timestamp()`, median 0.06 ms on its
  own, about 0.07 ms a call in admission). The prototype read the node's
  clock, which the store contract no longer allows.
- **The gap-check foreign key** costs about 0.01 ms a call, within the noise.
- **Grind's consumers on the shared pool** cost nothing measurable.
- With all three removed a call takes 0.39 ms, the prototype's figure; in this
  capture nothing else remains to attribute.
