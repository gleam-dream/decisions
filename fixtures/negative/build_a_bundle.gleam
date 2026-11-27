// Must not compile: a bundle built without `vocabulary.bundle`, which would
// skip the refusal of a size below one.
import decisions/vocabulary

pub fn forge() {
  vocabulary.Bundle(key: "report-7", size: 0)
}
