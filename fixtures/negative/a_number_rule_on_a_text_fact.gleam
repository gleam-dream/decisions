// Must not compile: a policy that compares a text fact with a number.
import decisions/fact
import decisions/policy

pub fn confused() {
  policy.below(fact.text("category"), 100.0)
}
