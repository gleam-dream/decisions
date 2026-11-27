// Control for build_a_policy.
import decisions/policy

pub fn sound() {
  policy.new(version: 1, rules: [], otherwise: policy.AnyoneHolding("finance"))
}
