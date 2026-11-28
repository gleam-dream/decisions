// Must not compile: an item built without `vocabulary.item`, which would
// skip the refusal of a slash and give two bundles' members one key.
import decisions/vocabulary

pub fn forge() {
  vocabulary.Item(name: "b/c")
}
