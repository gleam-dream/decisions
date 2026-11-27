# An isolated model has a heap limit

<a id="adr-0071"></a>

Recorded on 2026-11-27.

## Decision

- `isolated.model(inner, within:, heap:)` takes an `isolated.HeapLimit`, an opaque whole number of megabytes of at least one, built with `isolated.heap_limit(megabytes:)`.
- The model's process is spawned with `max_heap_size` at that limit, `kill => true` and no error report. A model killed for its heap is `model.Raised`, with a reason that names the limit.
- The limit is required: there is no default.

## Why

- The module promises that a model call cannot hurt its caller. A deadline bounds its time, but a model that allocates without bound within its deadline could still exhaust the node: a test model built 80 MB of list cells inside a 10-second deadline and answered.
- A limit of zero means "no limit" to the runtime, so the type holds at least one megabyte.

## Alternatives

- **A default limit.** Any default is a guess about the application's models, and a model above it would start failing after an upgrade with no change of its own. A required argument makes each caller choose once.
- **Count shared binaries too (`include_shared_binaries`).** A long prompt is a shared binary the caller also holds; counting it would charge the model for memory it did not allocate.

## What changes for consumers

- Every `isolated.model` call passes `heap:`.
