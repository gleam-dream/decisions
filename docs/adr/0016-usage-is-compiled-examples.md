# Usage is compiled examples

<a id="adr-0016"></a>

## Decision

- Usage lives as compiled, runnable code in `examples/usage`: one module per topic (a first point, the autonomy ladder, a ticket across requests, four eyes with escalation, a provider effect, the same context for a person, replay), each asserting what it shows. The full gate runs its tests, so an API change that breaks an example fails the build.
- README examples are synchronized from named regions of that source with Snips; no prose usage guide exists.
- Type claims are fixtures that must fail to compile (`fixtures/negative`), each with a positive control that compiles.

## Rationale and alternatives

- A prose guide cannot fail when the API changes, so it drifts. The sibling packages (Saga ADR 0014, Fabric ADR 0016, Grind ADR 0019) reached the same decision.
- Keeping examples inside the root package's tests was rejected: an example must import only public modules, which a separate package proves.

## Evidence and history

- `examples/usage/src/decisions_usage/` and `examples/usage/test/decisions_usage_test.gleam`; `scripts/check_negative.sh`. Decided 2026-11-15.
