//// Well-formed policies written as literals in tests.

import decisions/policy.{type Eligible, type Policy, type Rule}

/// The policy `policy.new` builds from these parts, which a test writes
/// well formed.
pub fn checked(
  version version: Int,
  rules rules: List(Rule),
  otherwise otherwise: Eligible,
) -> Policy {
  let assert Ok(made) = policy.new(version:, rules:, otherwise:)
  made
}
