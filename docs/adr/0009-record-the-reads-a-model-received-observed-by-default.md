# Record the reads a model received, observed by default and reported when the model knows better

<a id="adr-0009"></a>

## Decision

- The record holds the reads a model received, never the reads it merely called.
- By default `model.run` observes: every read the sources answered while the model ran is recorded (`model.new`, `model.over`). This is right for a model that uses every answer it asks for, such as one provider call or a rule.
- A model built with `model.reporting` or `model.over_reporting` reports the reads it received in its recommendation, and `run` believes the report. A cascade records only the reads of the stage that answered.
- A changed read is flagged on the card like a changed context reference.

## Rationale and alternatives

- In an agent loop a tool read can fail, be retried after the data moved, and succeed. Counting calls put on the card a value the model never had, which breaks the promise that a validator sees what the model saw. The Fabric recipe avoided it by taking reads from succeeded actions; the core's default was wrong (defect 8).
- Reporting always was rejected: most models are single calls whose observed reads are exactly what they received, and a report is one more thing to get wrong. Observing always was rejected for the agent case above.

## Evidence and history

- `/code/gleam-dream/decision-point-lab/ledger_fabric/test/c3_model_run_recording_test.gleam`, `c3_model_run_also_counts_a_read_the_model_never_received_test`; `c3_agent_reads_test.gleam`, `c3_every_read_the_model_received_is_on_the_record_test` and `c3_e1_the_card_shows_exactly_what_the_agent_read_test`. `FINDINGS-2.md`, "The same context, to a person", and items 8 and 9.
- In this repository: `test/defects_test.gleam`, `defect_8_a_reported_read_is_believed_test` and `defect_9_a_changed_read_is_flagged_test`; `test/corrections_test.gleam`, `c14_interface_corrections_test` (cascade stages). Owner decision 4, 2026-11-15.
