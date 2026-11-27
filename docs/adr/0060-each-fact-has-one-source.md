# Each fact a policy reads has one source

<a id="adr-0060"></a>

Recorded on 2026-11-27.

## Decision

- A point declares each fact with one source: `decisions.fact` (computed from the output), `decisions.signal` (carried by the recommendation), or `decisions.answer(key, from: point)` (returned by that consulted point through `inform`). The declaration holds one entry per name; declaring a name again replaces the earlier entry.
- `recommend` refuses, with `InvalidFacts` (`Poisoned`), a recommendation whose signals hold a fact not declared as a signal, or of another type. `inform` refuses a fact not declared as an answer from the point that informs, or of another type.
- `decisions.policy_facts(point, recommendation, informed:)` builds the facts a policy reads, taking each fact only from its declared source. The desk and `learning.answer_under` and `learning.candidate_under` use it, so a replay reads facts as the desk did. It replaces `decisions.facts_of`.

## Why

- Signals and consulted answers shared one declaration (`signal`) and one list, read first match in the order output facts, signals, answers. A model whose signals named a consulted point's answer (`cleared: True`) shadowed it: a policy "consult compliance until `cleared` is known, proceed when it is true" released at once and never consulted. Had compliance answered false, the policy would still have read the model's true. A consulted point is usually the independent check on the model, and the model could stand in for it.
- With one source per name the order of the list no longer matters, and the policy reads only what that source can supply. Refusing the misplaced signal at `recommend` makes the attempt visible: the job is set aside for an operator instead of the signal being kept silently on the record.

## Alternatives

- **Keep one list and put answers first.** Rejected: a signal could still stand for an output fact or for an answer not yet given, and the rule would depend on an order a reader must remember.
- **Refuse a point that declares a name twice.** The builders return a `Point`, not a `Result`, and a name declared twice is a mistake in the application's own code; replacing the earlier entry keeps one source per name without a second construction path.
- **Ignore an undeclared signal instead of refusing it.** Rejected: a model that sends a fact it may not supply is a bug or an attack, and failing early shows it.

## What changes for consumers

- `decisions` 0.2.0: declare a consulted point's answer with `decisions.answer(key, from: "point")` instead of `decisions.signal(key)`. A recommendation that carries an undeclared or mistyped signal is refused with `InvalidFacts`. `decisions.facts_of(point, output)` is replaced by `decisions.policy_facts(point, recommendation, informed:)`.
