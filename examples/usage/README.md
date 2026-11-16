# Decisions usage examples

[![CI](https://github.com/gleam-dream/decisions/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/decisions/actions/workflows/ci.yml)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

Compiled, runnable examples of the public API, one module under
`src/decisions_usage/` per topic. The package depends on `decisions` by path
and imports only its public modules, so an incompatible change to the API fails
the build here. Each topic has a `run` function, and
`test/decisions_usage_test.gleam` asserts what it returns. The repository
[README](../../README.md) quotes the regions between `snips-start` and
`snips-end` markers.

| Module                  | Region                  | Shows                                                                                                                                            |
| ----------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `clinic`                | `refund-point`          | The cast every topic shares, the refund point's declaration with its one fact, and the gated tool whose executor accepts only a released refund. |
| `first_point`           | `first-point`           | A recommendation admitted once per key, a policy that asks `finance`, and a verdict that releases the refund once in its own transaction.        |
| `autonomy_ladder`       | `autonomy-ladder`       | Two policy versions published as data and checked with `publishable`; the same code path files every refund.                                     |
| `ticket`                | `ticket`                | A card opened in one request and decided in another from its ticket; a ticket shown to someone else is refused.                                  |
| `four_eyes`             | `four-eyes`             | Two different approvers, neither the person who asked; escalation to managers after four hours; expiry after a day, applied by wake-ups.         |
| `two_or_one_senior`     | `either-several`        | An eligibility with alternatives: two approvals from finance, or one from the head of finance, each alternative judged on the approvals so far.  |
| `undo_window`           | `undo-window`           | An undo window carried by the policy's `Proceed`, and finance withdrawing during the hold; what a person approved is released at once.           |
| `provider_effect`       | `provider-effect`       | An instruction written beside the release, performed under the release key, and the effect recorded with `report`.                               |
| `same_context`          | `same-context`          | One reader for the model and the card, reads captured as evidence, and the card flagging a read that changed.                                    |
| `card_document`         | `card-document`         | The card served as a typed document with the card codec and its JSON Schema, and read back typed by a client with the same codec.                |
| `expect_then_recommend` | `expect-then-recommend` | A trigger expected in the transaction that receives it; a newer event supersedes it before the model's late recommendation, which is refused.    |
| `replay`                | `replay`                | Recorded occurrences exported as examples and a candidate model scored on them with no network.                                                  |

Every topic runs over `decisions/memory`, the single-process store for tests
and examples.

## Run

From the repository root:

```sh
nix develop --command sh -c 'cd examples/usage && gleam test'
```

`scripts/test.sh` runs these tests as part of the full gate. After changing a
region, format the source and run `nix run .#snips -- --commands deny README.md`
from the repository root to update the README. See the
[design](../../docs/design/design-layer.pdf), "Verification gates", and
[ADR 0016](../../docs/adr/0016-usage-is-compiled-examples.md).
