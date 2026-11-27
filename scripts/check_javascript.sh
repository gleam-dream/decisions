#!/usr/bin/env bash
# Checks that the core builds for JavaScript. A throwaway package under
# build/javascript-check depends on the root by path, imports every public
# module of decisions, and is built with `--target javascript` and warnings
# treated as errors. When Node.js is on PATH, it also runs a scenario on the
# JavaScript target: a json_blueprint codec, recommend, open, decide and
# release, the card document with its schema, a model that raises, a read
# made after the model returned, replay, the invariant checker, and the
# whole conformance suite (which includes a savepoint whose body raises).
#
# Every public module of decisions is target-independent; `decisions/model`
# and `decisions/memory` carry a small .mjs beside their .erl.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/build/javascript-check"

rm -rf "$CHECK"
mkdir -p "$CHECK/src"

cat >"$CHECK/gleam.toml" <<TOML
name = "decisions_javascript_check"
version = "0.0.0"
target = "javascript"

[dependencies]
gleam_stdlib = ">= 0.70.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
gleam_time = ">= 1.11.0 and < 2.0.0"
json_blueprint = ">= 3.0.0 and < 4.0.0"
decisions = { path = "$ROOT" }
TOML

cat >"$CHECK/src/decisions_javascript_check.gleam" <<'GLEAM'
import decisions
import decisions/conformance
import decisions/entry
import decisions/fact
import decisions/learning
import decisions/memory
import decisions/model
import decisions/occurrence
import decisions/policy
import decisions/store
import decisions/testing
import decisions/view
import decisions/vocabulary
import decisions/wire
import gleam/io
import gleam/json
import gleam/result
import gleam/string
import json/blueprint/codec

pub type Reply {
  Reply(text: String, urgent: Bool)
}

fn reply_codec() -> wire.Codec(Reply) {
  wire.codec({
    use text <- codec.field("text", codec.string(), get: fn(r: Reply) { r.text })
    use urgent <- codec.field("urgent", codec.bool(), get: fn(r: Reply) { r.urgent })
    codec.success(Reply(text:, urgent:))
  })
}

pub fn main() -> Nil {
  let store = memory.new()
  let point = decisions.point("check.reply", reply_codec())
  let desk =
    decisions.desk(
      point,
      drives: fn(_) {
        decisions.Gated(name: "send", guard: fn(_, _) { Ok([]) }, execute: fn(tx, released) {
          let reply: Reply = decisions.output(released)
          memory.put(tx, "sent", reply.text)
          Ok(Nil)
        })
      },
      under: fn(_) {
        policy.new(version: 1, rules: [], otherwise: policy.AnyoneHolding("ops"))
        |> result.replace_error("the policy is malformed")
      },
      over: memory.port(),
    )
  let context = vocabulary.Manifest(refs: [vocabulary.Ref("message", "m1", "1")], renderer: "r")
  let sources =
    model.Sources(
      resolve: fn(_) { Ok("olá") },
      read: fn(name, argument) { Ok(model.Captured(vocabulary.Ref(name, argument, "1"), "balance")) },
    )
  let echo_model =
    model.new(fn(context: vocabulary.Manifest, sources: model.Sources) {
      let assert [ref] = context.refs
      use text <- result.map(sources.resolve(ref))
      vocabulary.Recommendation(Reply(text, False), vocabulary.Rules("echo", "1"), vocabulary.RuleFired("echo"), [fact.set(fact.number("score"), 1.0)], [])
    })
  let assert Ok(recommendation) = model.run(echo_model, context, sources)
  let assert Error(model.Raised(_)) =
    model.run(model.new(fn(_, _) { panic as "raised on purpose" }), context, sources)
  // A model that hands its read function out; reading after it returned
  // answers and is not recorded.
  let assert Ok(leaked) =
    model.run(
      model.new(fn(_, sources: model.Sources) {
        Ok(vocabulary.Recommendation(sources.read, vocabulary.Rules("leak", "1"), vocabulary.RuleFired("r"), [], []))
      }),
      context,
      sources,
    )
  let assert [] = leaked.reads
  let assert Ok(model.Captured(body: "balance", ..)) = leaked.output("balance", "late")
  let assert Ok(waiting) =
    memory.transaction(store, decisions.recommend(
      desk,
      _,
      decisions.proposal(trigger: vocabulary.Trigger("message", "m1"), about: vocabulary.Subject("person", "ana"), context:, recommending: recommendation),
    ))
  let assert Ok(released) =
    memory.transaction(store, fn(tx) {
      use card <- result.try(decisions.open(desk, tx, occurrence: waiting.id, by: vocabulary.Validator("bia", ["ops"]), latest: fn(r) { r.revision }))
      let assert Ok(document) = view.of(card, content: fn(_) { Ok("olá") }) |> view.to_json(reply_codec())
      let assert True = string.contains(json.to_string(document), "\"output_schema\":{")
      decisions.decide(desk, tx, card, vocabulary.Approve)
    })
  let assert occurrence.Released(final: Reply("olá", False), ..) = released.status
  let assert Ok("olá") = memory.get(store, "sent")
  let assert Ok(example) =
    learning.example(released, as_of: memory.now(store), from: learning.Archive(render: fn(_) { Ok("r") }, reads: fn(_) { [] }, content: fn(_) { Ok("olá") }))
  let assert learning.Replay(tally: learning.Tally(agreed: 1, judged: 1, ..), unanswered: []) =
    learning.replay([example], echo_model, same: fn(a, b) { a == b })
  let assert Ok(_) = testing.check(store, memory.inspection(), [testing.audit_record(desk)])
  let assert Ok(Nil) =
    conformance.run(fn() {
      let db = memory.new()
      Ok(conformance.Adapter(port: memory.port(), inspect: memory.inspection(), handle: db, transaction: fn(body) { memory.transaction(db, body) }, cleanup: fn() { Nil }))
    })
  let _ = entry.kinds
  let _ = store.describe(store.Unavailable("x"))
  let _ = view.ticket_decoder()
  io.println("javascript scenario passed: " <> string.inspect(occurrence.status_name(released.status)))
}
GLEAM

cd "$CHECK"
gleam build --target javascript --warnings-as-errors
if command -v node >/dev/null 2>&1; then
  gleam run --target javascript
else
  echo "SKIP: node is not on PATH; the JavaScript build passed and was not run"
fi
