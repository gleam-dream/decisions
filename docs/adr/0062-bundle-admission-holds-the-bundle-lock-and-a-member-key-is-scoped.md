# Bundle admission holds the bundle's lock, and a member's key is scoped by its bundle

<a id="adr-0062"></a>

Recorded on 2026-11-27. Supersedes the part of ADR-0058 that takes no bundle lock and names a bundle on the proposal.

## Decision

- `recommend_member(desk, tx, of: bundle, item:, proposal:)` and `recommend_bundle` load `bundle_lock(bundle)` through the port before they count a bundle's members. The id is `bundle_lock_prefix` and the hex SHA-256 of the bundle's key, a reserved prefix as for the subject lock; nothing is stored under it. The port's `load` locks an id that holds no entries (ADR-0005), so two transactions that admit members of one bundle run one after the other. Locks are taken in one order: the bundle lock, then the member's key.
- A member's key is `member_key(bundle, item)`: the bundle's key, a slash and the item. `recommend` and `recommend_once` admit no member, and a `Proposal` names no bundle (`in_bundle` is removed), so every member is admitted under a key its bundle scopes, and a member delivered again is found.
- `vocabulary.Bundle` is opaque. `vocabulary.bundle(key:, size:)` refuses an empty key (`NoBundleKey`) and a size below one (`EmptyBundle`), so a `Bundle` value is always well formed; `bundle_key` and `bundle_size` read it. A stored bundle that it refuses does not decode.

## Why

- The size check and the insert were not serialised. Two transactions admitting different members of one bundle could each see room and both commit: a bundle of two then held three members, `is_complete` never held, and the follow-on (a payout, a reply) was never started. Only invariant I9 in a test run noticed. A test over the process-safe store showed it: with one member uncommitted, a second transaction admitted two more and the bundle held three.
- A member admitted with plain `recommend` got a fresh id, so a delivery of the same member again was refused as `BundleFull` (`Poisoned`) instead of being found. Keying every member by its bundle makes redelivery find it.
- An empty key or a size below one was refused only at admission, as a set-aside job; the constructor now refuses them.

## Alternatives

- **Admit every bundle in one transaction.** It was the documented workaround, but a bundle that spans points is admitted by several workers, and nothing enforced it.
- **Keep `in_bundle` and refuse it on `recommend`.** A proposal would then carry a bundle that two of the three verbs refuse; removing it makes the refused combination unrepresentable.

## What changes for consumers

- `decisions` 0.2.0: replace `recommend_once(key: k, proposal: p |> in_bundle(b))` with `recommend_member(of: b, item: i, proposal: p)`, where `k` was `member_key(b, i)`. `recommend_bundle` takes items named by their item (`"l1"`), not by their full key. Build a bundle with `vocabulary.bundle`. `BundleFault` loses `NoBundleKey` and `EmptyBundle` (now `vocabulary.MalformedBundle`, carried by `Malformed` from `recommend_bundle`), and `RepeatedItem` names the item.
