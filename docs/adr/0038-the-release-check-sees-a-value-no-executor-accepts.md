# The release check sees a value no executor accepts

<a id="adr-0038"></a>

## Decision

- The release check receives `ToRelease(output, subject, context, key)`, not a `Released` value: `checking(desk, with: fn(tx, ToRelease(o)) -> Result(List(Ref), Stop))`.
- `Released` is built only for the executor, for one release attempt inside the savepoint. An executor must not keep it beyond its call.
- A negative fixture, `fixtures/negative/a_release_check_value_to_an_executor.gleam`, shows that handing the check's value to an executor does not compile.

## Rationale and alternatives

- The check used to receive the `Released` value. A check could keep it, refuse, and later call the tool's executor with it, so an effect happened for an occurrence that ended refused. This was the one back door the final review found to a release without acceptance.
- Giving the check the output and nothing typed was rejected: the context and the key are what a check needs to name its evidence.

## Evidence and history

- Final review of the core, 2026-11-15, finding R3. `src/decisions.gleam`, `ToRelease`, `checking`, `Released`; the core's test of the release order (guard, check, executor), added because moving the check after the executor passed every earlier test (finding R12). This refines ADR 0031.
