#import "../.render/designlib.typ": *

#let title = [Runtime]
#let accent = "amber"
#let body = [
#section(title: "Foundation", lead: "The runtime context owns the processes around the record and how they deliver what the record says is owed.", body: [
  #goal(title: "Everything around an occurrence can be killed at any instant")[Each process reads its work from rows and acts in the transaction that removes it, so a replacement carries on from the store and recovery needs no code of its own.]
  #no-goal(title: "A process per occurrence")[An occurrence can wait for days and its truth is its record. A process holding it would be a second copy that must forget what the store undid; #adr(2) records the measurement.]
  #invariant(title: "A job leaves its queue only in the transaction that acts on it", enforcement: "mechanism")[A wake-up is taken, a notice marked delivered and a trigger finished inside the transaction that runs the verb or the follower, so a kill before the commit leaves the job for the next delivery.]
  #invariant(title: "A delivered job that finds nothing to do does nothing", enforcement: "mechanism")[`wake` writes nothing when nothing is due, `recommend_once` finds the occurrence it made, and a notice already delivered is skipped. At-least-once delivery is therefore enough everywhere.]
  #invariant(title: "A model call cannot take its caller down or outstay its deadline", enforcement: "mechanism")[An isolated call runs the model in a process of its own; a raise becomes `Raised` and a model still running at the deadline is killed and becomes `Deadline`.]
  #principle(title: "Observations never control delivery")[A hint and a telemetry event are emitted after the transaction they describe. Missing one loses nothing, because the record is read again.]
])

#pending-ledger(
  pending-entry(title: "A true stop and start of the OTP runtime", kind: "ruling", since: "2026-11-15")[
    `runtime.pause` stops delivery while the runtime's processes stay up; stopping and starting the runtime is left to the application's own supervisor through `supervisor_of`. A stop and start owned by the runtime was declined in this build. Whether one is needed is open.
  ],
  pending-entry(title: "A model built inside its isolated process", kind: "build", since: "2026-11-20", adr: [#adr(57)])[
    `isolated.model` copies the application's model, and every heap term its function captures (a binary larger than 64 bytes is shared by reference), into a new process for each call, and `replay.replay` into one for each share. Until a model can be built inside that process, consumers keep a model small. Tracker issue 31 of `issues/first-applications-findings`.
  ],
)

#section(title: "Processes around the record", lead: "None of these processes keeps state; each can be killed and its replacement carries on from rows.", visual: diagram(
  altitude: "L2", viewpoint: "runtime", title: "The processes and what each owns",
  nodes: (
    (id: "store", label: "Store", sub: "record, wake-ups, notices, triggers", kind: "database", tint: "teal"),
    (id: "sweeper", label: "Sweeper", sub: "due wake-ups", kind: "service", tint: "amber"),
    (id: "dispatcher", label: "Dispatcher", sub: "settlement notices", kind: "service", tint: "amber"),
    (id: "workers", label: "Workers", sub: "one trigger each", kind: "service", tint: "amber"),
    (id: "model", label: "Isolated call", sub: "one model, one deadline", kind: "component", tint: "amber"),
    (id: "subs", label: "Subscribers", sub: "open cards, queues", kind: "frontend", tint: "amber"),
    (id: "follower", label: "Follower", sub: "application", kind: "external-system", tint: "slate"),
  ), edges: (
    (from: "sweeper", to: "store", relation: "call", label: "take due; wake in one transaction"),
    (from: "dispatcher", to: "store", relation: "call", label: "deliver notice in one transaction"),
    (from: "dispatcher", to: "follower", relation: "call", label: "run in that transaction"),
    (from: "workers", to: "model", relation: "call", label: "run outside a transaction"),
    (from: "workers", to: "store", relation: "call", label: "recommend_once or record_failure"),
    (from: "store", to: "subs", relation: "pubsub", label: "hint after commit"),
  ), caption: [In the OTP runtime these are children of one supervisor over the backlog. In PostgreSQL the sweeper and the dispatcher are Grind workers and the hints come from `NOTIFY`.],
), body: [
  #points(
    [Three rules make every kill harmless, and none is about processes: admission is idempotent by key; a job leaves the queue in the transaction that acts on it; a wake-up that finds nothing due does nothing.],
    [What only the BEAM gives, and the runtime uses: a model call that cannot take its caller down; replay spread over every core; hints without polling; supervision with no recovery code; and a rollback when a process dies inside a transaction.],
  )
])

#section(title: "The supervised runtime", lead: "One supervisor, one sweeper, one dispatcher and a bounded number of workers over a backlog.", body: [
  #md-table(5, (
    [*Process*], [*Owns*], [*Keeps in memory*], [*Killed: what is lost*], [*Restarted by*],
    [Sweeper], [Delivering due wake-ups, and again at `until` one that arrived early], [The batch in hand], [Nothing: a wake-up leaves the backlog in the transaction that acts on it], [The runtime's supervisor],
    [Dispatcher], [Delivering each settlement to its point's follower], [The batch in hand], [Nothing: a notice is marked delivered in the transaction that runs the follower], [The runtime's supervisor],
    [Worker, `workers` of them], [Turning one trigger at a time into a recommendation], [The trigger in hand], [Nothing: the claim dies with the worker and another takes the trigger], [The runtime's supervisor],
  ))
  #points(
    [`runtime.config(backlog, points:, work:)` requires every handler: a `runtime.point(desk, settled:)` per point, whose follower runs in the transaction that marks the notice delivered, is handed the settled record as `decisions.read_record` returns it when the notice is delivered (`Begun(occurrence)`, or `NotBegun(pending)` for a record superseded or lapsed before it began, whose outcome is final), and returns `Result(Nil, decisions.HandlerFailure)` (`runtime.nothing_follows` when nothing does), and `work`, which turns a submitted trigger into a recommendation outside any transaction and ends with `recommend_once` under the trigger's key. A trigger is worked once even when several workers look at it. Every notice reaches the follower in both runtimes (#adr(55)). Defaults: four workers, a poll of 100 ms, a batch of 100, 20 attempts, the name `"decisions_otp"`, a restart tolerance of 100 in 5 seconds, and no control.],
    [In an application's tree, `supervised(config)` is a child specification and `supervised_from(configure)` configures the runtime at every start, from the current handle of a store started by the same tree (`store.supervised`), under a `RestForOne` supervisor with the store first. A `Control` made once with `new_control` lets the application `pause` and `resume` delivery, ask `is_paused`, and find the supervisor and children by name (`supervisor_of`, `children_of`). A paused runtime's children finish the job in hand and then wait; its processes stay up. `Config.name` names the runtime in its telemetry (`source`).],
    [The strategy is one-for-one. No child holds state another needs. The supervisor allows 100 restarts in 5 seconds, so a child killed now and then is restarted at once and a child that crashes on every start, such as one over a stopped store, takes the runtime down to the application's supervisor.],
    [Each child's mailbox holds at most one message, its next look, and each look reads at most `batch` jobs. The backlog is the queue; nothing else is queued in memory.],
    [A delivery that does not commit is rolled back, and what happens to its job is the handling rule below, the same in both runtimes. In the OTP runtime a refusal of a verb the runtime calls itself is handled as `DeskRefused`, a handler that raises as `ApplicationFailed`, and a backlog call or a commit that fails, or a commit whose outcome is unknown, as `Redeliver`: nothing says the handler failed, so it is not counted. A `Redeliver` job is left out of the child's next look, so the jobs behind it go on, and delivered again two looks later; `[decisions, job, failed]` reports it with zero attempts. `Drop` is reported by `[decisions, job, dropped]`. A `Backoff` job waits the store's `retry_backoff`, doubled after each failure, and after `attempts` failures it is set aside.],
    [A job set aside leaves its queue, stays readable through the backlog's `aside`, and is reported by `[decisions, job, set_aside]`; the jobs behind it go on. A job for a point the runtime was not given is set aside at once. A look that met only transient failures waits `poll` before the next.],
    [Delivery is at least once. A kill between the commit and the next look can deliver a job again; a follower is safe to run twice when it writes only in the transaction it is handed.],
  )
  #answers(title: "Backlog", responsibility: [Hold the runtime's work as rows any store can implement.], interface: [`transaction`, `now`, `due`, `take_wake`, `add_wake`, `undelivered`, `deliver_notice`, `submit`, `claim_trigger`, `finish_trigger`, `release`, `failed`, `set_aside`, `aside`.], interactions: [`decisions_otp/store.backlog` implements it over the OTP store; the runtime and the stress suite run unchanged over any other implementation.], invariants: [`take_wake`, `deliver_notice`, `finish_trigger`, `failed` and `set_aside` lock the job they act on; the first three run in the acting transaction and return `False` when another delivery took the job, and taking a wake-up locks its occurrence. A trigger claim dies with the process that holds it, and `release` gives it up only after the transaction that decided the trigger's fate has ended. Reads outside a transaction see only committed rows.], failure: [`failed` counts an attempt in a transaction of its own; a set-aside job leaves its queue and stays readable through `aside`.])
])

#section(title: "Handler failures", lead: "One classification decides what becomes of a job whose delivery did not commit, in both runtimes.", body: [
  #points([A follower and a job handler return `decisions.HandlerFailure`: `DeskRefused(refusal)` when a verb of a desk refused, `ApplicationFailed(reason)` when the application's own work failed. A handler that raises is an application failure in both runtimes. `decisions.handling(failure)` turns it into a `Handling`, and the OTP runtime and the PostgreSQL workers act on that value alone (#adr(35), #adr(39)). Both allow 20 counted attempts by default.])
  #md-table(3, (
    [*Handling*], [*Given for*], [*What the runtime does*],
    [`Redeliver`], [A desk refusal with disposition `Transient`: a contended or unavailable store], [Delivers the job again soon, not counted],
    [`Backoff`], [`ApplicationFailed` or a raise; a desk refusal with disposition `Retry`: `StoreFailed(Conflict)`, `NoPolicy`, `ConsultFailed`, `ToolUnsure`], [Delivers the job again after a backoff, counted; when the attempts are used, sets it aside],
    [`SetAside`], [A desk refusal with disposition `Poisoned`: `Unreadable`, `Unpublishable`, `InvalidFacts`, `Unencodable`, `KeyTaken`], [Sets the job aside at once for an operator],
    [`Drop`], [A desk refusal with disposition `Final`: the occurrence moved on or the job can never apply], [Treats the job as done],
  ))
  #points([A job for a point the runtime was not given, and a notice no follower serves, are set aside at once. The timing of each runtime is in "The two adapters compared".])
])

#section(title: "The two adapters compared", lead: "The two packages share the classification; their timing, live notifications, setting aside and paging differ.", body: [
  #md-table(3, (
    [*Concern*], [*`decisions_otp`*], [*`decisions_postgres`*],
    [Classification], [`decisions.handling`, 20 attempts by default], [`decisions.handling`, 20 attempts by default],
    [`Redeliver`], [Delivered again two looks later (about two `poll`s), not counted; the jobs behind it go on], [Snoozed for 2 seconds, which uses no attempt; set aside after `with_snooze_limit` snoozes (1 000 unless set)],
    [`Backoff`], [Waits `store.Config.retry_backoff`, doubled after each failure, at most 64 times], [Retried after Grind's backoff (15 seconds doubling, unless the registered worker sets a retry policy)],
    [Live notifications], [Topics for one occurrence, one point, one decision set's queue and one point's review queue; a subscriber that falls behind is sent `Missed(count)`], [Everything, one point, or one occurrence; no `Missed`; `subscribe` is acknowledged and returns the listener's process to monitor],
    [Setting aside], [Acts on a job of the backlog (a wake-up, a notice or a trigger)], [`set_aside` acts on an occurrence; the workers set aside a wake-up row or a notice row],
    [`occurrences_of`], [Commit order], [Id order],
    [`settled_since`], [Commit order], [Order of the admitting transactions, never passing one still running],
    [Restart], [In the VM only: `restart` keeps every acknowledged commit; a stopped owner loses everything], [Durable in the database],
  ))
])

#section(title: "Delivery over PostgreSQL", lead: "Grind jobs admitted in the caller's transaction deliver wake-ups and notices; a row says whether a job still has work.", visual: sequence(
  title: "A wake-up job finds its row, wakes, and removes the row", participants: (
    (id: "verb", label: "Verb", shape: "control"),
    (id: "db", label: "PostgreSQL", shape: "database"),
    (id: "grind", label: "Grind", shape: "queue"),
    (id: "worker", label: "Wake worker", shape: "control"),
  ), steps: (
    seq-msg("verb", "db", "schedule: insert wake row, submit job at its time"),
    seq-note("db", "the row and the job commit with the verb, or neither does"),
    seq-msg("grind", "worker", "deliver the job"),
    seq-msg("worker", "db", "is the row still pending?"),
    seq-alt("pending", (
      seq-msg("worker", "db", "waker(occurrence); remove the row"),
    ), otherwise: (
      seq-note("worker", "row gone: do nothing", side: "left"),
    )),
    seq-opt("came early", (
      seq-msg("worker", "grind", "snooze until"),
    )),
  ), caption: [Grind cannot cancel a job, so a decided occurrence leaves jobs whose rows are gone; they do nothing when they arrive.],
), body: [
  #points(
    [Start-up order: run `migrate`; build the store and the desks over its port; put the workers on Grind's configuration, since workers must be registered before Grind starts; start Grind in the application's tree; then run `sweep`. The compiled wiring example and its test follow this order.],
    [`wake_worker(store, wakers)` takes the waker of every point that has holds, validity or steps. One delivery is one transaction: when the wake-up's row is no longer pending nothing happens; otherwise the point's waker runs, and the row is removed when it is done or kept and the job snoozed to `until` when it came early. A job whose lease expires is replayed up to 10 times; after that it is an abandoned delivery, below.],
    [A waker's refusal and a waker that raises follow the handling rule like a follower's failure: `Redeliver` snoozes the job without an attempt, and after `with_snooze_limit` snoozes without an outcome, an early wake-up counting too, the wake-up is set aside and reported; `Backoff` is counted toward `with_wake_attempts` (20 unless set). No job is dropped silently. A wake-up for a point with no waker is set aside.],
    [`settlement_worker` delivers notices of the points named with `following`. A follower is `#(point name, fn(connection, occurrence id) -> Result(Nil, decisions.HandlerFailure))`. Every notice reaches it, including one for a record that ended before it began; `decisions.read_record` reads it as the OTP runtime hands it over (#adr(55)). One delivery locks the notice's row, runs the follower and marks the notice delivered in one transaction, so the follower's database writes happen once per notice. An effect outside the database may happen more than once and must be keyed by the occurrence id.],
    [A follower's failure follows the handling rule, counted toward `with_settlement_attempts` (20 unless set). An early wake-up is snoozed by the time left on the store's clock. Each set-aside emits the `set_aside` event, and every event carries `source`, the store's name (`with_name`).],
    [Without `following(point)`, a settlement is recorded in `decisions_settled` and nothing is delivered.],
    [An abandoned delivery is a wake-up or notice job whose node died or which outlived its lease once its replays are used up; Grind holds it uncertain. Each worker declares through Grind what becomes of it (Grind calls this a settlement, which is not a decision's settlement or its notice). The rule reads only the job's row, writes only to the database, and treats the row, not the job, as the authority on whether work remains: a row no longer pending ends the job succeeded; a pending row is delivered again, since delivery is idempotent, at most three times per job; past that bound the row is set aside in the same transaction and the job ends failed with the reason; a requested cancellation, under which Grind refuses a replay, ends the job failed and leaves the row pending for the sweep (#adr(56)).],
    [`sweep(store, db)` admits a job for every pending wake-up and every undelivered notice of a followed point whose job will not deliver it: none was admitted or kept, it ended, or it is held uncertain with no settlement to come. A job held uncertain whose settlement is still due is left to that settlement, and a job left uncertain for a person is replaced and reported, so a pending row is never left without delivery (#adr(45), #adr(56)). A failure to read a job is an error of the sweep, never a row taken for one without a job. `deliver_notices` delivers the notices due now through the settlement worker's code path. `deliver_due(store, db, wakers, limit:)` delivers now, through the worker's own code path, every pending wake-up that is due on the store's clock, the earliest first, and returns how many it delivered. It is for tests that use `with_clock_offset`, whose Grind jobs are scheduled on the database's clock, and for an operator. It is safe beside the worker: the job that arrives later finds the row gone.],
  )
])

#section(title: "Isolated model calls", lead: "A worker runs its model in a process of its own, then recommends or records the failure.", body: [
  #points(
    [`isolated.model(inner, within:)` returns a model that runs `inner` in a new process. A raise becomes `Raised`; a model that has not answered by the deadline is killed and becomes `Deadline(within)`. The caller never waits longer than the deadline and the time to kill. The model's process is not linked to the caller, so its death never takes the caller down, and a watcher kills it when the caller exits, so a worker killed while its model hangs leaves no model running. The reads it received cross back to the caller and are on the recommendation.],
    [`isolated.recommend(desk, in:, request:, model:)` is the whole step a worker takes for a trigger: run the model outside any transaction, then in one transaction either `recommend_once` under the request's key, returning `Recommended(occurrence)`, or `record_failure`, returning `Failed(failure, attempts)` with every attempt so far. When a newer event superseded an expected key first, both are refused and the result is `Superseded(event)`: the trigger is done. When the key's own deadline passed first, `record_failure` is refused and the result is `Lapsed(deadline)`; a late recommendation is recorded and the result is `Recommended(occurrence)` with the occurrence expired (#adr(54)). A deadline or a raise is reported as `[decisions, model, failed]`. Safe to repeat. With PostgreSQL, `decisions_postgres.refusing(db, _)` is the `in:`.],
    [`isolated.recommend_when(.., holds:)` adds a precondition checked inside the recommending transaction, after the model answered and before anything is written. The precondition answers `Ok(Nil)` or an `Unmet`: `Skip(reason)` when it was checked and says to skip the trigger for good, and the result is `Skipped(reason)`; `CouldNotCheck(error)` when the store failed, and the result is `Error(StoreFailed(error))`, retried as its disposition says. For a key that was expected first, `decisions.expect` already closes the superseding window; the precondition is for any other check that must commit with the recommendation.],
  )
])

#section(title: "Replay across processes", lead: "A replay is a pure function of each example, so it spreads over every core.", body: [
  #points(
    [`replay.replay(examples, candidate, same:, across:)` runs `learning.replay_one` over at most `across` processes and merges the results in order. The tally and the unanswered examples equal those of `learning.replay`.],
    [`replay.map(items, across, work)` is the bounded map underneath. It keeps the order of its input and reports a process that died as an `Error` in its place.],
  )
])

#section(title: "Live hints", lead: "A process holding a card or a queue is told after a commit that something it watches changed.", body: [
  #points(
    [In the OTP store, `store.subscribe(s, to: topic, hints:)` returns a `Result` (an `OwnerError` when the owner is stopped or does not answer in time) and registers a subject for an occurrence, a point, a queue or a point's review queue (`ToOccurrence`, `ToPoint`, `ToQueue`, `ToReviews`). A hint is sent after a commit and never for a transaction that rolled back. A subscriber that falls behind gets `Missed(count)` before its next hint, or by itself as soon as its mailbox has room again when no further change comes, so it reads everything it watches again; a subscriber that exits is forgotten.],
    [In PostgreSQL every append sends `NOTIFY` on `decisions_changed` inside the appending transaction, so it arrives only on commit. `decisions_postgres/live` runs one listener with a connection of its own, outside the pool, that forwards notifications to subscribers of `Everything`, a `Point` or an `Occurrence`. `subscribe` is acknowledged and returns the listener's process: a subscriber monitors it to learn that the listener went away, then subscribes again. A notification is lost while the listener's connection is down and when the listener restarts; the listener checks its connection every 500 ms, opens a new one when the server closed it, and does not report the gap. Nothing bounds a subscriber's mailbox. The subscriber's contract is therefore: listen, and poll `queue.positions(db, ids)` for the occurrences it holds, reading again any whose last sequence number moved.],
  )
  #behavior(title: "A validator holding a card learns that someone else decided", area: "Live", level: "interface")[
    #given[Two validators have the same card open.]
    #when[One of them decides and the transaction commits.]
    #then[The other is told the card changed and, reading again, sees the outcome.]
    #then[When the notice is missed, reading the card again still shows the outcome.]
  ]
])

#section(title: "Telemetry", lead: "Sinal events describe deliveries after they committed or rolled back; no verb of the core emits anything.", body: [
  #md-table(2, (
    [*Package*], [*Events*],
    [`decisions_otp/telemetry`], [`settlement_delivered`, `trigger_worked`, `wake_delivered` with its outcome, `job_failed`, `job_dropped` for a job removed as done, `job_set_aside`, `model_failed` for a deadline or a raise. Every record carries `source` (the runtime's `Config.name` or the request's source), the point, the occurrence (the trigger's key for a trigger) and a correlation derived from the occurrence id; durations are in microseconds.],
    [`decisions_postgres/telemetry`], [`wake_delivered`, `wake_rescheduled`, `settlement_delivered`, `set_aside` for a wake-up, a notice or an occurrence; every record carries `source`, the store's name (`with_name`).],
  ))
  #points([A handler runs synchronously in the emitting process unless the application routes the prefix to a Sinal forwarder; a slow handler slows a delivery process, never a verb, and never holds a lock.], [Neither package attaches a handler. Sinal binds a handler to the process that attached it and detaches it when that process exits, so an application attaches a handler that must outlive a call from a long-lived supervised process.])
])

#section(title: "The stress suite", lead: "The port's clauses that need several processes, and the race and crash conditions, written once against any store.", body: [
  #md-table(2, (
    [*Scenario*], [*What it shows*],
    [A1], [Forty verdicts, eight wake-ups and a superseding event on one occurrence: one verdict stands, the tool runs at most once, every loser gets a typed refusal.],
    [A2], [Sixteen validators drain a queue: each occurrence is decided once and nobody blocks.],
    [A3], [A withdrawal, a wake-up and the clock passing the hold race: each trial ends withdrawn with no send or released with one, and both endings occur.],
    [A4], [A random walk of eight processes over fifty occurrences keeps every invariant, and every earlier record is a prefix of the later.],
    [One key], [Concurrent `recommend_once` on one key: one occurrence, one effect.],
    [Clauses], [A load of an absent or present id waits; uncommitted writes, wake-ups and notices are invisible; a process killed inside a transaction or a savepoint leaves nothing and releases its lock; concurrent `happened` and `decide` do not deadlock; wake-ups and notices survive a restart; `now` moves inside an open transaction; `schedule` leaves a delivered wake-up alone.],
    [Held superseded], [A held occurrence whose hold has ended, raced by its wake-up and a superseding event: each trial ends released once or superseded with nothing released.],
    [Expect], [A key expected with `decisions.expect`, raced by a slow model's recommendation and a superseding event: no occurrence for the older trigger is left waiting or released.],
    [Concurrent admissions], [Eight transactions about one subject, each `happened` then `expect` of its own key, all open before any commits: the subject lock orders them, so exactly one key is left pending, every other key was superseded before it began, and the lock's id holds nothing.],
    [B1], [A worker killed during the model, and after the commit before acknowledging: one occurrence per trigger.],
    [B2], [A process killed inside the verdict after the tool wrote: no write, the occurrence still waits, a second verdict succeeds once.],
    [B4], [The runtime killed with holds pending and started again after they ended: each released once.],
    [B5], [A random runtime child killed every 50 ms while occurrences move; the triggers arrive in waves paced by the kills, so at least five children die while work is in flight: all settle.],
    [B6], [A record that no longer decodes is set aside at once; a follower and a trigger that always fail are set aside after three attempts; the jobs behind them are delivered.],
    [B7], [A model that raises and one that hangs: a typed failure within the deadline, on the record.],
    [Own deadline], [Four keys expected with one deadline of their own, the store restarted before it: each expires once at the deadline, a late recommendation is recorded expired, a late failure and a late verdict are refused.],
    [Every notice], [Records that ended before they began (superseded, lapsed at their own deadline), lapsed records recommended late before and after their wake-up, and one rejected: the runtime hands each settlement notice to the point's follower exactly once, none dropped or set aside.],
  ))
  #points(
    [A race starts every process at a gate and releases them in shuffled order. A crash is `process.kill` at a named kill point. Every scenario ends with the invariant check over the points it used.],
    [A store runs the suite by building a `stress.Target` and calling `stress.run(target, load)`; `default_load` and `light_load` fix the sizes. All twenty-five scenarios run against the OTP store and against PostgreSQL, each as one test there, at the light load in `gleam test` and at the default load on request (#adr(26)). The PostgreSQL target drives `decisions_otp/runtime` over its own tables through a test-only backlog; production delivery there remains Grind's. Where a scenario restarts the store, the PostgreSQL target stops the runtime and its pool and opens a new pool over the same schema; it does not restart the server. In the OTP store the restart scenario commits while the restart is in flight, and the invisibility scenario checks that a commit appears whole.],
    [`decisions_otp/scale` writes the workloads of condition H and use case 12 once against the same target: H1 to H6 and moderation at volume. Each asserts that the work was done as well as timing it. The results and their limits are in `docs/BENCHMARKS.md`.],
  )
])

]
