//// The storage port's contract, as `decisions/conformance` states it,
//// against PostgreSQL: every check on a fresh store over one runtime.

import decisions/conformance
import decisions_postgres
import gleam/list
import gleam/string
import kit
import pog

pub fn postgres_passes_every_conformance_check_test() {
  let #(name, store) = kit.store()
  use env <- kit.run(name, store, kit.options(), [], [])
  let outcome =
    conformance.run(fn() {
      Ok(
        conformance.Adapter(
          port: decisions_postgres.port(store),
          inspect: decisions_postgres.inspection(),
          handle: env.db,
          transaction: fn(body) {
            case pog.transaction(env.db, body) {
              Ok(Nil) -> Ok(Nil)
              Error(pog.TransactionRolledBack(reason)) -> Error(reason)
              Error(pog.TransactionQueryError(error)) ->
                Error(string.inspect(error))
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
