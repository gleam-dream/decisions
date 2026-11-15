//// The README's wiring example starts, migrates and serves a verb.

import decisions
import decisions/vocabulary.{Manifest, Recommendation, RuleFired, Rules, Trigger}
import decisions_postgres
import gleam/option.{None}
import kit
import wiring/postgres_wiring

pub fn the_readme_wiring_starts_and_serves_test() {
  let assert Ok(Nil) = postgres_wiring.migrate_at_deploy(kit.pool_config(2))
  let assert Ok(wired) = postgres_wiring.start(kit.pool_config(4))
  assert decisions_postgres.name(wired.store) == "billing"
  let proposal =
    decisions.proposal(
      trigger: Trigger("test", kit.tag("t")),
      about: kit.ana,
      context: Manifest(refs: [], renderer: "test-1"),
      recommending: Recommendation(
        output: "refund the fee",
        by: Rules("test", "1"),
        explanation: RuleFired("test"),
        signals: [],
        reads: [],
      ),
    )
  let assert Ok(waiting) =
    decisions_postgres.transaction(wired.db, decisions.recommend(
      wired.refunds,
      _,
      proposal,
    ))
  assert waiting.valid_until == None
}
