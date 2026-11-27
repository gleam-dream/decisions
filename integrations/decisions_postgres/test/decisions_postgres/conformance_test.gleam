//// The storage port's contract, as `decisions/conformance` states it,
//// against PostgreSQL: every check on a fresh store over one runtime.

import decisions/conformance
import decisions_postgres
import gleam/list
import gleam/string
import kit

pub fn postgres_passes_every_conformance_check_test() {
  let #(name, store) = kit.store()
  use env <- kit.run(name, store, kit.options(), [], [])
  let outcome =
    conformance.run(fn() {
      Ok(
        conformance.Adapter(
          port: decisions_postgres.port(store),
          inspect: decisions_postgres.inspection(),
          transaction: fn(body) {
            case kit.own(env, body) {
              Ok(text) -> Ok(text)
              Error(decisions_postgres.OwnFailed(reason)) -> Error(reason)
              Error(decisions_postgres.LibraryFailed(failure)) ->
                Error(decisions_postgres.describe(failure))
            }
          },
          cleanup: fn() { Nil },
        ),
      )
    })
  case outcome {
    Ok(Nil) -> Nil
    Error(failures) ->
      panic as string.join(list.map(failures, string.inspect), "\n")
  }
}
