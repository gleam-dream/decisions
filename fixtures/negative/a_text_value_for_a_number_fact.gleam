// Must not compile: a model reports a text where the point declared a
// number.
import decisions/fact

pub fn signal() {
  fact.set(fact.number("confidence"), "very")
}
