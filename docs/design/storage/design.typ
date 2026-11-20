#import "../.render/designlib.typ": *

#let title = [Storage]
#let accent = "teal"
#let body = [
#section(title: "Foundation", lead: "The storage context owns what a store must guarantee so that the record's invariants hold under real concurrency.", body: [
  #goal(title: "Any store that meets the port's contract keeps every invariant")[A store implements eight functions once. The desk relies on nothing else, and an executable suite states each clause one process can check.]
  #invariant(title: "Two deliveries of one trigger cannot both admit it", enforcement: "mechanism")[`load` locks the id for the rest of the transaction even when no entry exists, so a second transaction that loads the same id waits and then sees what the first stored.]
  #invariant(title: "A tool that writes and then refuses leaves nothing", enforcement: "mechanism")[`atomically` runs the guard and the executor in a savepoint; when the body returns an error or raises, its writes are undone and the transaction stays usable.]
  #invariant(title: "Queues never parse an entry", enforcement: "mechanism")[The head carries the status, the sets waited in, the due time, the arrival time and who has approved, so every queue and superseding query reads heads alone.]
  #principle(title: "The port is a contract, not an option of one adapter")[The absence lock, the savepoint and the rich head are required of every adapter. #adr(5) records why the core cannot provide them alone.]
])

#pending-ledger(
  pending-entry(title: "Whether schedule and settled fold into the head", kind: "ruling", since: "2026-11-15", adr: [#adr(19)])[
    `schedule` and `settled` are port functions beside `append`. A reviewer proposed deriving pending wake-ups and the settlement notice from the head an append writes, which would shrink the port to six functions. The port keeps eight until the owner decides.
  ],
  pending-entry(title: "Setting a record aside cannot be undone", kind: "ruling", since: "2026-11-15")[
    An adapter sets aside a record that no longer decodes, with its wake-ups and notice, so it blocks nothing. No operation brings it back once its codec is fixed; whether one is needed, and what it must check, is open.
  ],
)

#section(title: "The port at a glance", lead: "The desk calls the port in the caller's transaction; each adapter implements it for one store.", visual: diagram(
  altitude: "L2", viewpoint: "persistence", title: "The port and its adapters",
  nodes: (
    (id: "desk", label: "Desk", sub: "record context", kind: "component", tint: "violet"),
    (id: "port", label: "Storage port", sub: "eight functions", kind: "component", tint: "teal"),
    (id: "mem", label: "Memory store", sub: "decisions/memory", kind: "database", tint: "teal"),
    (id: "otp", label: "OTP store", sub: "decisions_otp/store", kind: "database", tint: "teal"),
    (id: "pg", label: "PostgreSQL adapter", sub: "decisions_postgres", kind: "database", tint: "teal"),
    (id: "suite", label: "Conformance suite", sub: "twenty-two checks", kind: "component", tint: "teal"),
  ), edges: (
    (from: "desk", to: "port", relation: "call", label: "load, append, schedule, settled, ..."),
    (from: "mem", to: "port", relation: "dependency", label: "implements"),
    (from: "otp", to: "port", relation: "dependency", label: "implements"),
    (from: "pg", to: "port", relation: "dependency", label: "implements"),
    (from: "suite", to: "port", relation: "call", label: "checks each clause"),
  ), caption: [The desk never reads an inspection; only the conformance suite and the invariant check do. The transaction type `tx` is the adapter's own.],
), body: [
  #entity(id: "head", title: "Head", description: [What a store keeps beside an occurrence's entries. The desk derives it with `occurrence.head` and writes it with every append.], kind: "value-object", owner: "decisions desk", lifecycle: "stateful", domain: "storage", tint: "teal")[
    #attribute(name: "Point and subject", type: "Name and subject", provenance: "derived")[What superseding filters on.]
    #attribute(name: "Status", type: "Pending or one of the nine statuses", provenance: "derived")[Stored by `store.status_name`; `pending` while the record has not begun: it holds an expectation or only failed attempts.]
    #attribute(name: "Awaiting", type: "Decision sets", provenance: "derived")[The queues the occurrence waits in; empty unless it awaits.]
    #attribute(name: "Due", type: "Optional time", provenance: "derived")[The effective deadline while it waits, the hold's end while it is held, the occurrence's own deadline while it has not begun (#adr(54)). The conformance suite checks that a pending head keeps it and that a record not begun can hold a wake-up.]
    #attribute(name: "Arrived", type: "Time", provenance: "derived")[The recommendation's time, or the first attempt's when there is none.]
    #attribute(name: "Approved", type: "Validators", provenance: "derived")[Who approved the standing output, so a queue leaves the card out for them.]
    #attribute(name: "May not decide", type: "Validators", provenance: "derived")[Who may not decide the occurrence whatever sets they hold: under `SomeoneElseHolding`, the requester and a person who recommended as their own act; under `Several`, whoever already approved the standing output; under `Either`, only who every alternative excludes. Empty unless it awaits. A queue leaves the card out for them (#adr(23)).]
    #attribute(name: "Review pending", type: "Flag", provenance: "derived")[Sampled, released and not yet reviewed.]
  ]
  #points([A stored entry is `Stored(seq, at, kind, event)`: the kind name as a column so the store can hold "at most one `released` per occurrence" behind a unique key, and the event as JSON text that only the point's codec decodes. `entry.to_stored` and `entry.from_stored` are the only translation, so an adapter never parses an entry.])
])

#section(title: "The contract, clause by clause", lead: "Each clause exists because a guarantee rests on the store and the core cannot provide it alone.", body: [
  #md-table(3, (
    [*Clause*], [*Statement*], [*Checked by*],
    [`load`], [Returns the entries in sequence order and locks the id for the rest of the transaction, also when no entry exists; empty when there is none. `happened` also loads a subject-lock id this way, purely as a lock; no entry is ever stored under it, so no port function was added for it.], [Conformance: an absent id loads empty and takes its first entry once. Several processes: a second transaction that loads an absent or a present id waits for the first.],
    [`append`], [Adds entries after the last one and replaces the head in one write. The first entry has number 1 and each next one the next number. Refuses with `Conflict` a number it holds, a gap, and a second `released` entry. Never changes or removes an entry.], [Conformance: entries come back in order and byte for byte; a repeated number, a gap and a second release are refused; the head comes back as written.],
    [`waiting`], [Returns the ids of a point's records about a subject whose head status is pending, recommended, awaiting or held (`store.is_waiting`): the records a superseding event can still end. In ascending id order. An adapter may leave out an occurrence it has set aside as poison, so one bad record does not stop a supersession.], [Conformance: filters by point, subject and every status, in id order.],
    [`schedule`], [Replaces every pending wake-up of an occurrence with one at each given time; an empty list cancels them. A wake-up already delivered is not affected.], [Conformance: replaced and cancelled; the desk's hold, deadline and step wake-ups and their cancellation. Several processes: a wake-up a delivery already took is left alone.],
    [`settled`], [Admits one durable notice that an occurrence of a point settled.], [Conformance: notices admitted in order; the desk keeps I6.],
    [`atomically`], [Runs a body in a savepoint. On `Error` its writes are undone and the transaction stays usable; on `Ok` they stay. The outer result is the savepoint's own failure.], [Conformance: rolls back alone, keeps what succeeded, rolls back alone when the body raises, and its writes go with a transaction that rolls back.],
    [`now`], [The wall clock at the moment of the call, at any resolution, not the start of the transaction: in PostgreSQL `clock_timestamp()`. The desk reduces it to whole milliseconds.], [Several processes only: one process cannot tell a frozen clock from a moving one. The suite assumes nothing about two reads.],
    [`new_id`], [A new, unique occurrence id.], [Conformance: new ids are unique.],
    [Transactions], [Uncommitted writes, wake-ups and notices are invisible to other transactions; a rolled-back transaction leaves nothing; a process killed inside a transaction or a savepoint leaves nothing and releases its locks.], [Conformance: a rolled-back transaction leaves nothing. Several processes: invisibility and kills.],
    [Locks], [Concurrent `happened` and `decide` do not deadlock, because `waiting` returns ids in one order.], [Several processes.],
    [Durability], [Wake-ups and notices survive a store restart.], [Several processes.],
  ))
  #points(
    [`StoreError` has three variants (#adr(22)). `Conflict(detail)` is a write that breaks the contract: running the transaction again from the start reloads the record and is safe, and a conflict that repeats points at a second writer that does not take the lock. `Contended(detail)` is a deadlock or a lock wait that timed out: nothing was written and running again is safe. `Unavailable(detail)` means the outcome is unknown, such as a lost connection or a failure in the reply to the commit: read the record before running again. The desk turns each into the refusal `StoreFailed`, whose disposition is `Retry`.],
    [The port offers no way to take, acknowledge or postpone a wake-up or a notice. It only records what is pending; delivery belongs to the runtime that drives the desk (#ctx("runtime")).],
    [The desk calls `now` after `load` in every verb and never stores an entry earlier than the one before it, so a verb that waited for the lock is stamped with when it ran.],
  )
])

#section(title: "Conformance and the invariant check", lead: "The contract is executable: twenty-two checks for one process, and a stress suite for the clauses that need several.", body: [
  #answers(title: "Conformance suite", responsibility: [Show that an adapter meets each clause one process can observe.], interface: [`conformance.run(fresh)` with `fresh` returning an `Adapter(port:, inspect:, handle:, transaction:, cleanup:)`; `conformance.checks()` lists the twenty-two named checks; failures are `Unmet`: `SetupFailed(reason)` or `CheckFailed(check, saw)`.], interactions: [Each check gets a fresh adapter; `handle` works outside a transaction with each call committing by itself. Three checks drive a real desk over the adapter: every invariant holds, a refused release leaves nothing, and an early wake-up says when to come back.], invariants: [The core's own tests break an in-memory adapter in each clause in turn and show that the check naming it fails.], failure: [Every failing check is reported with what it saw; the suite does not stop at the first.])
  #md-table(2, (
    [*Check*], [*Clause*],
    [an absent id loads empty; an absent id takes its first entry once], [`load`],
    [entries come back in order and unchanged; a repeated sequence number, a gap and a second release are refused; the head comes back as written], [`append`],
    [a rolled-back transaction leaves nothing], [transactions],
    [a savepoint rolls back alone; keeps what succeeded; rolls back alone when its body raises; leaves nothing inside a rolled-back transaction], [`atomically`],
    [waiting filters by point, subject and status, in id order], [`waiting`],
    [wake-ups are replaced and cancelled; a desk schedules its deadline and policy steps and cancels them], [`schedule`],
    [settlement notices are admitted in order], [`settled`],
    [new ids are unique], [`new_id`],
    [a desk keeps every invariant; a refused release leaves nothing behind; an early wake-up says when to come back], [the whole contract under a desk],
    [a subject lock stores nothing and orders two admissions], [`load` of an id used purely as a lock],
  ))
  #points(
    [`decisions/testing.check(tx, inspection, audits)` reads every occurrence of the audited points through the inspection and their desks and reports each violation of I1 to I8, as the root design states them. `testing.audit(desk, effects:)` also counts the gated tool's effects for I1; `testing.audit_record(desk)` does not.],
    [The clauses that need several processes are proved by `decisions_otp/stress`, which a store runs by building a target (#ctx("runtime")). #adr(6) records why the contract is executable.],
  )
])

#section(title: "Adapters", lead: "Three stores implement the port, for one process, for many processes in one VM, and for a database.", body: [
  #components(
    component(name: "Memory store", tint: "teal", mission: "A single-process store of text for tests and examples.", answers: answers-data(
      responsibility: [Implement the whole port in `decisions/memory` and pass the conformance suite.],
      interface: [`new`, `transaction`, `restart`, `port`, `inspection`, `evidence`, the clock (`now`, `set_clock`, `advance`), `queue`, `queue_for`, `review_queue`, `wakes`, `take_due`, `snooze`, `notices`, `get`, `put`, `tamper`.],
      interactions: [The same table holds the application's own rows, so a gated tool's writes commit and roll back with the verdict that released them.],
      invariants: [It keeps only text, so `restart` keeps exactly what a database would. A body that returns an error or raises puts every row back.],
      failure: [It serialises nothing: the lock the port promises holds only because one process runs one transaction at a time. It builds for Erlang and JavaScript.],
    )),
    component(name: "OTP store", tint: "teal", mission: "A process-safe in-memory store with real transactions.", answers: answers-data(
      responsibility: [Implement the port in `decisions_otp/store` for many processes at once.],
      interface: [`start`, or `supervised(config, named:)` and `named(name)` in an application's tree; `stop`, `restart`, `transaction`, `handle`, `port`, `inspection`, `evidence`; the queue reads `queue`, `queue_page`, `queue_for`, `queue_page_for`, `review_queue` and `review_queue_of`; the paged reads `occurrences_of` and `settled_since`; `subscribe`, `unsubscribe`, `backlog`, and application rows as text.],
      interactions: [A transaction runs in the calling process with a buffer no other transaction sees; one owner process grants locks, applies each commit and monitors every process that holds a transaction. Every read of committed rows through the queues, `waiting`, the pages and the inspection sees each commit whole or not at all (#adr(43)). The backlog's `due`, `undelivered` and `claim_trigger` read raw and rely on a check under the job's lock before they act.],
      invariants: [`load`, `append`, `schedule` and taking a wake-up lock the id whether or not it exists. A savepoint that rolls back keeps its locks until the transaction ends. Queue reads use indexes kept beside each head in queue order, and `occurrences_of` and `settled_since` follow a number the owner gives each commit, with an opaque cursor, so a page costs what it returns and a reader that keeps its cursor reads each occurrence or settlement once (#adr(44)).],
      failure: [A wait that would close a cycle is refused at once, and one longer than `lock_timeout` is withdrawn; both are `Contended`. A stopped owner is `Unavailable`; `named` and `subscribe` return an `OwnerError` (`StoreStopped`, `NoAnswerWithin`, `NoSubscriber`), so a slow owner is not reported as stopped. Stopping the owner loses every row. `restart` takes the snapshot and stops the old owner in one step, so every acknowledged commit is kept and a commit that reaches the old owner afterwards fails as "outcome unknown" (#adr(43)). Under a supervisor, a restarted owner starts an empty store under the same name and every earlier handle fails, so the store goes first under a `RestForOne` supervisor with everything that uses it after it, and each user takes a fresh handle with `named`. A handler's failed attempt waits the store's `retry_backoff`, doubling up to 64 times it. The `Stopped` clock breaks the clause that `now` is the wall clock, so the stress suite needs the `Wall` clock.],
    )),
  )
  #subsection(title: "PostgreSQL adapter")[
    #answers(title: "decisions_postgres", responsibility: [Implement the port over the application's own PostgreSQL transactions and ship its schema.], interface: [`new(jobs)`, `with_queue`, `following(point)`, `with_name`, `with_wake_attempts`, `with_settlement_attempts`, `with_snooze_limit`, `with_lock_timeout`, `with_clock_offset` (for tests), `port(store)`, `inspection`, `migrate`, `transaction`, `transaction_with`, `refusing`, `decide`, `set_aside`, the workers, `sweep`, `deliver_due` and `deliver_notices` of the #ctx("runtime") context, and `decisions_postgres/queue`.], interactions: [Every port function runs in the connection it is handed: the caller's open transaction, or the pool, where each call commits by itself. The application owns the pool and the Grind runtime.], invariants: [Every transaction runs at `READ COMMITTED`: each statement takes a new snapshot, so a read made after a lock is granted sees what the lock's previous holder committed, which the subject lock relies on. `load` refuses a transaction at another isolation level with `Conflict` (#adr(50)). The tables are named without a schema and resolved through the connection's `search_path`. An occurrence id and a point name are at most 255 bytes (`max_name_bytes`), checked before every append and by two constraints, so the `NOTIFY` payload stays under PostgreSQL's limit; a longer one is refused with `Conflict` (#adr(46)).], failure: [`transaction` and `decide` return a `Failure`: `Refused(refusal)`; `RefusedUnrecorded(refusal, detail)`, a refusal whose second transaction could not keep it on the record; `Conflict`; `Contended`; or `Unavailable`. In each case the transaction rolled back. The port maps an integrity violation (SQLSTATE class 23) to `Conflict`, a deadlock, a serialization failure or a lock wait that timed out to `Contended`, and every other failure to `Unavailable`. `load` sets a lock timeout of 4 seconds by default (`with_lock_timeout`), below `pog`'s 5-second connection checkout, so a long wait for a contended occurrence ends as `Contended` rather than as a lost connection reported `Unavailable` (#adr(51)); it overrides a timeout the caller set earlier in the transaction, and `None` keeps the caller's or the role's; after `Unavailable` on the commit reply, the commit may have happened.])
    #md-table(2, (
      [*Guarantee*], [*Mechanism*],
      [Entries are never changed or removed, against every role that does not own the tables], [A statement trigger on `decisions_entries` refuses update, delete and truncate. The owner can disable a trigger or drop a constraint, so the application runs as a role that does not own the tables, with `SELECT, INSERT, UPDATE, DELETE` on `decisions_occurrences`, `decisions_awaiting`, `decisions_wakes` and `decisions_settled` and `SELECT, INSERT` on `decisions_entries`; the suite runs verbs as such a role.],
      [A sequence number is held once], [Primary key `decisions_entries_pkey (occurrence_id, seq)`.],
      [Entries follow each other without a gap], [Foreign key `decisions_entries_no_gap`: entry n references entry n − 1 of its occurrence.],
      [At most one release per occurrence], [Unique index `decisions_entries_one_release` on released entries.],
      [Only known entry kinds and statuses], [Checks `decisions_entries_kind` and `decisions_occurrences_status`, equal to `entry.kinds` and `store.statuses`.],
      [One admission per id under concurrent deliveries], [`decisions_load` locks the head row, or an advisory lock on the id when there is no row, then the row again, and reads the entries after the lock is held.],
      [The head and the queues change with the entries], [`decisions_append` writes the head, the entries, the per-set queue rows and a `NOTIFY` in one statement.],
      [A tool that writes and refuses leaves nothing], [`atomically` is a savepoint; a tool that raises rolls back to it and raises again.],
      [The store clock], [`clock_timestamp()` at the moment of the call, never `now()`, truncated to the millisecond entries keep.],
      [Wake-ups survive a restart, and a cancelled one does nothing], [One `decisions_wakes` row per wake-up and a Grind job admitted in the same transaction; the job acts only while its row is pending.],
      [A pending row always has a job, or a sweep admits one], [`sweep(store, db)` admits a job for every pending wake-up and every undelivered notice of a followed point whose job will not deliver it: a job pruned, ended, held uncertain for a person, or never admitted because the point became followed later. Run it at start and when an operator wants to (#adr(45), #adr(56)).],
      [One settlement notice per occurrence], [Unique constraint `decisions_settled_once`.],
      [Ids], [`new_id` is a UUID version 7 made on the node.],
    ))
    #points(
      [`migrate(db)` runs the shipped migration under an advisory lock, records each version once, and is safe to run again and at once from several nodes. The SQL in `priv/migrations` is the same statements, for an application that runs its own migration tool.],
      [`transaction_with(db, body)` runs a body that also does the application's own work and fails with the application's own error: a verb's refusal is lifted with `decisions_postgres.desk` into `BodyFailure.Desk`, the application's error is `BodyFailure.Own`, and the result is `Failed`: `LibraryFailed(failure)`, classified exactly as `transaction` classifies it, or `OwnFailed(error)`. Both roll the transaction back.],
      [`refusing(db, body)` is `transaction` in the shape of a verb: its failure is a `Refusal`, as `decisions_otp/isolated.recommend` and `recommend_when` want for their `in:`. A failure of the transaction itself becomes `StoreFailed` with its classification kept.],
      [`with_clock_offset(offset)` makes the store's clock read the database's clock plus an offset, so a test can stand an hour later without waiting; wake-up jobs are still scheduled on the database's clock, at the moment the store's clock reaches their time. Production leaves it at zero.],
      [`decide` gives a verdict in a transaction of its own and, when the gated tool refuses, keeps the refused verdict on the record in a second transaction with `record_refusal`. A card opened inside the rolled-back transaction names a showing the record no longer holds, so a caller resumes from a ticket.],
      [`set_aside(occurrence)` sets aside a record that no longer decodes: it leaves every queue, `waiting` no longer returns it, and its pending wake-ups are set aside with it. Its entries stay as they are, and nothing undoes it.],
      [`decisions_postgres/queue` reads heads alone, each query served by one index: `page(for: validator, limit:, after:)` orders by due time, arrival and id and leaves out cards the validator already approved or may not decide, and `page_at` does the same for one point; `counts`, `about(subject)`, `review_queue` for one point and `review_queue_all` across points, `pending` for the records of a point that have not begun, oldest first, `positions` (the last sequence number of each occurrence, for polling) and `set_aside`. What a page returns is what was committed when it ran.],
      [For learning and export, `occurrences_of(point)` pages through a point's occurrences by id, and `settled_since(point, since)` through its settlements in the order of the transactions that admitted them, with a `Position` cursor; a page holds only settlements whose transaction ended before every transaction still running began, so a reader that keeps its cursor reads each settlement exactly once (#adr(44)). A transaction left open holds back every later settlement until it ends. The OTP store has the same two reads, both in commit order. Each occurrence is then read with `decisions.read`.],
    )
  ]
])

]
