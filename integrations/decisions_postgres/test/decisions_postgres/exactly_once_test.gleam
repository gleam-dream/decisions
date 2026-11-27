//// Releasing exactly once on real connections: eight processes race
//// `recommend_once` on one key, through the one shape a verb can take,
//// and the gated tool runs once per key.

import decisions
import decisions/vocabulary

import gleam/int
import gleam/list
import kit

/// Eight processes race `recommend_once` on each of twenty keys to a
/// point that proceeds: the gated tool runs once per key.
pub fn racing_processes_release_each_key_once_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("once"), policy: kit.proceed())
  let desk = kit.desk(store, spec)
  use env <- kit.run(
    name,
    store,
    kit.Options(..kit.options(), pool_size: 40),
    [],
    [],
  )
  let keys =
    list.map(kit.int_range(20), fn(n) { kit.tag("k" <> int.to_string(n)) })
  let _ =
    kit.race(20 * 8, 30_000, fn(n) {
      let assert Ok(key) = list.drop(keys, n / 8) |> list.first
      kit.tx(env, decisions.recommend_once(
        desk,
        _,
        key:,
        proposal: kit.proposal(spec.name, vocabulary.Subject("person", key)),
      ))
    })
  assert kit.effects(env.db, spec.name) == 20
}
