//// Use case 14 over PostgreSQL: a payout that a provider performs outside
//// the database. The gated tool writes an instruction beside the release;
//// the settlement's follower performs it at the provider under the
//// release's key and reports what became of it. A follower killed after
//// the provider accepted is delivered again and pays once; an unknown
//// outcome is recorded as such and settled by a lookup.

import decisions
import decisions/occurrence
import decisions/vocabulary.{Approve, NotPerformed, Performed, Ref, Uncertain}
import decisions_postgres
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam/time/duration
import grind
import kit
import pog

/// The provider: one payout per key, whatever it is sent, on a connection
/// of its own, so it never rolls back with the caller.
fn provider_pay(db: pog.Connection, key: String) -> String {
  let assert Ok(_) =
    pog.query(
      "INSERT INTO test_provider (key, receipt) VALUES ($1, 'rcpt-' || $1)
       ON CONFLICT (key) DO NOTHING",
    )
    |> pog.parameter(pog.text(key))
    |> pog.execute(db)
  "rcpt-" <> key
}

fn provider_lookup(env: kit.Env, key: String) -> Result(String, Nil) {
  let assert Ok(returned) =
    pog.query("SELECT receipt FROM test_provider WHERE key = $1")
    |> pog.parameter(pog.text(key))
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(env.db)
  case returned.rows {
    [receipt] -> Ok(receipt)
    _ -> Error(Nil)
  }
}

fn payouts(env: kit.Env, key: String) -> Int {
  kit.scalar(
    env.db,
    "SELECT count(*) FROM test_provider WHERE key = $1",
    [pog.text(key)],
    decode.int,
  )
}

pub fn a_follower_killed_after_the_provider_accepted_pays_once_test() {
  let #(name, store) = kit.store()
  let spec = kit.spec("payout")
  let store = decisions_postgres.following(store, spec.name)
  let desk = kit.desk(store, spec)
  // The tool's effect row is the instruction; the follower performs it.
  // The provider is reached on the pool, outside the follower's
  // transaction.
  let follower = #(spec.name, fn(tx, id) {
    let key = "release:" <> id
    let receipt = provider_pay(grind.connection(grind.named(name)), key)
    // The first delivery is lost after the provider accepted, before the
    // report: a worker killed at that moment.
    case kit.once("payout:" <> id) {
      True -> process.kill(process.self())
      False -> Nil
    }
    decisions.report(
      desk,
      tx,
      occurrence: id,
      effect: Performed(Ref("provider.receipt", key, receipt)),
    )
    |> result.replace(Nil)
    |> result.map_error(decisions.DeskRefused)
  })
  let options =
    kit.Options(..kit.delivering(), deadline: duration.milliseconds(1200))
  use env <- kit.run(name, store, options, [], [follower])
  let assert Ok(_) =
    pog.query(
      "CREATE TABLE IF NOT EXISTS test_provider (key text PRIMARY KEY, receipt text NOT NULL)",
    )
    |> pog.execute(env.db)
  let assert Ok(waiting) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert Ok(released) =
    kit.tx(env, kit.open_and_decide(
      desk,
      _,
      waiting.id,
      kit.finance("bia"),
      Approve,
    ))
  let assert occurrence.Released(key:, ..) = released.status
  assert kit.effects_of(env.db, waiting.id) == 1
  let assert True =
    kit.eventually(20_000, fn() {
      case kit.tx(env, decisions.read(desk, _, occurrence: waiting.id)) {
        Ok(known) -> occurrence.effect(known) != option.None
        Error(_) -> False
      }
    })
  assert payouts(env, key) == 1
  let assert Ok(known) =
    kit.tx(env, decisions.read(desk, _, occurrence: waiting.id))
  assert occurrence.effect(known)
    == Some(Performed(Ref("provider.receipt", key, "rcpt-" <> key)))
  kit.check(env, [desk])
}

pub fn an_unknown_outcome_is_recorded_and_settled_by_a_lookup_test() {
  let #(name, store) = kit.store()
  let spec = kit.spec("payout_unknown")
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let assert Ok(_) =
    pog.query(
      "CREATE TABLE IF NOT EXISTS test_provider (key text PRIMARY KEY, receipt text NOT NULL)",
    )
    |> pog.execute(env.db)
  let assert Ok(waiting) =
    kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
  let assert Ok(released) =
    kit.tx(env, kit.open_and_decide(
      desk,
      _,
      waiting.id,
      kit.finance("bia"),
      Approve,
    ))
  let assert occurrence.Released(key:, ..) = released.status
  // The provider paid; its answer never arrived.
  let _ = provider_pay(env.db, key)
  let assert Ok(_) =
    kit.tx(env, decisions.report(
      desk,
      _,
      occurrence: waiting.id,
      effect: Uncertain("the provider did not answer within 10 s"),
    ))
  // Nothing retries blindly: a lookup under the same key settles it.
  let settled = case provider_lookup(env, key) {
    Ok(receipt) -> Performed(Ref("provider.receipt", key, receipt))
    Error(Nil) -> NotPerformed("the provider holds no payout under this key")
  }
  let assert Ok(known) =
    kit.tx(env, decisions.report(
      desk,
      _,
      occurrence: waiting.id,
      effect: settled,
    ))
  let assert Some(Performed(receipt)) = occurrence.effect(known)
  assert string.starts_with(receipt.revision, "rcpt-")
  assert payouts(env, key) == 1
  let assert occurrence.Released(..) = known.status
  kit.check(env, [desk])
}
