# A client's verdict is read strictly, and outputs stay exact through the store

<a id="adr-0061"></a>

Recorded on 2026-11-27.

## Decision

- `view.verdict` and `wire.parse`, the entry points for JSON text a client sends, read through json_blueprint with `value.default_limits()` (1 MiB, 128 levels deep). A key given twice is refused, and numbers are read exactly. They return json_blueprint's `DecodeError`.
- A value that holds an output (a recommendation, a verdict, an assessment) is written and read as a json_blueprint `Value`: `wire.recommendation`, `wire.verdict`, `wire.assessment` and `wire.encode` return a `Value`, and `wire.decode_recommendation`, `wire.decode_verdict`, `wire.decode_assessment` and `wire.decode` read one. `wire.verdict_codec` is the verdict as a json_blueprint codec. The `gleam/dynamic` decoders `wire.decoder`, `wire.verdict_decoder`, `wire.recommendation_decoder` and `wire.assessment_decoder` are removed.
- A stored entry that holds an output is written as the `Value`'s text and read by parsing it exactly, so the output's numbers survive the store, `decisions.read`, the release and `learning.example_to_json`, which now returns text. The members that hold no output keep their `gleam/json` forms. The refused verdict carried by a `Rollback` is the same exact text.
- The core's own text, which it wrote and stored, is parsed without limits, as before.

## Why

- `view.verdict` used `gleam/json`, whose parser keeps one of two repeated keys, reads numbers as floats, and has no byte bound. `{"t":"reject","reason":{...},"t":"approve"}` decoded as a rejection, so an approval gateway or audit log that read the other duplicate saw a different verdict than the one recorded. A validator's correction of `12345678901234567.89` became `1.2345678901234568e16` before it was recorded and released. A person's correction is the most authoritative value in the system, and it was changed without notice.
- The store path had the same loss: an output passed through `gleam/json` `Json`, which cannot hold a number beyond a float's precision, so recommending such a number was refused as `Unencodable`. Exactness at the client boundary alone would have turned the silent rounding into a refusal at `decide`.

## Alternatives

- **Strict parsing at the boundary only, keeping `gleam/json` in the store.** Rejected for the reason above: the correction would be read exactly and then refused, or rounded, one step later.
- **Every stored entry as a json_blueprint codec.** Rejected for now: the entries that hold no output gain nothing, and their stored bytes would change for no reason.

## What changes for consumers

- `decisions` 0.2.0: `view.verdict` returns `Result(Verdict(o), codec.DecodeError)`; `view.verdict_to_json` and `learning.example_to_json` return JSON text. `wire.parse` is strict and bounded and returns `codec.DecodeError`. `wire.encode` returns a `Value`; write it with `value.to_string`. The removed `wire` decoders are replaced by the `decode_*` functions over a `Value`.
