# Migrating to the next release

These changes are on `main` and not released yet. They break the API of the
released `decisions` 0.2.0, so the next core release is 0.3.0.

## decisions

### A bundle item holds no slash

A bundle member's item is a `vocabulary.Item`, built with
`vocabulary.item(name:)`, which refuses an empty name (`NoItemName`) and a name
with a slash (`SlashInItem`). In 0.2 an item was free text, so bundle `a` with
item `b/c` and bundle `a/b` with item `c` named the same key, `a/b/c`, and the
second was refused as `BadBundle(KeyOutsideBundle)`, `Poisoned`. Member ids keep
their form: the bundle's key, a slash and the item.

```gleam
// Before (0.2)
decisions.recommend_member(desk, tx, of: bundle, item: "l1", proposal:)
decisions.recommend_bundle(desk, tx, bundle: "report-7",
  items: [#("l1", line_1), #("l2", line_2)])
decisions.member_key(bundle, "l1")

// After
let assert Ok(l1) = vocabulary.item(name: "l1")
let assert Ok(l2) = vocabulary.item(name: "l2")
decisions.recommend_member(desk, tx, of: bundle, item: l1, proposal:)
decisions.recommend_bundle(desk, tx, bundle: "report-7",
  items: [#(l1, line_1), #(l2, line_2)])
decisions.member_key(bundle, l1)
```

Where item names come from data, build the `Item` where the data enters and
refuse a name `item` refuses there. An application that escaped slashes in its
item names no longer needs to.

### A tool can say it was contended

`vocabulary.Stop` has a third case, `Contended(detail)`: the guard, the release
check or the executor wrote nothing and may be sent again at once, because a
lock of its own waited too long or a verb it ran was contended. The verb fails
with `StoreFailed(store.Contended(detail))`, which a runtime delivers again
uncounted and `decisions_postgres` reports as `Contended`. In 0.2 a tool could
only answer `Unsure`, so the verb failed with `ToolUnsure`, counted toward
setting the job aside, and was described as a tool that could not tell.

`decisions.stop_for(refusal)` maps a nested verb's refusal, or a store error of
the tool's own (`StoreFailed(error)`), to a `Stop`: contention stays
`Contended`, another `Transient` or `Retry` refusal is `Unsure`, and a
`Poisoned` or `Final` one is `Refuse`.

```gleam
// Before (0.2)
decisions.inform(payouts, tx, occurrence: id, from: "risk", facts:)
|> result.map_error(fn(refusal) {
  case decisions.disposition(refusal) {
    decisions.Transient | decisions.Retry ->
      vocabulary.Unsure(decisions.describe(refusal))
    decisions.Poisoned | decisions.Final ->
      vocabulary.Refuse(decisions.describe(refusal))
  }
})
store.lock(tx, "party:" <> id)
|> result.map_error(fn(error) { vocabulary.Unsure(store.describe(error)) })

// After
decisions.inform(payouts, tx, occurrence: id, from: "risk", facts:)
|> result.map_error(decisions.stop_for)
store.lock(tx, "party:" <> id)
|> result.map_error(fn(error) { decisions.stop_for(decisions.StoreFailed(error)) })
```

A `case` over `Stop` adds the `Contended` branch.

## decisions_postgres

### A worker's settlement can run verbs in Grind's transaction

`decisions_postgres.with_settlement(worker, settle)` is
`worker.with_settlement` for an application's worker whose settlement runs
verbs: `settle` receives Grind's settlement transaction as a `Tx`. In 0.3 a
`Tx` could only be opened on the pool, so such a settlement ran its verbs in a
second transaction, which committed even when Grind rolled its own decision
back and tried again. Nothing changes for code that does not use it.

```gleam
// Before (0.3): two transactions.
|> worker.with_settlement(fn(_transaction, job) {
  use _ <- result.try(
    decisions_postgres.transaction(pool, decisions.report(desk, _,
      occurrence: abandoned.input(job), effect: Uncertain("abandoned")))
    |> result.map_error(decisions_postgres.describe),
  )
  Ok(worker.ConfirmFailure("abandoned"))
})

// After: one.
|> decisions_postgres.with_settlement(fn(tx, job) {
  use _ <- result.try(
    decisions.report(desk, tx,
      occurrence: abandoned.input(job), effect: Uncertain("abandoned"))
    |> result.map_error(decisions.describe),
  )
  Ok(worker.ConfirmFailure("abandoned"))
})
```

# Migrating to decisions 0.2

decisions 0.2.0, decisions_otp 0.2.0 and decisions_postgres 0.3.0 are breaking
releases. They move the three packages onto json_blueprint 3, Sinal 0.2 and
Grind 0.3, which are breaking releases themselves. The public API of each
package exposes types of those libraries (`json_blueprint`'s `Codec` in
`decisions/wire` and `decisions/view`, Sinal's `Event` in both `telemetry`
modules, Grind's `Grind` in `decisions_postgres.new`), so an application must
move to the same majors.

| Package              | From  | To    | What changes for the application                                                                                                                                 |
| -------------------- | ----- | ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `decisions`          | 0.1.1 | 0.2.0 | json_blueprint 3; card documents encode outputs of any depth and size; a policy's default asks a person; a verb on `decisions/memory` runs only in a transaction |
| `decisions_otp`      | 0.1.1 | 0.2.0 | Sinal 0.2: a handler belongs to the process that attached it; a verb runs only in a transaction; ids are UUIDs; accepts core 0.2                                 |
| `decisions_postgres` | 0.2.1 | 0.3.0 | Sinal 0.2 as above; Grind 0.3 and its schema version 15; a verb runs only in a transaction; accepts core 0.2                                                     |

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

`view.verdict` and `wire.parse` now read through json_blueprint too; see below.

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

### Each fact has one source: signals, answers and output facts

A point declares a consulted point's answer with `decisions.answer`, apart
from the model's signals. In 0.1 both were declared with `signal` and read
from one list, so a model's signal with the answer's name stood in for the
consulted point and could skip the consult.

```gleam
// Before (0.1)
decisions.point("billing.payment", codec) |> decisions.signal(cleared)

// After (0.2)
decisions.point("billing.payment", codec)
|> decisions.answer(cleared, from: "compliance")
```

- `recommend` refuses a recommendation whose signals hold a fact not declared
  with `signal`, or of another type, with `InvalidFacts` (`Poisoned`). Declare
  every signal the model sends.
- `inform` accepts a fact only when it is declared as an answer from the
  point that informs.
- Declaring a name again, with `fact`, `signal` or `answer`, replaces its
  earlier declaration.
- `decisions.facts_of(point, output)` is replaced by
  `decisions.policy_facts(point, recommendation, informed:)`, which reads each
  fact from its declared source only.

### A client's verdict is read strictly, and outputs stay exact

`view.verdict` and `wire.parse` read a client's text through json_blueprint
within `value.default_limits()`: more than 1 MiB or 128 levels is refused, a
key given twice is refused, and numbers are exact. In 0.1 they used
`gleam/json`, which kept one of two repeated keys and rounded a correction such
as `12345678901234567.89` to a float.

An output is also stored exactly. A recommendation, a verdict or an assessment
is written as a json_blueprint `Value`, so a point whose codec uses exact
numbers keeps them through the store and the release.

```gleam
// Before (0.1)
let assert Ok(verdict) = view.verdict(text, codec)   // Error: json.DecodeError
let assert Ok(body) = view.verdict_to_json(verdict, codec)
json.to_string(body)

// After (0.2)
let assert Ok(verdict) = view.verdict(text, codec)   // Error: codec.DecodeError
let assert Ok(text) = view.verdict_to_json(verdict, codec)
```

- `view.verdict` and `wire.parse` return json_blueprint's `codec.DecodeError`.
- `view.verdict_to_json` and `learning.example_to_json` return JSON text.
- `wire.encode`, `wire.recommendation`, `wire.verdict` and `wire.assessment`
  return a json_blueprint `Value`; write it with `value.to_string`.
- `wire.decoder`, `wire.verdict_decoder`, `wire.recommendation_decoder` and
  `wire.assessment_decoder` are removed. Read a `Value` with `wire.decode`,
  `wire.decode_verdict`, `wire.decode_recommendation` and
  `wire.decode_assessment`, or use `wire.verdict_codec` with json_blueprint.
- Records stored by 0.1 decode unchanged.

### A bundle member is admitted under its bundle's lock and key

Admitting a member of a bundle now holds the bundle's lock, so members
admitted by concurrent transactions never exceed its size. In 0.1 two
transactions could each see room and both commit, and the bundle then never
completed. A member's key is scoped by its bundle, so a member delivered again
is found.

```gleam
// Before (0.1)
let bundle = vocabulary.Bundle(key: "report-8", size: 2)
decisions.recommend_once(desk, tx, key: "report-8/l1",
  proposal: proposal |> decisions.in_bundle(bundle))
decisions.recommend_bundle(desk, tx, bundle: "report-7",
  items: [#("report-7/l1", line_1), #("report-7/l2", line_2)])

// After (0.2)
let assert Ok(bundle) = vocabulary.bundle(key: "report-8", size: 2)
decisions.recommend_member(desk, tx, of: bundle, item: "l1", proposal:)
decisions.recommend_bundle(desk, tx, bundle: "report-7",
  items: [#("l1", line_1), #("l2", line_2)])
```

- `vocabulary.Bundle` is opaque: build it with `vocabulary.bundle`, which
  refuses an empty key or a size below one, and read it with `bundle_key` and
  `bundle_size`.
- `decisions.in_bundle` is removed; `recommend` and `recommend_once` admit no
  bundle member. The member's key is `decisions.member_key(bundle, item)`;
  expect it or record its failed attempts under that key.
- `BundleFault` loses `NoBundleKey` and `EmptyBundle`, which are now
  `vocabulary.MalformedBundle` (carried by `Malformed` from
  `recommend_bundle`), and `RepeatedItem` names the item.
- `bundle_lock_prefix` is reserved, as `subject_lock_prefix` is.

### A tool answers `vocabulary.Stop`, and the port passes it back typed

`Stop`, with `Refuse` and `Unsure`, moves to `decisions/vocabulary`, and the
port's `atomically` carries it typed. In 0.1 the desk sent it to the port as
prefixed text and parsed it back, so an adapter that changed the text turned
`Unsure` into a refusal for good.

```gleam
// Before (0.1)
Error(decisions.Refuse("refunds go to companies"))
atomically: fn(tx, body: fn(Tx) -> Result(List(Ref), String)) { .. }

// After (0.2)
Error(vocabulary.Refuse("refunds go to companies"))
atomically: fn(tx, body: fn(Tx) -> Result(List(Ref), vocabulary.Stop)) { .. }
```

### A card opened again is the same showing

`open` returns the validator's latest showing, with the same ticket and no new
entry, when nothing but showings was recorded after it and the inputs drifted
no further. A released, sampled occurrence opens only to someone `review`
admits; anyone else gets `NotEligible`. A model's raise is recorded with a
reason of at most 1 024 bytes (`model.max_reason_bytes`).

### The conformance suite runs every check in a transaction

`decisions/conformance.Adapter` has no `handle`: no port call runs outside a
transaction. `transaction` returns what its body returned, so the checks pass
a value such as a new id out of it. An adapter's `transaction` that wraps a
generic transaction function compiles unchanged once the field is gone.

```gleam
// Before (0.1)
conformance.Adapter(port:, inspect:, handle: store,
  transaction: fn(body) { memory.transaction(store, body) }, cleanup:)

// After (0.2)
conformance.Adapter(port:, inspect:,
  transaction: fn(body) { memory.transaction(store, body) }, cleanup:)
```

### A verb on the in-memory store runs only in a transaction

`decisions/memory` has a transaction type, `memory.Tx`, which only
`memory.transaction` makes. In 0.1 the `Memory` was also the port's
transaction value, so a verb called on it outside `transaction` kept whatever
it wrote before it failed: a release that ran the tool and appended its
entries, then failed on the settlement notice, left the record and the effect
behind. Now `memory.port()`, `memory.inspection()` and `memory.evidence()` are
over `Tx`, and so are a desk, a gated tool and an audit built on them.

```gleam
// Before (0.1)
let desk: Desk(Refund, Memory) = decisions.desk(point, .., over: memory.port())
decisions.read(desk, store, occurrence: id)
memory.put(store, "account", "open")
memory.get(store, "account")
testing.check(store, memory.inspection(), audits)

// After (0.2)
let desk: Desk(Refund, Tx) = decisions.desk(point, .., over: memory.port())
memory.transaction(store, decisions.read(desk, _, occurrence: id))
memory.transaction(store, fn(tx) { Ok(memory.put(tx, "account", "open")) })
memory.transaction(store, memory.get(_, "account"))
memory.transaction(store, testing.check(_, memory.inspection(), audits))
```

- The reads a test makes outside a verb take the `Memory`: `queue`,
  `queue_for`, `review_queue`, `entries`, `heads`, `wakes`, `notices` and the
  clock's `now`. The test controls `set_clock`, `advance`, `take_due`,
  `snooze`, `tamper` and `restart` take it too.
- Application rows (`get`, `put`) stay on `Tx`, as in `decisions_otp`: a gated
  tool reads and writes them in the transaction that releases it. Inside a
  tool, read the clock through the port, `memory.port().now(tx)`.
- `model.capture(memory.evidence(), ..)` takes a `Tx`: capture a read in a
  transaction of its own, `memory.transaction(store, model.capture(memory.evidence(), _, ..))`.

### The store's clock can fail, and a lock timeout is a `LockTimeout`

The port's `now` returns `Result(Timestamp, StoreError)`; the desk turns its
error into `StoreFailed`. In 0.1 an adapter that could not read its clock had to
make up a time. `store.LockTimeout` is the longest a transaction waits for an
occurrence's lock, a whole number of milliseconds of at least one, built with
`store.lock_timeout(milliseconds:)`; `store.default_lock_timeout` is 4 seconds.

```gleam
// Before (0.1)
now: fn(tx) { read_clock(tx) },

// After (0.2)
now: fn(tx) { Ok(read_clock(tx)) },
let assert Ok(timeout) = store.lock_timeout(milliseconds: 250)
```

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

### A verb runs only in a transaction

`store.handle` and `store.store_of` are removed. A verb run on the handle took
its lock, ran the gated tool and recorded the release in three separate
commits, so racing processes could each release the same occurrence. Only
`store.transaction` makes a `Tx`, and it takes the `Store`, never a `Tx`.

```gleam
// Before (0.1)
decisions.read(desk, store.handle(s), occurrence: id)
store.queue(store.handle(s), "finance")
store.get(store.handle(s), "accounts", "ana")

// After (0.2)
store.transaction(s, decisions.read(desk, _, occurrence: id))
store.queue(s, "finance")
store.transaction(s, fn(tx) { Ok(store.get(tx, "accounts", "ana")) })
```

- The reads `queue`, `queue_page`, `queue_for`, `queue_page_for`,
  `review_queue`, `review_queue_of`, `occurrences_of`, `settled_since`,
  `entries`, `heads`, `wakes` and `notices` take the `Store` and see committed
  rows.
- Application rows (`get`, `put`, `add`, `remove`, `rows`, `count`) and
  `inspection` stay on `Tx`.
- `decisions_otp/stress.Target` keeps its fields; `stress.transaction(target,
body)` runs a body in one of the target's transactions and returns its
  value.

### Occurrence ids are UUIDs

A new occurrence id (`recommend`, `expect` with a fresh id, the port's
`new_id`) is a UUID version 7 made on the node, as in `decisions_postgres`. In
0.1 it was `occ-` and a counter of the store's owner, which started again at 1
when a supervised owner restarted empty, so an external effect keyed by an
occurrence's id could meet an earlier occurrence's key. Code that parsed the
`occ-` form, or expected ids in counter order, reads them as opaque text;
ids made later still sort later.

### A lock timeout is a `LockTimeout`

`store.Config.lock_timeout` is a `decisions/store.LockTimeout`, at least one
millisecond, instead of a `Duration`; a zero or negative duration, which 0.1
clamped to "refuse at once", cannot be built. `store.defaults()` waits 4
seconds (`decisions/store.default_lock_timeout`) instead of 5.

```gleam
// Before (0.1)
store.Config(..store.defaults(), lock_timeout: duration.milliseconds(50))

// After (0.2)
let assert Ok(lock_timeout) = port_types.lock_timeout(milliseconds: 50)
store.Config(..store.defaults(), lock_timeout:)
```

### An isolated model has a heap limit

`isolated.model` takes `heap:`, an `isolated.HeapLimit` of whole megabytes and
at least one. A model whose heap passes it is killed at once and its call is
`model.Raised`. In 0.1 a model could allocate without bound within its
deadline.

```gleam
// Before (0.1)
isolated.model(classifier, within: duration.seconds(5))

// After (0.2)
let assert Ok(heap) = isolated.heap_limit(megabytes: 256)
isolated.model(classifier, within: duration.seconds(5), heap:)
```

### A wake-up whose record cannot be acted on sets its occurrence aside

`backlog.Backlog` has `set_aside_occurrence(tx, occurrence, reason)`. The
runtime calls it, beside `set_aside`, when a wake-up's record cannot be acted
on: the occurrence leaves every queue and `waiting`, and its other wake-ups are
set aside. An implementation of `Backlog` other than the in-memory store's adds
it.

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
gives the rolling-upgrade order. This package's own schema changes too; see
the next section.

The workers keep `ReplayAfterLeaseExpiry(10)`, so Grind 0.3 still replays a
delivery whose handler crashed through lease-expiry recovery, and the
package's settlement of an abandoned delivery is unchanged. Two Grind 0.3
changes are visible: a delivery that loses its lease is stopped at Grind's next
lease renewal instead of running to its timeout, and Grind claims into every
free slot with one statement.

### The package's migration 2 keeps a head's bundle

Apply the package's migration 2 (`priv/migrations/20261127000000-decisions_postgres_v2.sql`)
before a 0.3 node writes. It adds `bundle_key` and `bundle_size` to
`decisions_occurrences`, an index on them, and the `decisions_append` function
0.3 calls with a record's bundle. A database at migration 1 refuses every append
from 0.3, because migration 1 defines only the 15-argument `decisions_append`. Run `migrate(db)`, or
apply the file with the application's tool, as for migration 1. The index is
built with a plain `CREATE INDEX`, which blocks writes to `decisions_occurrences`
while it builds.

### A verb runs only in a transaction the package opened

The port's transaction value is `decisions_postgres.Tx`, which only the
transaction helpers and the workers make. A verb run on the pool took its
lock, ran the gated tool and recorded the release in separate commits, so
racing processes each released the same occurrence. The helpers take a
`Pool`, made from the pool's name, so a helper handed a transaction's
connection can no longer commit that transaction early.

```gleam
// Before (0.2)
let db = grind.connection(jobs)
decisions_postgres.transaction(db, decisions.recommend(desk, _, proposal))
decisions.read(desk, db, occurrence: id)
pog.transaction(db, fn(tx) {
  use waiting <- result.try(decisions.recommend(desk, tx, proposal))
  save_request(tx, waiting.id)
})

// After (0.3)
let db = decisions_postgres.pool(pool_config.pool_name)
decisions_postgres.transaction(db, decisions.recommend(desk, _, proposal))
decisions_postgres.transaction(db, decisions.read(desk, _, occurrence: id))
decisions_postgres.transaction_with(db, fn(tx) {
  use waiting <- result.try(
    decisions.recommend(desk, tx, proposal) |> decisions_postgres.desk,
  )
  save_request(decisions_postgres.connection(tx), waiting.id)
  |> result.map_error(decisions_postgres.Own)
})
```

- `transaction`, `transaction_with`, `refusing`, `decide`, `migrate`,
  `sweep`, `deliver_due`, `deliver_notices`, `set_aside` and every
  `decisions_postgres/queue` read take the `Pool`.
- `port(store)` is `Port(Tx)` and `inspection()` is `Inspection(Tx)`. A gated
  tool's executor, a `Waker` and a `Follower` receive a `Tx`; run their own
  statements, and `grind.submit_in`, on `connection(tx)`.
- A verb inside the application's own `pog.transaction` no longer compiles;
  move the body into `transaction_with`.

### A lock timeout is a `LockTimeout`, and more failures are contention

`with_lock_timeout` takes an `Option(decisions/store.LockTimeout)`, at least
one millisecond. In 0.2 a duration under one millisecond was sent as `0ms`,
which PostgreSQL reads as "wait for ever", and a negative one made every
`load` fail.

```gleam
// Before (0.2)
decisions_postgres.with_lock_timeout(store, Some(duration.milliseconds(250)))

// After (0.3)
let assert Ok(timeout) = store.lock_timeout(milliseconds: 250)
decisions_postgres.with_lock_timeout(store, Some(timeout))
```

- A statement the server cancelled (`57014`), a statement in a transaction an
  earlier statement aborted (`25P02`) and a pool with no connection to give are
  `Contended`, not `Unavailable`: nothing was written. A caller that retried
  only `Contended` now retries these too.
- The port's `now` returns the clock query's error instead of the node's clock.
- A settlement delivery that finds its notice held by another delivery snoozes
  instead of waiting for it, and the sweep skips such a notice.

### The core range accepts 0.2

`decisions_postgres` accepts `decisions` below 0.3.0, so it runs with core
0.2.0.
