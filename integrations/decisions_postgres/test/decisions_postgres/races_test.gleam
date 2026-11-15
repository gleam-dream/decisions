//// Condition A on real connections: many processes, each in its own
//// transaction, on one occurrence. Every scenario ends with the invariant
//// checker.

import decisions
import decisions/occurrence
import decisions/policy.{Policy, Proceed}
import decisions/vocabulary.{Approve, Reason, Reject}
import decisions_postgres.{Refused}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/time/duration
import kit

/// A1: forty validators decide one refund at once, twenty approving and
/// twenty rejecting, while eight processes deliver its wake-up and one
/// reports the event that supersedes it. One outcome stands, the tool ran
/// at most once (once exactly when an approval stands), and every loser is
/// told the occurrence no longer waits.
pub fn forty_verdicts_eight_wakes_and_a_supersession_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("a1"), superseded_by: ["closed"])
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options() |> pool(60), [], [])
  list.each(kit.int_range(5), fn(_) {
    let subject = vocabulary.Subject("person", kit.tag("ana"))
    let assert Ok(waiting) =
      kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, subject)))
    let id = waiting.id
    let results =
      kit.race(49, 30_000, fn(n) {
        case n {
          _ if n < 40 -> {
            let validator = kit.finance("v" <> int.to_string(n))
            let verdict = case n % 2 {
              0 -> Approve
              _ -> Reject(Reason("wrong", option.None))
            }
            #(
              "verdict",
              kit.tx(env, kit.open_and_decide(desk, _, id, validator, verdict))
                |> result_kind,
            )
          }
          _ if n < 48 -> #(
            "wake",
            kit.tx(env, decisions.wake(desk, _, occurrence: id))
              |> result_kind,
          )
          _ -> #(
            "happened",
            kit.tx(env, decisions.happened(desk, _, "closed", about: subject))
              |> result_kind,
          )
        }
      })
    let verdicts = list.filter(results, fn(r) { r.0 == "verdict" })
    let won = list.count(verdicts, fn(r) { r.1 == "ok" })
    // Every other verdict was refused as no longer waiting.
    assert list.all(verdicts, fn(r) {
      r.1 == "ok" || r.1 == "already decided" || r.1 == "not awaiting"
    })
    assert list.all(results, fn(r) { r.1 != "store" })
    let assert Ok(known) = kit.tx(env, decisions.read(desk, _, occurrence: id))
    let effects = kit.effects_of(env.db, id)
    case known.status {
      occurrence.Released(..) -> {
        assert won == 1
        assert effects == 1
      }
      occurrence.Rejected(_) -> {
        assert won == 1
        assert effects == 0
      }
      occurrence.Expired(_) -> {
        assert won == 0
        assert effects == 0
      }
      _ -> panic as "the occurrence still waits after the race"
    }
  })
  kit.check(env, [desk])
}

fn result_kind(result: Result(a, decisions_postgres.Failure)) -> String {
  case result {
    Ok(_) -> "ok"
    Error(Refused(decisions.AlreadyDecided(_))) -> "already decided"
    Error(Refused(decisions.NotAwaiting)) -> "not awaiting"
    Error(Refused(_)) -> "refused"
    Error(_) -> "store"
  }
}

fn pool(options: kit.Options, size: Int) -> kit.Options {
  kit.Options(..options, pool_size: size)
}

/// B1 and the absence lock: eight processes deliver one trigger at once
/// to a point that proceeds. One occurrence is made and released, the tool
/// runs once, and every delivery gets that occurrence back, not an error.
pub fn concurrent_recommend_once_makes_one_occurrence_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("b1"), policy: kit.proceed())
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options() |> pool(20), [], [])
  list.each(kit.int_range(20), fn(_) {
    let key = kit.tag("key")
    let proposal = kit.proposal(spec.name, kit.ana)
    let results =
      kit.race(8, 30_000, fn(_) {
        kit.tx(env, decisions.recommend_once(desk, _, key:, proposal:))
      })
    assert list.all(results, fn(result) {
      case result {
        Ok(found) ->
          found.id == key
          && case found.status {
            occurrence.Released(..) -> True
            _ -> False
          }
        Error(_) -> False
      }
    })
    assert kit.effects_of(env.db, key) == 1
  })
  kit.check(env, [desk])
}

/// A3: a held act is withdrawn by its author at the instant its hold ends
/// and its wake-up is delivered. Each trial ends withdrawn with no effect
/// or released with one: never both, never neither.
pub fn withdraw_races_the_wake_up_test() {
  let #(name, store) = kit.store()
  let spec =
    kit.Spec(
      ..kit.spec("a3"),
      policy: Policy(version: 1, rules: [], otherwise: Proceed(policy.Never)),
      hold: Some(duration.milliseconds(40)),
    )
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options(), [], [])
  let endings =
    list.map(kit.int_range(100), fn(_) {
      let assert Ok(held) =
        kit.tx(env, decisions.recommend(
          desk,
          _,
          kit.own_act(spec.name, by: "caio", about: kit.ana),
        ))
      // Aim the race at the hold's end; either ending is allowed, so this
      // wait chooses the moment and asserts nothing.
      process.sleep(38)
      let _ =
        kit.race(2, 30_000, fn(n) {
          case n {
            0 ->
              kit.tx(env, decisions.withdraw(
                desk,
                _,
                occurrence: held.id,
                by: "caio",
              ))
              |> result_kind
            _ ->
              kit.tx(env, decisions.wake(desk, _, occurrence: held.id))
              |> result_kind
          }
        })
      // A wake-up that came early is delivered again, as Grind would.
      let assert True =
        kit.eventually(2000, fn() {
          let _ = kit.tx(env, decisions.wake(desk, _, occurrence: held.id))
          let assert Ok(known) =
            kit.tx(env, decisions.read(desk, _, occurrence: held.id))
          occurrence.is_settled(known.status)
        })
      let assert Ok(known) =
        kit.tx(env, decisions.read(desk, _, occurrence: held.id))
      let effects = kit.effects_of(env.db, held.id)
      case known.status {
        occurrence.Withdrawn(_) -> {
          assert effects == 0
          "withdrawn"
        }
        occurrence.Released(..) -> {
          assert effects == 1
          "released"
        }
        _ -> panic as "neither withdrawn nor released"
      }
    })
  assert list.length(endings) == 100
  kit.check(env, [desk])
}

/// Superseding against deciding: ten occurrences about one subject, ten
/// validators each deciding one, and three processes reporting the event
/// that supersedes them, at once. Nobody deadlocks: every result is a
/// success or a typed refusal, never a store failure.
pub fn supersede_against_decide_never_deadlocks_test() {
  let #(name, store) = kit.store()
  let spec = kit.Spec(..kit.spec("super"), superseded_by: ["closed"])
  let desk = kit.desk(store, spec)
  use env <- kit.run(name, store, kit.options() |> pool(40), [], [])
  list.each(kit.int_range(10), fn(_) {
    let subject = vocabulary.Subject("person", kit.tag("ana"))
    let ids =
      list.map(kit.int_range(10), fn(_) {
        let assert Ok(waiting) =
          kit.tx(env, decisions.recommend(
            desk,
            _,
            kit.proposal(spec.name, subject),
          ))
        waiting.id
      })
    let results =
      kit.race(13, 60_000, fn(n) {
        case list.drop(ids, n) {
          [id, ..] if n < 10 ->
            kit.tx(env, kit.open_and_decide(
              desk,
              _,
              id,
              kit.finance("v" <> int.to_string(n)),
              Approve,
            ))
            |> result_kind
          _ ->
            kit.tx(env, decisions.happened(desk, _, "closed", about: subject))
            |> result_kind
        }
      })
    assert list.all(results, fn(kind) { kind != "store" })
  })
  kit.check(env, [desk])
}
