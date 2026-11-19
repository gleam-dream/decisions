# Decisions PostgreSQL integration instructions

- This is a nested package in [decisions](../../AGENTS.md). Use the parent dev shell, design-gate pin and the parent's local `issues/` tracker; this package has no independent flake, gate copy or tracker.
- It holds the storage port over PostgreSQL, its migrations, the Grind workers for wake-ups and settlements, `NOTIFY` and the queue queries. It depends on `decisions` by path (`decisions = { path = "../.." }`) until its release commit (a Git tag, not a Hex release) replaces that with the core's Hex range, and on `pog`, `pgo`, `grind` and `sinal`, with the `pog` and `pgo` ranges equal to Grind's; `decisions_otp` is a dev-dependency only, for the shared stress scenarios and scale workloads.
- The application owns the connection pool. Do not add pool startup or shutdown to this package.
- Run database tests only through the parent's `scripts/test-postgres.sh`. It creates a throwaway PostgreSQL 16 cluster, passes its URL in `DECISIONS_TEST_DATABASE_URL`, and removes the cluster on exit. Plain `gleam test` has no database URL. Never select another database for verification.

```sh
nix develop ../.. --command bash -c 'gleam format --check src test && gleam build --warnings-as-errors && bash ../../scripts/test-postgres.sh'
```

## Commit messages

Use a concise subject and an optional explanatory body. Do not add any commit
footers or trailers, including `Co-authored-by`, `Signed-off-by`, `Reviewed-by`,
`Acked-by`, or tool/AI attribution. Do not use `git commit --signoff` or let an
automated tool append a footer. Tracker-comment attribution rules apply only to
tracker comments, never to commit messages.
