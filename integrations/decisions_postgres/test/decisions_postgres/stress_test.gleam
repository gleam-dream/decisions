//// The shared race and crash scenarios of `decisions_otp/stress`, run
//// against PostgreSQL at the light load. The default load runs with
//// `bash scripts/test-postgres.sh stress`.

import decisions_otp/stress
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import stress_target

pub fn the_shared_scenarios_pass_against_postgres_test() {
  let failures =
    list.filter_map(stress.scenarios(), fn(scenario) {
      case
        stress.run_scenario(scenario, stress_target.fresh, stress.light_load())
      {
        Ok(Nil) -> Error(Nil)
        Error(failure) -> Ok(failure)
      }
    })
  case failures {
    [] -> Nil
    _ -> {
      list.each(failures, fn(failure) {
        io.println_error(string.inspect(failure))
      })
      panic as { int.to_string(list.length(failures)) <> " scenarios failed" }
    }
  }
}
