//// Use case 14 and condition D: a payout a provider's API performs, and a
//// guard that needs a fact only the provider knows.
////
//// The gated tool never calls the provider. It writes an instruction beside
//// the release, in the release's transaction. A worker performs it under
//// the release's key and reports what became of it.

import decisions.{type Desk, type Gated, Gated}
import decisions/memory.{type Memory}
import decisions/model
import decisions/occurrence
import decisions/policy.{AnyoneHolding}
import decisions/vocabulary.{
  type Ref, Approve, NotPerformed, Performed, Ref, Uncertain,
}
import decisions/wire
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{Some}
import gleam/order
import gleam/result
import gleam/time/duration
import gleam/time/timestamp
import support/payout.{type Payout, Payout}
import support/policies
import support/world.{type World}

/// The provider keeps one payout per key, whatever it is sent.
fn provider_pay(w: World, key: String, payout: Payout) -> String {
  case memory.get(w.outside, "paid:" <> key) {
    Ok(receipt) -> receipt
    Error(Nil) -> {
      world.push(w.outside, "provider_payouts", payout.to)
      let receipt = "rcpt-" <> key
      memory.put(w.outside, "paid:" <> key, receipt)
      receipt
    }
  }
}

fn provider_lookup(w: World, key: String) -> Result(String, Nil) {
  memory.get(w.outside, "paid:" <> key)
}

/// "Is the account open?" Only the provider knows, and it may be down.
fn provider_account(w: World) -> Result(String, String) {
  memory.get(w.outside, "account")
  |> result.replace_error("the provider did not answer")
}

/// Ask the provider and keep the answer as evidence, before any verdict.
/// This runs outside the verdict's transaction: no lock is held over a
/// network call.
fn check_account(w: World) -> Result(Ref, String) {
  world.in_tx(w, fn(tx) {
    use captured <- result.try(
      model.capture(
        memory.evidence(),
        tx,
        source: "provider.account",
        request: world.clinica.id,
        fetch: fn() { provider_account(w) },
      ),
    )
    memory.put(
      tx,
      "account_check:" <> world.clinica.id,
      json.to_string(
        json.object([
          #("evidence", wire.ref(captured.ref)),
          #("at", wire.time(memory.now(tx))),
        ]),
      ),
    )
    Ok(captured.ref)
  })
}

fn pay_at_provider() -> Gated(Payout, Memory) {
  Gated(
    name: "pay_at_provider",
    // D2. The guard reads the captured answer, not the network, and says
    // which evidence it relied on.
    guard: fn(tx, subject) {
      let check =
        memory.get(tx, "account_check:" <> subject.id)
        |> result.try(fn(text) {
          json.parse(text, {
            use evidence <- decode.field("evidence", wire.ref_decoder())
            use at <- decode.field("at", wire.time_decoder())
            decode.success(#(evidence, at))
          })
          |> result.replace_error(Nil)
        })
      case check {
        Error(Nil) ->
          Error(decisions.Refuse(
            "nobody has asked the provider whether the account is open",
          ))
        Ok(#(evidence, at)) -> {
          let fresh =
            timestamp.compare(
              memory.now(tx),
              timestamp.add(at, duration.minutes(5)),
            )
            == order.Lt
          case fresh, memory.evidence().get(tx, evidence) {
            False, _ ->
              Error(decisions.Refuse(
                "the provider's answer is older than 5 minutes",
              ))
            True, Ok("open") -> Ok([evidence])
            True, _ ->
              Error(decisions.Refuse(
                "the provider says the account is not open",
              ))
          }
        }
      }
    },
    execute: fn(tx, released) {
      let payout: Payout = decisions.output(released)
      memory.put(
        tx,
        "instruction:" <> decisions.key(released),
        decisions.occurrence_of(released)
          <> "|"
          <> payout.to
          <> "|"
          <> int.to_string(payout.cents),
      )
      Ok(Nil)
    },
  )
}

fn desk() -> Desk(Payout, Memory) {
  decisions.desk(
    payout.point(),
    drives: fn(_) { pay_at_provider() },
    under: fn(_) {
      Ok(policies.checked(
        version: 1,
        rules: [],
        otherwise: AnyoneHolding("finance"),
      ))
    },
    over: memory.port(),
  )
}

fn approved(w: World, key: String) -> String {
  let assert Ok(waiting) =
    world.in_tx(w, payout.request(
      desk(),
      _,
      key:,
      by: "felipe",
      payout: Payout("clinica-x", 50_000),
    ))
  let assert Ok(released) =
    world.in_tx(w, world.open_and_decide(
      desk(),
      _,
      waiting.id,
      world.bia,
      Approve,
    ))
  let assert occurrence.Released(key: release_key, ..) = released.status
  release_key
}

pub fn the_release_names_the_evidence_its_guard_relied_on_test() {
  let w = world.new()
  memory.put(w.outside, "account", "open")
  let assert Ok(evidence) = check_account(w)
  let _ = approved(w, "payout-20")
  assert occurrence.relied(world.read(w, desk(), "payout-20")) == [evidence]
}

pub fn a_provider_that_is_down_refuses_the_release_and_says_so_test() {
  let w = world.new()
  // The provider does not answer, so no evidence exists.
  assert check_account(w) == Error("the provider did not answer")
  let assert Ok(waiting) =
    world.in_tx(w, payout.request(
      desk(),
      _,
      key: "payout-21",
      by: "felipe",
      payout: Payout("clinica-x", 50_000),
    ))
  let decide = fn() {
    world.in_tx(w, world.open_and_decide(
      desk(),
      _,
      waiting.id,
      world.bia,
      Approve,
    ))
  }
  assert result.map_error(decide(), decisions.describe)
    == Error("nobody has asked the provider whether the account is open")
  // The verdict rolled back with the refusal: the occurrence still waits.
  assert memory.queue(w.db, "finance") == ["payout-21"]

  // The provider returns. Stale evidence is refused too.
  memory.put(w.outside, "account", "open")
  let assert Ok(_) = check_account(w)
  world.at(w, duration.minutes(6))
  assert result.map_error(decide(), decisions.describe)
    == Error("the provider's answer is older than 5 minutes")
  let assert Ok(_) = check_account(w)
  let assert Ok(released) = decide()
  let assert occurrence.Released(..) = released.status
}

/// (a) The worker dies after the provider accepted and before it recorded
/// the answer. The instruction is still there, so it is delivered again.
pub fn a_worker_lost_after_the_provider_accepted_pays_once_test() {
  let w = world.new()
  memory.put(w.outside, "account", "open")
  let assert Ok(_) = check_account(w)
  let key = approved(w, "payout-22")
  let assert Ok(_) = memory.get(w.db, "instruction:" <> key)

  // First delivery: the call succeeds and the worker is lost.
  let _ = provider_pay(w, key, Payout("clinica-x", 50_000))
  assert occurrence.effect(world.read(w, desk(), "payout-22")) == option.None

  // Second delivery, same key: the provider answers with the same receipt.
  let receipt = provider_pay(w, key, Payout("clinica-x", 50_000))
  let assert Ok(_) =
    world.in_tx(w, decisions.report(
      desk(),
      _,
      occurrence: "payout-22",
      effect: Performed(Ref("provider.receipt", key, receipt)),
    ))
  assert world.all(w.outside, "provider_payouts") == ["clinica-x"]
  assert occurrence.effect(world.read(w, desk(), "payout-22"))
    == Some(Performed(Ref("provider.receipt", key, "rcpt-" <> key)))
}

/// (b) The call times out. Nobody knows whether the provider paid.
pub fn an_unknown_outcome_is_recorded_and_settled_by_looking_test() {
  let w = world.new()
  memory.put(w.outside, "account", "open")
  let assert Ok(_) = check_account(w)
  let key = approved(w, "payout-23")

  // The provider did pay; the answer never arrived.
  let _ = provider_pay(w, key, Payout("clinica-x", 50_000))
  let assert Ok(_) =
    world.in_tx(w, decisions.report(
      desk(),
      _,
      occurrence: "payout-23",
      effect: Uncertain("the provider did not answer within 10 s"),
    ))
  let assert Some(Uncertain(_)) =
    occurrence.effect(world.read(w, desk(), "payout-23"))

  // Nothing retries blindly. A lookup under the same key settles it.
  let settled = case provider_lookup(w, key) {
    Ok(receipt) -> Performed(Ref("provider.receipt", key, receipt))
    Error(Nil) -> NotPerformed("the provider holds no payout under this key")
  }
  let assert Ok(known) =
    world.in_tx(w, decisions.report(
      desk(),
      _,
      occurrence: "payout-23",
      effect: settled,
    ))
  let assert Some(Performed(_)) = occurrence.effect(known)
  assert world.all(w.outside, "provider_payouts") == ["clinica-x"]
  // The outcome of the decision did not change: only reports were added.
  let assert occurrence.Released(..) = known.status

  // A report on an occurrence that was never released is refused.
  let assert Ok(waiting) =
    world.in_tx(w, payout.request(
      desk(),
      _,
      key: "payout-24",
      by: "felipe",
      payout: Payout("clinica-x", 1),
    ))
  assert world.in_tx(w, decisions.report(
      desk(),
      _,
      occurrence: waiting.id,
      effect: settled,
    ))
    == Error(decisions.NotReleased)
}
