# Occurrence ids and point names are bounded in PostgreSQL

<a id="adr-0046"></a>

## Decision

- `decisions_postgres` keeps an occurrence id (a `recommend_once` key) and a point name of at most 255 bytes (`max_name_bytes`). A longer one is refused at once with `Conflict`, whose detail says so; two constraints hold the bound in the schema.

## Rationale and alternatives

- Every append sends `NOTIFY` with the id and the point, and PostgreSQL limits the payload to 8 000 bytes. A long id made every append fail with `Unavailable`, and the job was redelivered without end.
- Truncating the payload was rejected: a subscriber could no longer name the occurrence. A typed refusal in the core was not built; that the bound lives in one adapter is a tracker issue.

## Evidence and history

- Independent review of both adapters, 2026-11-15, finding G3 (probe P1). `integrations/decisions_postgres/src/decisions_postgres.gleam`, `max_name_bytes`; the package's tests of both bounds.
