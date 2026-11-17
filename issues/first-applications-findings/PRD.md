# What the first applications still found

AI-assisted contribution.

Three Oversight applications use `decisions`, `decisions_otp` and
`decisions_postgres` end to end: `clinic_registration`, `payout_desk` and
`moderation_desk`, under `apps/` in `gleam-dream/oversight`. Their friction
drove the application round (ADR 0036). This feature collects what they still
work around after that round, what the two final independent reviews and the
last rounds left open (ADR 0047), and the decisions the owner still has to
make.
Each issue is a brief: the behaviour wanted, the evidence in the application,
and what done looks like. None prescribes an implementation.

Twenty-eight issues: 10 done, 17 needs-triage, 1 wontfix.

| Issue                                                                                                                                                                                                      | State        |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| [01. `recommend_when`'s precondition cannot report a store failure](issues/01-recommend-when-precondition-cannot-report-a-store-failure.md)                                                                | done         |
| [02. A failed attempt recorded by `recommend_when` carries no evidence](issues/02-a-failed-attempt-in-recommend-when-carries-no-evidence.md)                                                               | done         |
| [03. `recommend_when` needs an adapter around `decisions_postgres.transaction`](issues/03-recommend-when-wants-a-refusal-transaction.md)                                                                   | done         |
| [04. `occurrence.account` does not carry the release key](issues/04-the-account-of-a-release-lacks-its-key.md)                                                                                             | done         |
| [05. A failed attempt and its occurrence end up under different keys](issues/05-a-failed-attempt-and-its-occurrence-under-different-keys.md)                                                               | needs-triage |
| [06. `decided_by` has no answer for an expired occurrence](issues/06-decided-by-has-no-answer-for-an-expired-occurrence.md)                                                                                | needs-triage |
| [07. Two desks that consult each other need mutually recursive constructors](issues/07-two-desks-that-consult-each-other.md)                                                                               | needs-triage |
| [08. Judging a candidate model under a candidate policy means rebuilding the example](issues/08-judging-a-candidate-model-under-a-candidate-policy.md)                                                     | done         |
| [09. The OTP store's retry backoff never ends under a stopped test clock](issues/09-retry-backoff-on-a-stopped-test-clock.md)                                                                              | needs-triage |
| [10. A restarted in-memory store is empty and every application seeds it](issues/10-a-restarted-in-memory-store-is-empty.md)                                                                               | needs-triage |
| [11. The policy cannot say "two approvals, one of them by a senior", nor read who recommended](issues/11-two-approvals-one-of-them-senior-and-who-recommended.md)                                          | needs-triage |
| [12. An application's own telemetry needs `source` passed by hand](issues/12-application-telemetry-needs-source-by-hand.md)                                                                                | needs-triage |
| [13. Decide whether the policy hold belongs inside `Proceed`](issues/13-decide-whether-the-policy-hold-belongs-inside-proceed.md)                                                                          | done         |
| [14. Decide whether a held occurrence is superseded](issues/14-decide-whether-a-held-occurrence-is-superseded.md)                                                                                          | done         |
| [15. Decide whether the port carries a per-subject marker for the superseding window](issues/15-decide-whether-the-port-carries-a-per-subject-marker.md)                                                   | wontfix      |
| [16. A lone worker can loop on a trigger that must be delivered again](issues/16-a-lone-worker-can-loop-on-a-redelivered-trigger.md)                                                                       | done         |
| [17. The in-memory backlog's reads are not consistent across a commit](issues/17-the-in-memory-backlog-reads-are-not-consistent-across-a-commit.md)                                                        | needs-triage |
| [18. `occurrences_of` orders by commit in one store and by id in the other](issues/18-occurrences-of-orders-differently-in-the-two-stores.md)                                                              | needs-triage |
| [19. Live notifications have two shapes across the two packages](issues/19-live-notifications-have-two-shapes.md)                                                                                          | needs-triage |
| [20. A queue can show a card to someone barred under the only alternative they qualify for](issues/20-a-queue-can-show-a-card-to-someone-barred.md)                                                        | needs-triage |
| [21. The bound on key length is enforced by the PostgreSQL adapter, not by the core](issues/21-the-key-length-bound-is-enforced-by-one-adapter.md)                                                         | needs-triage |
| [22. The PostgreSQL stress target's restart is a new pool, not a server restart](issues/22-the-postgres-stress-restart-is-a-new-pool.md)                                                                   | needs-triage |
| [23. `Unsure` at a hold's wake-up was not watched to fail with the fix removed](issues/23-unsure-at-a-holds-wake-up-was-not-watched-to-fail.md)                                                            | done         |
| [24. There is no queue of held occurrences to withdraw from](issues/24-no-queue-of-held-occurrences.md)                                                                                                    | needs-triage |
| [25. `isolated.recommend` can never return `Skipped`, yet its caller must match it](issues/25-isolated-recommend-can-never-return-skipped.md)                                                              | needs-triage |
| [26. The payout desk starts a fresh Fabric run per retry and cancels a parked run itself](issues/26-payout-desk-starts-a-fresh-run-per-retry-and-cancels-parked-runs.md)                                   | done         |
| [27. The in-memory runtime drops a notice for a record superseded before it began; PostgreSQL hands it to the follower](issues/27-the-two-runtimes-treat-a-notice-for-a-record-never-begun-differently.md) | needs-triage |
| [28. Do two expectations about one subject need an order when no `happened` runs?](issues/28-admission-order-for-points-that-only-expect.md)                                                               | needs-triage |
| [29. Does a follow-on run start from the world as it is, or from the handed-over run's history?](issues/29-the-follow-on-recipe-continues-the-waiting-runs-view.md)                                        | done         |
