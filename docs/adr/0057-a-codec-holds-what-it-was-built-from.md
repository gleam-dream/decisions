# A codec holds what it was built from, because it is copied with its point

<a id="adr-0057"></a>

Recorded on 2026-11-19. Amends nothing; the public API of `decisions/wire` and `decisions/view` is unchanged. It ships in core 0.1.1. The released integrations accept `decisions >= 0.1.0 and < 0.2.0`, so an application gets it by resolving core 0.1.1 (`gleam deps update decisions`), with no integration release; the integrations' own releases then raise their floor to 0.1.1.

## Decision

- Every package requires `json_blueprint >= 2.1.1`. Before 2.1.1 a copy of a combinator codec to another process multiplied in size at each nesting layer, because a copy does not keep sharing; from 2.1.1 each layer adds a roughly fixed amount. The integrations depend on the published core, whose range still admits 2.0.0, so each lists `json_blueprint` as a floor even though it does not import it.
- `wire.Codec` holds only what it was built from: the json_blueprint codec for `wire.codec`, or the encoder and the decoder for `wire.plain`. `encode`, `decoder`, `schema` and `blueprint` derive what they return each time they are called. Before, a codec held the json_blueprint codec, an encode closure over it, `blueprint.decoder(it)` (a second closure over it) and the rendered schema.
- `view.codec(output)` binds nothing before its fields. The output's schema is rendered inside the `output_schema` field when a document is encoded, not parsed once and captured by the fields after it. The point's codec is the only value from outside the document that its fields capture.
- `test/codec_copy_size_test.gleam` holds both, measured as `erts_debug:flat_size` times the word size, the bytes a send copies: a point's codec copies at most 64 bytes more than its json_blueprint codec, a desk's waker (the term a Grind job's closure holds) at most 1 024 bytes more, and the card codec over a nested output stays under 24 000 bytes.
- No generated codecs in this change. The core's envelopes need none, and the card document cannot have one; see the assessment below.

## Assessment: generated codecs

The json_blueprint guide recommends a generated codec when the shape is fixed and the codec is hot, long-lived or held by other processes. For each shape in decisions:

- **Entries and the wire helpers** (`decisions/entry`, the encoders and decoders in `decisions/wire`): these are `gleam/json` encoders and `gleam/dynamic/decode` decoders that top-level functions build per call. No process holds them, so they cost nothing to copy, and generating them would change nothing about copying. They are hot when a store decodes a record, but a measured decode cost would be a separate question.
- **The card document** (`view.codec`): its fixed fields (refs, subject, items, approvals, verdicts) are built inside their fields by top-level functions, so the card codec does not multiply them. Its output fields are the point's own type, which only the application knows. json_blueprint's generator compiles a definition of concrete shapes into a module, so it cannot generate a document over any output. Generating only the fixed parts would shrink the card codec's base, about 4.4 kB, and nothing else.
- **A point's output codec**: this is where the size is, and it belongs to the application. json_blueprint's record codec keeps its first field's continuation in about a dozen callbacks, so a copy of `view.codec(output)` holds about twelve copies of the point's codec, the only value that continuation captures. A generated codec for a fixed output keeps those copies small.
- **A model**: `decisions_otp`'s `isolated.model` runs the application's `Model` in a new process for each call, and `replay.replay` in a new process for each share, so the model and every heap term its function captures, such as a codec for a structured answer, is copied each time; a binary larger than 64 bytes is reference-counted, and only a reference to it is copied. The docs of both functions and the README tell consumers to keep a model small and build heavy values inside its function. Building the model inside the spawned process is tracker issue 31 of `issues/first-applications-findings`.

Revisit when json_blueprint holds a record's continuation once ([json_blueprint issue: hold a record continuation once](https://github.com/lostbean/json_blueprint/blob/main/issues/record-copy-cost/issues/01-hold-a-record-continuation-once.md)): that removes the remaining twelvefold copy in `view.codec`. Revisit also if an application holds a card codec in long-lived or shared state and measures it large.

## What changes for consumers

- Nothing in the API, the stored text or the card document: schemas, documents, decoding results, error texts and placeholders are byte for byte the same.
- From core 0.1.1, a point built with `wire.codec` copies about as much as its json_blueprint codec: 1 664 bytes instead of 13 776 for the nested output in the test. A desk carried in a Grind job's closure, or held in actor state, is then copied with that much less. An application that uses the integrations gets it as soon as it resolves core 0.1.1, because the released integrations accept `decisions >= 0.1.0 and < 0.2.0`; their next releases require 0.1.1.
- `wire.schema` and `wire.decoder` build their result on each call. Code that calls them in a loop can keep the result for the loop's length.
- Applications on `json_blueprint < 2.1.1` must upgrade; the new floor requires it.

## Rationale and alternatives

- A consumer service was killed for running out of memory when json_blueprint 2.1.0 codecs, held in points in desks that travel with every Grind job's `run` closure, were copied about three times per job and multiplied at each copy. json_blueprint 2.1.1 fixed its combinators. A study of the codecs' consumers then measured `wire.Codec` at 38 kB copied against 8.4 kB for the json_blueprint codec it held, and `view.codec` over a nested output at 542 kB copied against 18 kB in one process's heap.
- Keeping the rendered schema and the decoder in the codec was rejected. They save a schema render per card and one closure per decoder, and they cost a copy of the schema tree and a second copy of the codec on every send of every point. A card now renders and parses the output schema once per document; before, it only parsed a schema rendered once per point codec.
- Wrapping the card codec in `blueprint.custom` was rejected. It would capture the point's codec about three times instead of about twelve, but `custom` takes the document's schema computed in advance, so the card codec would hold the whole schema tree. It would also stop being a record codec, and its strict decode would go through a `Value`, which risks changing decoding behaviour.
- Moving the output fields to the front of the document, so that only the first field held the point's codec, was rejected. It changes the member order of `decision-card.v1` and of its schema.

## Evidence and history

- The copied size in bytes (`erts_debug:flat_size` times the word size, 8 bytes on this 64-bit machine) with json_blueprint 2.1.1, for the nested output of `test/codec_copy_size_test.gleam` (a record holding a record and a list of records):

| Term                         | Before  | After  |
| ---------------------------- | ------- | ------ |
| The json_blueprint codec     | 1 640   | 1 640  |
| `wire.codec(it)`             | 13 776  | 1 664  |
| `wire.text()`                | 1 312   | 208    |
| `view.codec(wire.text())`    | 21 512  | 4 424  |
| `view.codec(wire.codec(it))` | 221 288 | 21 896 |

- The figures of 38 kB and 542 kB come from the study that preceded this change, which used an output codec of its own; the table above is this repository's measurement.
- The json_blueprint guide: [Codec practice](https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md).
