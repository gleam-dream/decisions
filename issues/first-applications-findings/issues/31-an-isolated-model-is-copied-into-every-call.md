# An isolated model is copied into every call, with everything it captures

Status: needs-triage
Category: enhancement

AI-assisted contribution.

**Parent:** [What the first applications still found](../PRD.md). Design anchors: ADR 0056; the runtime context's isolated model calls and parallel replay.

## Behaviour wanted

`isolated.model(inner, within:)` runs a model in a process of its own for each call, and `replay.replay(examples, candidate, ..)` runs the candidate in a process of its own for each share of the examples. Both start the process with a closure that captures the user's `Model`, so the model, and every value its function captures, is copied into the new process on every call or share. A copy between processes does not keep sharing.

A model often captures a json_blueprint codec: the point's output codec, or the codec of a structured answer from an LLM provider. Each isolated call then copies that codec. A consumer service was killed for running out of memory when codecs held in its desks were copied several times per Grind job (ADR 0056), so the same pattern on every model call is a risk worth removing.

An application should be able to hand `decisions_otp` a model that is built inside the spawned process: for example a builder, `fn() -> Model(output)`, that the new process calls, so that only the builder's own captures are copied. Whether that is a new function beside `isolated.model` and `replay.replay`, or a change to them, is open.

## Evidence

- `integrations/decisions_otp/src/decisions_otp/isolated.gleam:75`: `call` starts `process.spawn_unlinked(fn() { .. model.run(inner, context, sources) .. })`, which captures `inner` on every call.
- `integrations/decisions_otp/src/decisions_otp/replay.gleam:45`: `replay` passes `map` a closure that captures `candidate`; `start` at `replay.gleam:142` spawns one process per share with that closure.
- Measured with json_blueprint 2.1.1 (`erts_debug:flat_size` times the word size, the bytes a send copies): a `model.new` whose function captures `wire.codec` over the nested output of `test/codec_copy_size_test.gleam` copies 1 720 bytes; the json_blueprint codec alone copies 1 640. The cost of each call grows with whatever else the model captures.
- Until this is built, the docs of `isolated.model` and `replay.replay`, and the README section "A point's codec, and what copying it costs", tell consumers to keep a model small and build heavy values inside its function.

## Done when

- An application can run an isolated model, and a replay, whose heavy values are built inside the spawned process, so that a call copies only what the application chose to capture.
- A test bounds the bytes copied into the model's process for a model that would otherwise capture a codec.
- The README section and ADR 0056 point to the new way.
