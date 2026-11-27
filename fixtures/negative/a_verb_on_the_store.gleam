// Must not compile: a desk verb run on the in-memory store itself, outside
// `memory.transaction`. Only a transaction makes the port's `Tx`.
import decisions
import decisions/memory.{type Memory}
import decisions/vocabulary.{Approve}
import decisions_usage/clinic
import decisions_usage/first_point
import gleam/result

pub fn outside(store: Memory, id: String) {
  use card <- result.try(decisions.open(
    first_point.desk(),
    store,
    occurrence: id,
    by: clinic.felipe,
    latest: fn(r) { r.revision },
  ))
  decisions.decide(first_point.desk(), store, card, Approve)
}
