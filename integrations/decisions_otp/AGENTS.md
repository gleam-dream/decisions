# Decisions OTP integration instructions

- This is a nested package in [decisions](../../AGENTS.md). Use the parent dev shell, design-gate pin and the parent's local `issues/` tracker; this package has no independent flake, gate copy or tracker.
- It holds the process-safe in-memory store, the supervised runtime, isolated model calls, parallel replay and subscriptions. It depends on the published core by its Hex range (`decisions = ">= 0.3.0 and < 0.4.0"`), and its tests run against that release; it also depends on `gleam_otp`, `gleam_erlang` and `sinal`. The core owns the meaning of points, occurrences, entries and policies; this package owns processes, their lifetimes and their failure handling.
- Prove a race with real processes against a real transaction boundary, and a crash with `process.kill`.
- Run its checks from this directory in the parent shell:

```sh
nix develop ../.. --command bash -c 'gleam format --check src test && gleam build --warnings-as-errors && gleam test'
```

## Commit messages

Use a concise subject and an optional explanatory body. Do not add any commit
footers or trailers, including `Co-authored-by`, `Signed-off-by`, `Reviewed-by`,
`Acked-by`, or tool/AI attribution. Do not use `git commit --signoff` or let an
automated tool append a footer. Tracker-comment attribution rules apply only to
tracker comments, never to commit messages.
