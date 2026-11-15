# Refusals are classified by four meanings

<a id="adr-0039"></a>

## Decision

- `Disposition` is `Transient | Retry | Poisoned | Final`, and `handling` maps them to `Redeliver | Backoff | SetAside | Drop`:
  - deliver again, uncounted, only for contention and an unavailable store (`Transient`);
  - deliver again after a backoff, counted, for what may pass but may also never pass: `StoreFailed(Conflict)`, `NoPolicy`, `ConsultFailed`, `ToolUnsure`, and an application failure (`Retry`);
  - set aside for what needs an operator while the occurrence still waits for the job: `Unreadable`, `Unpublishable`, `InvalidFacts`, `Unencodable`, `KeyTaken` (`Poisoned`);
  - drop only when the occurrence moved on or the job can never apply (`Final`).
- The classification names every variant, and its reasoning is a table in `disposition`'s doc comment.

## Rationale and alternatives

- The earlier classification had two errors. Endless redelivery: `ConsultFailed` from a desk with no consult handler, `NoPolicy` for a policy that never exists and a repeating `Conflict` were redelivered uncounted for ever. Lost work: `Unpublishable`, `InvalidFacts` and `Unencodable` were dropped as done although the occurrence still waited for what the job was delivering.
- Counting contention was rejected: under load it would set healthy jobs aside.

## Evidence and history

- Final review of the core, 2026-11-15, finding R4. `src/decisions.gleam`, `Disposition`, `disposition`, `Handling`, `handling`; the core's tests of the lost-work and endless cases. This supersedes the classification of ADR 0021 and refines ADR 0035.
