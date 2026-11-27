// Control for a_verb_on_the_store.
import decisions
import decisions/memory.{type Memory}
import decisions/vocabulary.{Approve}
import decisions_usage/clinic
import decisions_usage/first_point
import gleam/result

pub fn inside(store: Memory, id: String) {
  use tx <- memory.transaction(store)
  use card <- result.try(decisions.open(
    first_point.desk(),
    tx,
    occurrence: id,
    by: clinic.felipe,
    latest: fn(r) { r.revision },
  ))
  decisions.decide(first_point.desk(), tx, card, Approve)
}
