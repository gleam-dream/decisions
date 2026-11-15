// Control for a_number_rule_on_a_text_fact and a_text_value_for_a_number_fact.
import decisions/fact
import decisions/policy

pub fn sound() {
  #(
    policy.below(fact.number("amount"), 100.0),
    fact.set(fact.number("confidence"), 0.9),
  )
}
