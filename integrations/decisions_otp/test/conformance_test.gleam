//// The process-safe store against the core's conformance suite, with a
//// stopped clock and with the wall clock.

import decisions/conformance
import decisions/wire
import decisions_otp/store
import gleam/list

fn conforms(config: store.Config) -> Result(Nil, List(conformance.Unmet)) {
  conformance.run(fn() {
    case store.start(config) {
      Ok(s) ->
        Ok(
          conformance.Adapter(
            port: store.port(),
            inspect: store.inspection(),
            handle: store.handle(s),
            transaction: fn(body) { store.transaction(s, body) },
            cleanup: fn() { store.stop(s) },
          ),
        )
      Error(_) -> Error("the store did not start")
    }
  })
}

pub fn the_store_conforms_with_a_stopped_clock_test() {
  let at = wire.from_milliseconds(1_800_000_000_000)
  assert conforms(store.Config(..store.defaults(), clock: store.Stopped(at)))
    == Ok(Nil)
}

pub fn the_store_conforms_with_the_wall_clock_test() {
  assert conforms(store.defaults()) == Ok(Nil)
}

pub fn the_suite_has_twenty_one_checks_test() {
  assert list.length(conformance.names()) == 21
}
