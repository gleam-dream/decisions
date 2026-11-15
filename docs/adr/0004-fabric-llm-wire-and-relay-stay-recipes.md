# Fabric, llm_wire and Relay stay recipes in the application

<a id="adr-0004"></a>

## Decision

- None of the three packages depends on Fabric, llm_wire or Relay. Each join is compiled application code, kept in the Oversight example applications.
- The library never needs a type of these libraries. An explanation holds a run id as text (`RunAnswer`, `RunAction`); a provider's answer is captured evidence (`Receipt`); an MCP caller is the connection's context.

## Rationale and alternatives

- The recipes were small: 425 lines for Fabric, 342 for llm_wire and 240 for Relay. Each library changes on its own schedule, and a bridge package would pin the core to all three.
- Hosting the record inside Fabric was rejected on evidence (ADR 0001). A bridge package per library was rejected because nothing in the core needs one.

## Evidence and history

- `/code/gleam-dream/decision-point-lab/ledger_fabric/` (21 tests: agent reads, the gated tool call corrected by a person), `ledger_llm/` (10 tests: one provider call with a typed answer, `c2_the_request_and_the_answer_are_evidence_test`), `ledger_relay/` (`another_system_works_the_queue_over_mcp_test`).
- `FINDINGS.md`, "The answer" (packaging), and `FINDINGS-2.md`, "Other packages". Owner decision 2, 2026-11-15.
