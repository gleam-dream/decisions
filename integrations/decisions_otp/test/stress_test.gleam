//// The reusable stress suite against the process-safe store, one test per
//// scenario so that a failure names its scenario.

import decisions_otp/store
import decisions_otp/stress
import gleam/list
import gleam/string
import gleam/time/duration

@external(erlang, "decisions_otp_ffi", "quiet")
fn quiet() -> Nil

fn run(prefix: String) -> Nil {
  run_at(prefix, stress.default_load())
}

fn run_at(prefix: String, load: stress.Load) -> Nil {
  quiet()
  let assert [scenario] =
    list.filter(stress.scenarios(), fn(scenario) {
      string.starts_with(scenario.name, prefix)
    })
  let outcome =
    stress.run_scenario(
      scenario,
      fn() {
        stress.in_memory(
          store.Config(
            ..store.defaults(),
            retry_backoff: duration.milliseconds(10),
          ),
        )
      },
      load,
    )
  assert outcome == Ok(Nil)
}

pub fn a1_test() {
  run("A1 ")
}

pub fn a2_test() {
  run("A2 ")
}

pub fn a3_test() {
  run("A3 ")
}

pub fn a4_test() {
  run("A4 ")
}

pub fn held_superseded_test() {
  run("a held occurrence superseded")
}

pub fn expect_closes_the_window_test() {
  run("expect closes the superseding window")
}

pub fn admissions_about_one_subject_test() {
  run("concurrent admissions about one subject")
}

pub fn one_key_test() {
  run("recommend_once on one key")
}

pub fn absent_id_waits_test() {
  run("a load of an absent id")
}

pub fn present_id_waits_test() {
  run("a load of a present id")
}

pub fn uncommitted_writes_are_invisible_test() {
  run("uncommitted writes")
}

pub fn killed_in_a_transaction_test() {
  run("a process killed in a transaction")
}

pub fn killed_in_a_savepoint_test() {
  run("a process killed in a savepoint")
}

pub fn happened_and_decide_do_not_deadlock_test() {
  run("happened and decide")
}

pub fn wake_ups_and_notices_survive_a_restart_test() {
  run("wake-ups and notices survive")
}

pub fn now_is_the_wall_clock_test() {
  run("now is the wall clock")
}

pub fn schedule_leaves_a_delivered_wake_up_alone_test() {
  run("schedule leaves a delivered")
}

pub fn b1_test() {
  run("B1 ")
}

pub fn b2_test() {
  run("B2 ")
}

pub fn b4_test() {
  run("B4 ")
}

pub fn b5_test() {
  run("B5 ")
}

/// B5 holds its condition at a load small enough to settle before five
/// kills would happen by themselves.
pub fn b5_at_the_light_load_test() {
  run_at("B5 ", stress.light_load())
}

pub fn b6_test() {
  run("B6 ")
}

pub fn b7_test() {
  run("B7 ")
}

pub fn own_deadline_test() {
  run("an expected record expires at its own deadline")
}

/// Every scenario has a test above.
pub fn every_scenario_is_run_test() {
  assert list.length(stress.names()) == 24
}
