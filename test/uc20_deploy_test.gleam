//// Use case 20: a deployment. Nothing about customers, and no concept the
//// library did not already have.

import decisions.{type Desk, type Point, Gated}
import decisions/fact.{type Key}
import decisions/memory.{type Memory}
import decisions/occurrence.{type Occurrence}
import decisions/policy.{AnyoneHolding, Ask, Never, Policy, Proceed, When}
import decisions/vocabulary.{
  Approve, Manifest, Recommendation, Ref, RuleFired, Rules, Subject, Superseded,
  Trigger, Validator,
}
import decisions/wire
import gleam/int
import gleam/time/duration
import json/blueprint/codec
import support/world.{type World}

type Promotion {
  Promotion(build: Int, environment: String)
}

const api = Subject(kind: "service", id: "api")

const rita = Validator(subject: "rita", holds: ["release-managers"])

fn environment() -> Key(String) {
  fact.text("environment")
}

fn point() -> Point(Promotion) {
  decisions.point(
    "release.promote",
    wire.codec({
      use build <- codec.field("build", codec.int(), get: fn(p: Promotion) {
        p.build
      })
      use environment <- codec.field(
        "environment",
        codec.string(),
        get: fn(p: Promotion) { p.environment },
      )
      codec.success(Promotion(build:, environment:))
    }),
  )
  |> decisions.fact(environment(), fn(promotion: Promotion) {
    promotion.environment
  })
  // Ten minutes of canary before the release.
  |> decisions.with_hold(duration.minutes(10))
  |> decisions.superseded_by("newer_build_ready")
}

/// One policy serves both environments, because the environment is a fact
/// of the output.
fn policy() {
  Policy(
    version: 1,
    rules: [When(policy.is(environment(), "staging"), Proceed(Never))],
    otherwise: Ask(AnyoneHolding("release-managers")),
  )
}

fn desk() -> Desk(Promotion, Memory) {
  decisions.desk(
    point(),
    drives: fn(_) {
      Gated(
        name: "deploy",
        guard: fn(tx, subject) {
          case memory.get(tx, "incident:" <> subject.id) {
            Ok(_) ->
              Error(decisions.Refuse("an incident is open on " <> subject.id))
            Error(Nil) -> Ok([])
          }
        },
        execute: fn(tx, released) {
          let promotion: Promotion = decisions.output(released)
          Ok(world.push(
            tx,
            "deploys",
            promotion.environment <> ":" <> int.to_string(promotion.build),
          ))
        },
      )
    },
    under: fn(_) { Ok(policy()) },
    over: memory.port(),
  )
}

fn build_passed(w: World, build: Int, to: String) -> Occurrence(Promotion) {
  let assert Ok(arrived) =
    world.in_tx(w, decisions.recommend_once(
      desk(),
      _,
      key: "promote-" <> int.to_string(build) <> "-" <> to,
      proposal: decisions.proposal(
        trigger: Trigger(kind: "build_passed", id: int.to_string(build)),
        about: api,
        context: Manifest(
          refs: [
            Ref("diff", "api", int.to_string(build)),
            Ref("test_report", "api", int.to_string(build)),
          ],
          renderer: "promotion-1",
        ),
        recommending: Recommendation(
          output: Promotion(build:, environment: to),
          by: Rules("promotion-rules", "1"),
          explanation: RuleFired("all-checks-green"),
          signals: [],
          reads: [],
        ),
      ),
    ))
  arrived
}

pub fn the_policy_is_publishable_for_this_point_test() {
  assert decisions.publishable(point(), policy()) == Ok(Nil)
}

pub fn staging_proceeds_after_its_canary_test() {
  let w = world.new()
  let staging = build_passed(w, 812, "staging")
  let assert occurrence.Held(by: occurrence.ByPolicy(1), ..) = staging.status
  assert world.all(w.db, "deploys") == []

  world.at(w, duration.minutes(10))
  assert world.deliver_due(w, [decisions.waker(desk())]) == 1
  let assert occurrence.Released(..) = world.read(w, desk(), staging.id).status
  assert world.all(w.db, "deploys") == ["staging:812"]
}

pub fn production_asks_and_an_incident_during_the_canary_stops_it_test() {
  let w = world.new()
  let production = build_passed(w, 812, "production")
  let assert occurrence.Awaiting(AnyoneHolding("release-managers")) =
    production.status

  let assert Ok(held) =
    world.in_tx(w, world.open_and_decide(
      desk(),
      _,
      production.id,
      rita,
      Approve,
    ))
  let assert occurrence.Held(by: occurrence.ByValidator("rita"), ..) =
    held.status

  // An incident opens during the canary. The guard is checked again at
  // release, against the world as it is then.
  world.at(w, duration.minutes(4))
  memory.put(w.db, "incident:api", "INC-9")
  world.at(w, duration.minutes(10))
  assert world.deliver_due(w, [decisions.waker(desk())]) == 1
  assert world.read(w, desk(), production.id).status
    == occurrence.Refused("an incident is open on api")
  assert world.all(w.db, "deploys") == []
}

pub fn a_newer_build_supersedes_a_promotion_that_still_waits_test() {
  let w = world.new()
  let old = build_passed(w, 812, "production")
  let assert Ok(decisions.Supersession(expired: [superseded], unreadable: [])) =
    world.in_tx(w, decisions.happened(
      desk(),
      _,
      "newer_build_ready",
      about: api,
    ))
  assert superseded.id == old.id
  assert superseded.status
    == occurrence.Expired(Superseded("newer_build_ready"))
  assert world.in_tx(w, world.open_and_decide(desk(), _, old.id, rita, Approve))
    == Error(decisions.NotAwaiting)
}
