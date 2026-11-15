# Agent Instructions

## About this repo

`decisions` models the decision point in Gleam: a model recommends an output, a
policy either proceeds or asks a person, the person approves, rejects or
corrects, and the final output is released exactly once to a gated tool. Every
step is kept as an append-only record of entries, and that record is the data
the system learns from.

The repository holds three packages:

| Package              | Path                              | Holds                                                                                                                             |
| -------------------- | --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `decisions`          | repository root                   | The pure core. It starts no process and performs no I/O.                                                                          |
| `decisions_otp`      | `integrations/decisions_otp`      | The process-safe in-memory store, the supervised runtime, isolated model calls, parallel replay and subscriptions.                |
| `decisions_postgres` | `integrations/decisions_postgres` | The storage port over PostgreSQL, its migrations, the Grind workers for wake-ups and settlements, `NOTIFY` and the queue queries. |

The two integrations depend on the root by path (`decisions = { path = "../.." }`)
while it is unpublished. The core never depends on an integration. The design
layer under `docs/design/` owns the contracts and the vocabulary, `docs/adr/`
records the rationale, and `docs/COVERAGE.md` maps repository parts to their
design owners.

## Tooling

- When updating dependency pins, reconcile affected `manifest.toml` files in examples and nested packages through Gleam, then run the full repository gate; updating the root lock alone is insufficient.

- `nix develop` (or direnv): dev shell with `gleam`, Erlang/OTP 29, `rebar3`, `lefthook`, Node.js 24 for the JavaScript target, and PostgreSQL 16 for `integrations/decisions_postgres`.
- `nix fmt`: formats the whole repo via treefmt (`gleam format`, `nixfmt`, `prettier`, `shfmt`). The compiler-negative fixtures under `fixtures/` are excluded because they are deliberately invalid.
- `lefthook`: the pre-commit hook formats staged files, re-stages them, and runs the design-layer check.
- `nix flake check`: fails iff the tree is not formatted.
- Dependencies use Hex version requirements, and each package's `manifest.toml` is its lock. Update one with `gleam deps update <package>` in the package directory.

## Validation

Use the shared tools directly, then run application tests:

```sh
nix flake check
nix run .#design-gate-check -- docs/design .
nix develop --command bash scripts/test.sh
```

For the core edit loop, run `nix develop --command gleam test`.

`scripts/test.sh` builds every package with `--warnings-as-errors` and tests it,
in this order: the root package, `examples/usage`, `integrations/decisions_otp`,
`integrations/decisions_postgres` (through `scripts/test-postgres.sh`), then
`scripts/check_negative.sh` and `scripts/check_javascript.sh`. It does not run
formatting or design validation. It prints a `SKIP` line for a part that does
not exist and says at the end which parts were not tested. CI runs it with
`--require-all`, which fails the run when a part is missing.

- `examples/usage` is a separate package (path dependency on `decisions`) that imports only public modules. Run `gleam test` inside it.
- `integrations/decisions_otp` is a separate package so that the core never depends on `gleam_otp`. Run `gleam test` inside it.
- `integrations/decisions_postgres` is a separate package so that the core never depends on `pog` or Grind. Run its tests only through `nix develop --command bash scripts/test-postgres.sh` from the repository root. The script creates a throwaway PostgreSQL 16 cluster, sets `DECISIONS_TEST_DATABASE_URL` to it, runs `gleam test` in the package, and removes the cluster on exit. It unsets every `PG*` variable and never selects another database.
- `scripts/check_negative.sh` proves the compiler-negative fixtures under `fixtures/negative/` still fail to compile.
- `scripts/check_javascript.sh` builds every public module of the core for JavaScript with warnings as errors and, when Node.js is on `PATH`, runs one scenario there (recommend, open, decide and release, the card document, replay, the invariant check and the conformance suite). The core's own test suite runs on Erlang only.

## Benchmarks

The scale runs are observational and gate nothing: `cd integrations/decisions_otp/bench && gleam run` for the in-memory store, `nix develop --command bash scripts/test-postgres.sh scale` for PostgreSQL. `nix develop --command bash scripts/test-postgres.sh stress` runs the shared stress scenarios against PostgreSQL at the default load. `docs/BENCHMARKS.md` retains the method, the machine, the numbers and the limits.

## References

- `examples/usage` holds the usage examples as compiled, runnable code. Add or change an example in the same change as the API it shows.
- `integrations/decisions_otp/AGENTS.md` and `integrations/decisions_postgres/AGENTS.md` hold the rules for each integration.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

## Agent skills

**Design layer** — `docs/design/design.typ` describes the design (the layer
renders to one `docs/design/design-layer.pdf`), each `CONTEXT.typ` under
`docs/design/` defines its context's vocabulary, and `docs/adr/` records
decision rationale. `docs/CONTEXT-MAP.md` indexes the design documents.
`docs/COVERAGE.md` maps repository parts to their design owners.

**Tracker** — local markdown under `issues/`: one directory per feature
(`issues/<feature-slug>/`), the PRD at `issues/<feature-slug>/PRD.md`, issue
files at `issues/<feature-slug>/issues/<NN>-<slug>.md` numbered from 01. Each
issue file carries two header lines near the top — `Status: <state>`,
`Category: <category>`. Conversation appends to the bottom
of the file under a `## Comments` heading. Labels (canonical strings, adopted
verbatim): states `needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `in-progress`, `done`, `wontfix`; categories `bug`,
`enhancement`.

**AI disclaimer** — AI-authored tracker comments start with
`AI-assisted contribution.`

**Shared design validation** — `nix run .#design-gate-check -- docs/design .`
uses the pinned design-layer implementation for render freshness, vocabulary and
layer integrity. `nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`
updates the rendered document; `nix run .#design-gate-context -- docs/design` exports
context. Run these tools sequentially because they share `.render`. If an
integration gets its own layer under `integrations/<package>/docs/design/`, add
`--nested-project integrations/<package>` to the check in `lefthook.yml`, CI and
this file.

<!-- agent-skills:end -->

## README snippets

Keep README Gleam examples in compiled example source. Use named
`snips-start` / `snips-end` regions (or include a whole example module), and retain
Prettier ignore ranges around generated README blocks. Format the source first,
then run `nix run .#snips -- --commands deny README.md`. CI runs
`nix run .#snips -- --check --commands deny README.md` using the shared pinned
package. Snips checks synchronization; the example tests check behavior. Add a
nested README to both commands when one is created.

## Commit messages

Use a concise subject and an optional explanatory body. Do not add any commit
footers or trailers, including `Co-authored-by`, `Signed-off-by`, `Reviewed-by`,
`Acked-by`, or tool/AI attribution. Do not use `git commit --signoff` or let an
automated tool append a footer. Tracker-comment attribution rules apply only to
tracker comments, never to commit messages.
