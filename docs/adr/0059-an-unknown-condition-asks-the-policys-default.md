# An unknown condition asks the policy's default, and a policy is built well formed

<a id="adr-0059"></a>

Recorded on 2026-11-27.

## Decision

- A policy's default is who to ask: `Policy(version, rules, otherwise: Eligible)`. A policy proceeds or consults only through a rule whose condition holds. `Always` is the condition of a rule that decides whatever the facts.
- The rules are read in order. A condition is true, false, or unknown; it is unknown when a fact it compares is absent or of another type, and `Not` keeps it unknown. The first rule that holds decides. When a rule's condition is unknown, or when no rule holds, the policy answers `Ask(otherwise)`. A rule after an unknown one is never read.
- A policy that would consult the same point twice also answers `Ask(otherwise)`.
- `Policy` is opaque. `policy.new` refuses, with `Malformed`, a policy that no point could use: fewer than one approval, a `Several` inside another `Several`, an `Either` with no alternative, a sample outside 0 to 100, a hold of zero or less. `policy.decoder` builds through `new`, so a stored malformed policy does not decode. `check` and `decisions.publishable` keep only what depends on the point: an undeclared fact and a fact compared as the wrong type.

## Why

- The design promised that what is unknown never proceeds, but a condition over a missing fact only failed to match, and evaluation fell through to later rules and to `otherwise`. Under "ask risk when the risk is at least 0.5, otherwise proceed", a recommendation whose model sent no risk score, or sent it as text, was released with no person. The record showed an ordinary `policy_applied` proceed.
- Stopping at the unknown rule needs somewhere to go that is safe whatever the rules say. A default that is always a person is that place, and it removes the other path by which a policy proceeded without a rule saying so: falling through to a proceeding default.
- The structural faults of a policy were found on every read and refused with `Unpublishable` (`Poisoned`), so each malformed policy cost a set-aside job. They need no point to be found, so the constructor can refuse them and a `Policy` value is always well formed.

## Alternatives

- **A separate `unknown: Eligible` on every policy, beside a default that may proceed.** Rejected: most policies ask their default, and the field would repeat it; and a proceeding default would still let a policy proceed when no rule holds, which is the shape that hid the bug.
- **Refuse a recommendation that lacks a declared signal.** Not enough on its own: it covers signals, but not an output fact or a consulted answer that is absent. The policy must be safe whatever facts it is given.
- **Ask the eligibility of the unknown rule's own `Ask`.** Rejected: a rule that proceeds or consults has none, so the answer would depend on the rule's outcome.

## What changes for consumers

- `decisions` 0.2.0: `Policy` is opaque and built with `policy.new`, which returns `Result(Policy, List(Malformed))`; read it with `policy.version`, `policy.rules` and `policy.otherwise`. `otherwise` is an `Eligible`. A default that proceeded becomes a last rule `When(Always, Proceed(..))`. `Fault` keeps `UndeclaredFact` and `WrongKind`; the other variants move to `Malformed`, described by `policy.describe_malformed`. The stored JSON of a policy writes `otherwise` as an eligibility, and `{"t": "always"}` as a condition. A policy stored by 0.1 does not decode and is published again.
