//// Releasing exactly once, under real processes: eight processes race
//// `recommend_once` on one key, through the one shape a verb can take,
//// and the gated tool runs once per key.

import decisions/vocabulary.{Rules}
import decisions_otp/store
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import support/lab

pub fn racing_processes_release_each_key_once_test() {
  let s = lab.start()
  let desk = lab.desk(lab.point("race.once", None), lab.proceeding())
  let keys = lab.numbers(1, 20) |> list.map(fn(n) { "k-" <> int.to_string(n) })
  let done = process.new_subject()
  list.each(keys, fn(key) {
    list.each(lab.numbers(1, 8), fn(_) {
      process.spawn(fn() {
        let _ =
          store.transaction(s, lab.recommend(
            desk,
            _,
            key,
            about: lab.ana,
            output: "pay",
            by: Rules("rules", "1"),
            score: 1.0,
          ))
        process.send(done, Nil)
      })
    })
  })
  list.each(lab.numbers(1, 20 * 8), fn(_) {
    let assert Ok(Nil) = process.receive(done, 10_000)
  })
  assert lab.effects(s, desk) == list.length(keys)
}
