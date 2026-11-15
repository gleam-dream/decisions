//// The entry point: `gleam test` runs every `*_test` module. Run through
//// `scripts/test-postgres.sh scale`, it runs the scale program instead;
//// with `stress`, the shared scenarios at their default load.

import decisions_otp/stress
import gleam/io
import gleam/list
import gleam/string
import gleeunit
import scale
import stress_target

@external(erlang, "kit_ffi", "plain_arguments")
fn arguments() -> List(String)

pub fn main() -> Nil {
  let arguments = arguments()
  case list.contains(arguments, "scale"), list.contains(arguments, "stress") {
    True, _ -> scale.main()
    _, True -> stress_at_default_load()
    _, _ -> gleeunit.main()
  }
}

/// Every shared scenario at the load STRESS.md states, one line each.
fn stress_at_default_load() -> Nil {
  list.each(stress.scenarios(), fn(scenario) {
    let line = case
      stress.run_scenario(scenario, stress_target.fresh, stress.default_load())
    {
      Ok(Nil) -> "passed: " <> scenario.name
      Error(failure) -> "FAILED: " <> string.inspect(failure)
    }
    io.println(line)
  })
}
