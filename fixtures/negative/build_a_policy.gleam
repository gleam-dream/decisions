// Must not compile: a policy built without `policy.new`, which would skip
// the refusal of a count of zero approvals.
import decisions/policy

pub fn forge() {
  policy.Policy(
    version: 1,
    rules: [],
    otherwise: policy.Several(0, policy.AnyoneHolding("finance")),
  )
}
