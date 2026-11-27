# Migrating to decisions 0.2

decisions 0.2.0, decisions_otp 0.2.0 and decisions_postgres 0.3.0 are breaking
releases. They move the three packages onto json_blueprint 3, Sinal 0.2 and
Grind 0.3, which are breaking releases themselves. The public API of each
package exposes types of those libraries (`json_blueprint`'s `Codec` in
`decisions/wire` and `decisions/view`, Sinal's `Event` in both `telemetry`
modules, Grind's `Grind` in `decisions_postgres.new`), so an application must
move to the same majors.

| Package              | From  | To    | What changes for the application                                                                        |
| -------------------- | ----- | ----- | ------------------------------------------------------------------------------------------------------- |
| `decisions`          | 0.1.1 | 0.2.0 | json_blueprint 3; card documents encode outputs of any depth and size; a policy's default asks a person |
| `decisions_otp`      | 0.1.1 | 0.2.0 | Sinal 0.2: a handler belongs to the process that attached it; accepts core 0.2                          |
| `decisions_postgres` | 0.2.1 | 0.3.0 | Sinal 0.2 as above; Grind 0.3 and its schema version 15; accepts core 0.2                               |

## Install

`decisions` is on Hex. The integrations are taken from this repository by Git
tag.

```toml
[dependencies]
decisions = ">= 0.2.0 and < 0.3.0"
json_blueprint = ">= 3.0.0 and < 4.0.0"

decisions_otp = { git = "https://github.com/gleam-dream/decisions.git", ref = "decisions_otp-v0.2.0", path = "integrations/decisions_otp" }
sinal = ">= 0.2.0 and < 0.3.0"

decisions_postgres = { git = "https://github.com/gleam-dream/decisions.git", ref = "decisions_postgres-v0.3.0", path = "integrations/decisions_postgres" }
grind = ">= 0.3.0 and < 0.4.0"
pog = ">= 4.1.0 and < 4.2.0"
pgo = ">= 0.20.0 and < 0.21.0"
```

List `json_blueprint` and `sinal` only when the application imports them.
Then run `gleam deps update decisions json_blueprint sinal grind`,
`gleam build --warnings-as-errors` and `gleam test`.

## decisions 0.2.0

### json_blueprint 3 is required

The core requires `json_blueprint >= 3.0.0 and < 4.0.0`. A point's codec built
with `wire.codec` and the card codec from `view.codec` are json_blueprint 3
codecs, so the application's own json_blueprint code moves to 3.0 with them.
json_blueprint's
[migration guide](https://github.com/gleam-dream/json_blueprint/blob/main/docs/MIGRATION.md)
lists its changes; the codec combinators that a point's codec is written with
are unchanged.

```toml
# Before
json_blueprint = ">= 2.2.0 and < 3.0.0"

# After
json_blueprint = ">= 3.0.0 and < 4.0.0"
```

### A card document encodes an output of any depth or size

json_blueprint 3 adds a 128-level depth bound to `value.default_limits()`,
which already bounded text to 1 MiB. When the card document, or a codec from
`wire.blueprint`, held a value in its JSON form (a `wire.plain` output, the
recommender, the explanation, the facts), the core re-read the text it had
just encoded with those limits. On json_blueprint 3 an output nested deeper
than 128 levels would therefore fail to encode. The core now parses that text,
which it wrote itself, with `value.unlimited()`.

```gleam
// An output whose wire.plain encoder writes 200 nested arrays.
let codec = wire.blueprint(wire.plain(encode, decoder))

// Before: the core re-read the text with value.default_limits(), so an output
// over 1 MiB failed, and on json_blueprint 3 so does one nested deeper than 128
// levels: Error(EncodeError([], Custom("the value does not encode")))
blueprint.to_json(codec, deep_output)

// After (0.2.0): Ok, with the encoder's own JSON.
blueprint.to_json(codec, deep_output)
```

Nothing to change in the application. An output schema deeper than 128 levels
also no longer stops `view.codec` from encoding a card.

### Decoding a client's card text is bounded

Decoding text that a client sent stays the application's call, with
json_blueprint's limits. `codec.decode_json(view.codec(output), text)` now
refuses a document nested deeper than 128 levels with
`InvalidJson(DepthLimitExceeded(128))`, as well as one larger than 1 MiB. Raise
the bound when the outputs need it:

```gleam
// Before (json_blueprint 2): only the 1 MiB bound applied.
codec.decode_json(view.codec(output), text)

// After: pass the bounds the outputs need.
let limits = value.default_limits() |> value.with_max_depth(512)
codec.decode_json_with_limits(view.codec(output), text, limits)
```

`view.verdict` and `wire.parse` decode with `gleam/json` and are unchanged.

### A policy's default asks a person, and an unknown condition asks it

A policy's `otherwise` is now an `Eligible`: who is asked when no rule holds.
A policy proceeds or consults only through a rule whose condition holds. A
condition over an absent or mistyped fact is unknown, and the first unknown
condition stops the reading: the policy asks `otherwise`, whatever the later
rules say. In 0.1 an unknown condition only failed to match, so a policy whose
default proceeded released a recommendation that lacked the fact it tested.

`Policy` is opaque. Build it with `policy.new`, which refuses what no point
could use (fewer than one approval, a nested `Several`, an empty `Either`, a
sample outside 0 to 100, a hold of zero or less) with `List(Malformed)`. Read
it with `policy.version`, `policy.rules` and `policy.otherwise`. A default that
proceeded or consulted becomes a last rule with the new `Always` condition.

```gleam
// Before (0.1)
Policy(
  version: 1,
  rules: [When(policy.at_least(risk, 0.5), Ask(AnyoneHolding("risk")))],
  otherwise: Proceed(Never, None),
)

// After (0.2): the same policy, and a missing or mistyped risk asks `risk`.
policy.new(
  version: 1,
  rules: [
    When(policy.at_least(risk, 0.5), Ask(AnyoneHolding("risk"))),
    When(policy.Always, Proceed(Never, None)),
  ],
  otherwise: AnyoneHolding("risk"),
)
```

- A policy that would consult the same point twice now asks `otherwise`.
- `policy.Fault` keeps `UndeclaredFact` and `WrongKind`, which `publishable`
  and `inform` report. `TooFewApprovals`, `SampleOutOfRange`, `NestedSeveral`,
  `EmptyEither` and `NonPositiveHold` move to `policy.Malformed`, described by
  `policy.describe_malformed`. `Unpublishable` no longer carries them.
- The stored JSON changes: `otherwise` holds an eligibility (`{"t": "anyone",
"set": "finance"}`) instead of an outcome, and `{"t": "always"}` is a
  condition. A policy stored by 0.1 does not decode; publish each version
  again in the new form. A stored policy that `new` refuses does not decode.

## decisions_otp 0.2.0

### A handler belongs to the process that attached it

The package depends on `sinal >= 0.2.0 and < 0.3.0`. Its events
(`decisions_otp/telemetry`) and the moments they are emitted are unchanged.
Sinal 0.2 detaches a handler when the process that attached it exits, for any
reason, including a normal return. A handler attached by a setup function that
a short-lived process runs stops observing as soon as that process ends, and
no error says so.

```gleam
// Before (Sinal 0.1): the handler outlived the process that ran setup.
pub fn setup() -> Nil {
  let _ = sinal.observe(telemetry.job_set_aside(), alert)
  Nil
}

// After (Sinal 0.2): attach from the process that stays alive, such as an
// actor's initialiser under the application's supervisor.
actor.new_with_initialiser(1000, fn(subject) {
  let _attachment = sinal.observe(telemetry.job_set_aside(), alert)
  actor.initialised(Nil) |> actor.returning(subject) |> Ok
})
```

`sinal.detach` now returns `Error(Nil)` for an attachment that is already
gone: detached before, removed after a failure, or released because its owner
exited. Treat it as "already gone". Sinal's diagnostics are counted rather than
logged on every occurrence; read them with `sinal.diagnostics()`. See Sinal's
[migration guide](https://github.com/gleam-dream/sinal/blob/main/docs/MIGRATION.md).

### The core range accepts 0.2

`decisions_otp` accepts `decisions` below 0.3.0, so it runs with core 0.2.0. The stress suite (`decisions_otp/stress`) attaches its own handler
from the process that runs the scenario, which waits for it, so it is
unaffected.

## decisions_postgres 0.3.0

### A handler belongs to the process that attached it

As for `decisions_otp`: the package depends on `sinal >= 0.2.0 and < 0.3.0`,
and a handler on `decisions_postgres/telemetry` events must be attached from a
long-lived supervised process.

### Grind 0.3 and its schema version 15

The package depends on `grind >= 0.3.0 and < 0.4.0`, because Grind 0.3 is the
release on Sinal 0.2. `decisions_postgres.new` takes Grind 0.3's `Grind`.

```toml
# Before
grind = ">= 0.2.0 and < 0.3.0"

# After
grind = ">= 0.3.0 and < 0.4.0"
```

Apply Grind's schema version 15 before starting a 0.3 node that runs the wake-up
and settlement workers: a Grind 0.3 runtime with consumers refuses a schema
below 15. Version 15 builds an index with `CREATE INDEX CONCURRENTLY`, so run
`grind.migrate` (or Grind's two mirrored files) outside a transaction and
through a session-mode connection. Grind's
[migration guide](https://github.com/gleam-dream/grind/blob/main/docs/MIGRATION.md)
gives the rolling-upgrade order. This package's own tables do not change.

The workers keep `ReplayAfterLeaseExpiry(10)`, so Grind 0.3 still replays a
delivery whose handler crashed through lease-expiry recovery, and the
package's settlement of an abandoned delivery is unchanged. Two Grind 0.3
changes are visible: a delivery that loses its lease is stopped at Grind's next
lease renewal instead of running to its timeout, and Grind claims into every
free slot with one statement.

### The core range accepts 0.2

`decisions_postgres` accepts `decisions` below 0.3.0, so it runs with core
0.2.0.
