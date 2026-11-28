# A bundle item holds no slash

<a id="adr-0072"></a>

Recorded on 2026-11-28.

## Decision

- A bundle member's item is a `vocabulary.Item`, an opaque name built with `vocabulary.item(name:)`. It refuses an empty name (`NoItemName`) and a name that holds a slash (`SlashInItem`); `item_name` reads it.
- `recommend_member`, `recommend_bundle` and `member_key` take an `Item`. `member_key(bundle, item)` stays the bundle's key, a slash and the item's name, so a member's id has the same form as before.
- A bundle's key may still hold slashes. Because an item holds none, the last slash of a member's key separates the bundle's key from the item, and no two pairs of bundle and item name one key.

## Why

- `member_key` joined the bundle's key and the item with a slash, and both were free text. Bundle `a` with item `b/c` and bundle `a/b` with item `c` both named `a/b/c`. The second admission found the first's occurrence, outside its bundle, and was refused `BadBundle("a/b", KeyOutsideBundle("a/b/c"))` (`Poisoned`): a member that could never be admitted, set aside as if its record were broken.
- An application that wanted item names with slashes had to escape them itself, and an escape it did not test could collide the same way.

## Alternatives

- **Refuse a slash at admission, with a new `BundleFault`.** It keeps `String` items, but a member with a bad item would be built, carried to a worker and only refused there, as a set-aside job.
- **Escape the item in the key.** Every item would be accepted, but an occurrence id would no longer show the item as written, and the escape character would need escaping in turn.
- **Refuse a slash in the bundle's key as well.** Not needed: with slash-free items the split is already unique, and existing bundle keys with slashes keep working.

## What changes for consumers

- `decisions` (next release): build each item with `vocabulary.item(name:)` and pass the `Item` to `recommend_member`, `recommend_bundle` and `member_key`. Member ids are unchanged. An application that escaped slashes in its item names can drop the escape and refuse such names where they enter, or keep its own slash-free encoding.
