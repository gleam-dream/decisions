# In-memory occurrence ids are UUIDs made on the node

<a id="adr-0064"></a>

Recorded on 2026-11-27.

## Decision

The process-safe store of `decisions_otp` makes a new occurrence id as the PostgreSQL adapter does: a UUID version 7, 48 bits of Unix milliseconds and then random bits, made on the node. The owner's counter no longer names occurrences.

## Why

- An id was `occ-` and a counter of the owner's. The counter lived in the owner's tables, so a supervised restart, which starts an empty store (the store's own failure path), issued `occ-1`, `occ-2` and so on again.
- Applications key external effects by the occurrence's id, as the PostgreSQL README recommends. After a restart the external system deduplicated a new occurrence against an old one with the same id, and the effect was dropped or attached to the wrong record. Losing the store's rows is a loss the application accepted; a silent identity collision is not.
- A UUID is unique by construction, so nothing about it is lost with the owner. The two stores then make ids one way.

## Alternatives

- **Keep the counter across restarts.** `restart` already hands the committed rows to a new owner, but a supervised restart starts empty by design, and nothing outside the VM keeps the counter.
- **Prefix the counter with the owner's start time.** It is unique per owner start, but it is a second id scheme beside PostgreSQL's for no gain.

## What changes for consumers

`decisions_otp` 0.2.0: occurrence ids are UUIDs instead of `occ-` and a number. Treat them as opaque text; ids made later still sort later.
