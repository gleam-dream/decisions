# The sweep reads pending rows in batches and each batch's jobs in one listing

<a id="adr-0065"></a>

Recorded on 2026-11-27.

## Decision

`decisions_postgres.sweep` reads pending wake-ups and undelivered notices 500 rows at a time with a keyset on the row. Rows with no recorded job come first and need no Grind read. The other rows are read in the order of their jobs, and one `grind/admin.list` of the store's queue, from the batch's first job id to its last, gives the state and the settlement mark of every job of the batch. A second page is read only when more than 10 000 jobs of the queue fall between those two ids. Jobs admitted during the sweep have ids above the highest recorded when it started, so their rows are not read again.

## Why

The sweep loaded every pending row into one list and then made two Grind reads for each row, plus a listing of every uncertain job. A restart with a large backlog of awaiting occurrences, which is when an operator needs recovery to be quick, then held the whole backlog in memory and made two round trips per row: 3 699 statements for 600 pending rows in the test that records it. Reading a job's state and its settlement mark in one listing also removes the separate uncertain listing and the window between it and the state read.

## Alternatives

- **Keyset pages with a Grind read per row.** It bounds memory but keeps the round trips per row.
- **A join against Grind's job table.** It would be one query, but the table is Grind's own and not part of its public API.
- **A batch read of jobs by id in Grind.** It would make each batch exactly one read; Grind has no such read today.

## What changes for consumers

Nothing in the API. `sweep` returns the same `Swept`.
