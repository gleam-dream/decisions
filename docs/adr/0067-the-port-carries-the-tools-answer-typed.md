# The port carries the tool's answer typed

<a id="adr-0067"></a>

Recorded on 2026-11-27.

## Decision

- `Stop` (`Refuse(reason)`, `Unsure(reason)`) moves from `decisions` to `decisions/vocabulary`, which `decisions/store` already imports.
- The port's `atomically` takes a body of type `fn(tx) -> Result(List(Ref), Stop)` and returns `Result(Result(List(Ref), Stop), StoreError)`. The desk no longer encodes a `Stop` as prefixed text and parses it back.
- A model's raise is recorded with its reason rendered to a depth of 30 and cut to `model.max_reason_bytes` (1 024) on a character boundary.

## Why

- The body's error was `String`, so the desk sent `"refuse:"` or `"unsure:"` and parsed the text it got back. Any other text, from an adapter that wrapped or edited the error contrary to the contract, became `Refuse`. A tool that could not tell (`Unsure`) then ended its occurrence `Refused` for good: a test whose port prefixed the error with `tool: ` recorded `Refused("tool: unsure:the provider timed out")` instead of failing with `ToolUnsure`. With the type, the adapter can only pass the value back.
- `describe` rendered the whole raise term with `~p`, and the record kept it: a model that raised with a response body wrote 140 000 bytes into an `attempt_failed` entry.

## Alternatives

- **Put `Stop` in `decisions/store`.** It is the adapter's module, and a tool's author would import it for every guard; `vocabulary` already holds the words a tool's author uses.
- **Let `exit` and `throw` propagate out of `model.run`.** It would separate a supervisor-level stop from a model fault, but it changes which failures a runtime records as attempts; it is left as it is.

## What changes for consumers

- `decisions` 0.2.0: write `vocabulary.Refuse(..)`, `vocabulary.Unsure(..)` and `vocabulary.Stop` where `decisions.Refuse`, `decisions.Unsure` and `decisions.Stop` were written. An adapter's `atomically` is typed over `Stop` and passes the body's error back as it is.
- A recorded raise's reason is at most 1 024 bytes.
