# Occurrences proposed together are a bundle, completed by a follower

<a id="adr-0058"></a>

Recorded on 2026-11-27.

## Decision

- One recommendation that proposes several separable items (the lines of an expense report, a reply and a process to start, extracted entities, a batch of labels) is admitted as several ordinary occurrences that name one **bundle**: a key and the number of occurrences it holds (`vocabulary.Bundle(key, size)`). Each member is judged, released, reported and assessed on its own, at its own point, under its own policy and its own release key. The members may belong to several points.
- A proposal names its bundle with `decisions.in_bundle`; `decisions.recommend_bundle` admits every item of one point under its own key, with the size the number of items. The bundle is written on the `recommended` entry, when present, and on the head. The desk refuses, with `BadBundle(bundle, fault)` (disposition `Poisoned`), an empty key, a size below one, a size that differs from one a member already recorded, a member beyond the size, and an item key given twice to `recommend_bundle`. A trigger delivered again finds its members and writes nothing.
- The storage port gains `members(tx, key)`: the ids and heads of a bundle's occurrences of every point, in ascending id order, without a lock. `decisions.members` and `decisions.is_complete` tell whoever follows the bundle's points when every member has settled and the bundle holds as many members as its size.
- What follows a bundle, such as one payout of the approved lines, is started by the point's follower: on each settlement notice it reads the members and, once the bundle is complete, recommends the follow-on with `recommend_once` under a key derived from the bundle. The library records no "ended" fact and takes no bundle lock.
- Whole rejection stays what it is: a verdict on each member, given by a validator each member admits. All-or-nothing across members stays the caller's transaction (use case 17).
- The conformance suite gains two checks (`members` in id order across points; a desk admits a bundle and tells when it is complete), invariant I9 checks that the members of a bundle agree on its size and are no more than it, and the shared stress suite gains a scenario in which every bundle starts exactly one follow-on. PostgreSQL migration 2 adds the bundle columns, their check and a partial index.

## Why a follower can tell, and why it starts the follow-on once

- A follower runs after the settlement it is told of has committed. The follower of the member that commits last therefore sees every member settled. Followers of earlier members may see it too; `recommend_once` under the bundle's follow-on key makes their extra calls write nothing.
- The check is unsafe inside the settling transactions: two last members settling at once under READ COMMITTED each see the other still open, and nobody starts the follow-on. Moving the check after the commit, into the follower, removes the race without a lock.
- A follower must check, not assume. A bundle whose last notice is set aside stays complete with nothing started; it is the follower's notice, and the store's set-aside list, that show it.
- The size on every member makes a bundle admitted in several transactions safe: it is not complete until every member has arrived.

## What changes for consumers

- `decisions` 0.2.0: `store.Head` gains `bundle`, `store.Port` gains `members`, `occurrence.Occurrence` gains `bundle`, `entry.Recommended` gains `bundle`, `Refusal` gains `BadBundle`. An adapter implements `members`; code that builds a `Head` or a `Recommended` entry by hand adds the field. Records written before decode unchanged: the entry field is read as absent.
- `decisions_otp` 0.2.0: the store keeps an index row per member. `decisions_postgres` 0.3.0: migration 2. Its version 1 `decisions_append` is kept beside the new one, so a node not yet upgraded keeps writing during a rolling deploy; it never writes a bundle. Upgrade every node before admitting the first bundle.

## Rationale and alternatives

- **Parts inside one occurrence** (a point that declares the parts of its output, one record with a verdict per part) was rejected after review: it rebuilds the occurrence's whole lifecycle (eligibility, timeline, quorum, hold, release, effect, assessment, settlement) as a second state machine inside one record, and the head, the queues, the release key and the invariants have no meaning for an occurrence that is part released and part waiting.
- **A bundle record of its own** (a second record type with its own lock, membership, discard, and an `ended` entry written by a bundle worker) was designed and reviewed over three rounds. Every round found new defects in the same place: a lock order across items and bundles, deadlocks with verbs that lock an item first, a second notice delivery, rolling deploys, and executors held under the bundle's lock. The owner asked to step back from it.
- **Ending the bundle in the transaction that settles its last member** is the race above.
- The prior art takes the same shape: agent SDKs approve each tool call of one run on its own and resume the run when every approval is resolved (the grouping is the run's id), and job queues tag jobs with a batch id and run a unique callback once every job of the batch has completed.

## Evidence and history

- The owner's ruling of 2026-11-26, after a prototype: every member an occurrence, grouped by a bundle key and size, completed by a follower. A throwaway prototype raced the last settlements of 1 660 bundles on PostgreSQL (Grind's settlement worker) and on the OTP store, staggered and in bursts, with followers that failed their first delivery: every bundle started exactly one follow-on. It also showed the two hazards the design closes or names: a bundle admitted in pieces started its follow-on early until the size was checked, and a last follower whose notice was set aside left its bundle with nothing started.
- Consumer evidence ([ADR-0036](0036-applications-are-the-consumer-evidence.md#adr-0036)): an application outside the three named ones needs a model's several proposals judged one by one, and cannot get per-item policy, release, effect and measurement from one occurrence. The owner counts it as the evidence.
- `test/uc21_bundle_test.gleam`; `decisions/conformance` (two checks); `decisions/testing` (I9); the stress scenario "each bundle starts exactly one follow-on", run against the OTP store and PostgreSQL; `integrations/decisions_postgres/test/decisions_postgres/bundle_test.gleam`; `examples/usage/src/decisions_usage/bundle.gleam`.
