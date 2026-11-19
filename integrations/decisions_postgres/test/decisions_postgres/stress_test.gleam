//// The shared race and crash scenarios of `decisions_otp/stress`, run
//// against PostgreSQL at the light load, one test per scenario so each has
//// gleeunit's whole time limit (50 s) to itself; run together in one test
//// they exceeded it on a loaded machine. The default load runs with
//// `bash scripts/test-postgres.sh stress`. `every_scenario_has_a_test`
//// fails when the shared list gains one that has no test here.

import decisions_otp/stress
import gleam/list
import gleam/string
import stress_target

const count = 25

fn run(index: Int) -> Nil {
  let assert Ok(scenario) = list.drop(stress.scenarios(), index) |> list.first
  case stress.run_scenario(scenario, stress_target.fresh, stress.light_load()) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as string.inspect(failure)
  }
}

pub fn every_scenario_has_a_test_test() {
  assert list.length(stress.names()) == count
}

pub fn scenario_00_test() {
  run(0)
}

pub fn scenario_01_test() {
  run(1)
}

pub fn scenario_02_test() {
  run(2)
}

pub fn scenario_03_test() {
  run(3)
}

pub fn scenario_04_test() {
  run(4)
}

pub fn scenario_05_test() {
  run(5)
}

pub fn scenario_06_test() {
  run(6)
}

pub fn scenario_07_test() {
  run(7)
}

pub fn scenario_08_test() {
  run(8)
}

pub fn scenario_09_test() {
  run(9)
}

pub fn scenario_10_test() {
  run(10)
}

pub fn scenario_11_test() {
  run(11)
}

pub fn scenario_12_test() {
  run(12)
}

pub fn scenario_13_test() {
  run(13)
}

pub fn scenario_14_test() {
  run(14)
}

pub fn scenario_15_test() {
  run(15)
}

pub fn scenario_16_test() {
  run(16)
}

pub fn scenario_17_test() {
  run(17)
}

pub fn scenario_18_test() {
  run(18)
}

pub fn scenario_19_test() {
  run(19)
}

pub fn scenario_20_test() {
  run(20)
}

pub fn scenario_21_test() {
  run(21)
}

pub fn scenario_22_test() {
  run(22)
}

pub fn scenario_23_test() {
  run(23)
}

pub fn scenario_24_test() {
  run(24)
}
