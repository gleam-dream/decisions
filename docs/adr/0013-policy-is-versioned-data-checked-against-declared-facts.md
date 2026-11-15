# Policy is versioned data checked against the facts a point declares

<a id="adr-0013"></a>

## Decision

- Every condition for proceeding without a person is a `Policy` value: rules, a default, and a version. It reads only the recommender and named facts. The declaration holds no condition.
- A point declares the facts a policy may read with typed keys. `publishable(point, policy)` refuses a policy that reads an undeclared fact, compares a fact as the wrong type, asks for fewer than one approval or samples outside 0 to 100; the desk checks it on every read.
- Time is a fact: `waited_minutes`. The policy's timeline is computed when it is applied and kept on the record, so a waiting occurrence keeps the version it was given; a consulted point's answer is the one moment the current version is read again. Every `policy_applied` entry records its version.
- Publishing a version is a write wherever the application stores it; the desk reads it in the caller's transaction.

## Rationale and alternatives

- Gate's policy was a function inside the declaration: it can read anything in the output, nothing but review keeps a guard's fact out of it, and version 2 is a new point and a deploy. Data makes the threshold a row, the autonomy ladder five policy versions with no code change, and a published version comparable and exportable.
- A policy that reads `"ammount"` never matches and silently asks; the publish check and typed keys close that.
- A condition that needs code becomes a fact computed by the declaration, which keeps the policy data. Whether eight conditions and `Several` are enough is open (pending in the record context).

## Evidence and history

- `/code/gleam-dream/decision-point-lab/FINDINGS.md`, "Where each rule lives" and the `policy.check` item; `FINDINGS-2.md`, use cases 10, 11, 15 and 20, and "Types".
- `test/f_types_test.gleam`, `a_policy_that_reads_an_undeclared_fact_is_not_publishable_test` and `a_desk_refuses_to_use_an_unpublishable_policy_test`; `test/uc11_escalation_test.gleam`; `test/uc15_ladder_test.gleam`, `one_point_climbs_from_no_model_to_sampled_and_back_test`; `test/corrections_test.gleam`, `c13_inform_applies_and_records_the_current_version_test`; fixtures `a_number_rule_on_a_text_fact` and `a_text_value_for_a_number_fact`. Decided 2026-11-15.
