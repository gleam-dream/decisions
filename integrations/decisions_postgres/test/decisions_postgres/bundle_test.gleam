//// Bundles over PostgreSQL: the members of a bundle settle from many
//// connections at once while the Grind settlement worker hands each
//// notice to the point's follower, and every bundle starts exactly one
//// follow-on. The schema keeps a bundle's columns consistent, the port
//// bounds its key, and the version 1 append still writes for a node that
//// has not been upgraded yet.

import decisions
import decisions/store.{Head, Stored}
import decisions/vocabulary.{Approve, Reason, Reject}
import decisions/wire
import decisions_postgres
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import kit
import pog

fn count(env: kit.Env, sql: String, params: List(pog.Value)) -> Int {
  kit.scalar(env.db, sql, params, decode.int)
}

/// What follows the line point: once every member of the bundle has
/// settled, recommend the payout under a key derived from the bundle.
fn follower(
  items: decisions.Desk(String, decisions_postgres.Tx),
  payout: decisions.Desk(String, decisions_postgres.Tx),
) -> decisions_postgres.Follower {
  #(decisions.name(decisions.point_of(items)), fn(tx, id) {
    use known <- result.try(
      decisions.read(items, tx, occurrence: id)
      |> result.map_error(decisions.DeskRefused),
    )
    case known.bundle {
      None -> Ok(Nil)
      Some(bundle) -> {
        let report = vocabulary.bundle_key(bundle)
        use members <- result.try(
          decisions.members(items, tx, bundle: report)
          |> result.map_error(decisions.DeskRefused),
        )
        case decisions.is_complete(members) {
          False -> Ok(Nil)
          True ->
            decisions.recommend_once(
              payout,
              tx,
              key: "payout:" <> report,
              proposal: kit.proposal(
                decisions.name(decisions.point_of(payout)),
                kit.ana,
              ),
            )
            |> result.replace(Nil)
            |> result.map_error(decisions.DeskRefused)
        }
      }
    }
  })
}

fn decide_until_done(env, desk, id, verdict) -> Nil {
  case
    kit.tx(env, kit.open_and_decide(desk, _, id, kit.finance("bia"), verdict))
  {
    Ok(_) -> Nil
    Error(decisions_postgres.Contended(_)) ->
      decide_until_done(env, desk, id, verdict)
    Error(other) ->
      panic as { "deciding " <> id <> ": " <> string.inspect(other) }
  }
}

pub fn each_bundle_starts_exactly_one_payout_test() {
  let #(name, store) = kit.store()
  let items = kit.spec("bundle_line")
  let payout = kit.Spec(..kit.spec("bundle_payout"), policy: kit.proceed())
  let store = decisions_postgres.following(store, items.name)
  let item_desk = kit.desk(store, items)
  let payout_desk = kit.desk(store, payout)
  let options =
    kit.Options(
      ..kit.delivering(),
      concurrency: 20,
      pool_size: 40,
      deadline: duration.seconds(8),
    )
  use env <- kit.run(name, store, options, [], [
    follower(item_desk, payout_desk),
  ])
  let size = 5
  let bundles = list.map(kit.int_range(40), fn(_) { kit.tag("report") })
  let ids =
    list.flat_map(bundles, fn(bundle) {
      let assert Ok(admitted) =
        kit.tx(env, decisions.recommend_bundle(
          item_desk,
          _,
          bundle:,
          items: list.map(kit.int_range(size), fn(n) {
            #("l" <> int.to_string(n), kit.proposal(items.name, kit.ana))
          }),
        ))
      list.map(admitted, fn(known) { known.id })
    })
  let _ =
    kit.race(list.length(ids), 120_000, fn(n) {
      let assert Ok(id) = list.drop(ids, n) |> list.first
      process.sleep(int.random(200))
      let verdict = case n % 3 {
        0 -> Reject(Reason("no", None))
        _ -> Approve
      }
      decide_until_done(env, item_desk, id, verdict)
    })
  let assert True =
    kit.eventually(60_000, fn() {
      count(
        env,
        "SELECT count(*) FROM decisions_settled
         WHERE point = $1 AND delivered_at IS NULL",
        [pog.text(items.name)],
      )
      == 0
      && kit.effects(env.db, payout.name) == list.length(bundles)
    })
  // Exactly one payout per bundle, under its own key.
  list.each(bundles, fn(bundle) {
    assert count(env, "SELECT count(*) FROM test_effects WHERE key = $1", [
        pog.text("release:payout:" <> bundle),
      ])
      == 1
  })
  assert kit.effects(env.db, payout.name) == list.length(bundles)
  assert count(
      env,
      "SELECT count(*) FROM decisions_settled
       WHERE set_aside_at IS NOT NULL AND point IN ($1, $2)",
      [pog.text(items.name), pog.text(payout.name)],
    )
    == 0
  kit.check(env, [item_desk, payout_desk])
}

fn head(point: String, bundle: option.Option(vocabulary.Bundle)) -> store.Head {
  Head(
    point:,
    subject: kit.ana,
    status: store.Recommended,
    awaiting: [],
    due: None,
    arrived: wire.from_milliseconds(1_800_000_000_000),
    approved: [],
    may_not_decide: [],
    review_pending: False,
    bundle:,
  )
}

fn recommended() -> List(store.Stored) {
  [Stored(1, wire.from_milliseconds(1_800_000_000_000), "recommended", "{}")]
}

pub fn a_bundle_key_longer_than_an_id_is_refused_before_the_append_test() {
  let #(name, store) = kit.store()
  use env <- kit.run(name, store, kit.options(), [], [])
  let port = decisions_postgres.port(env.store)
  let long = string.repeat("k", decisions_postgres.max_name_bytes + 1)
  let id = kit.tag("long_bundle")
  let assert Error(store.Conflict(detail)) =
    kit.within(env, port.append(
      _,
      id,
      head(kit.tag("p"), Some(bundle_of(long, 1))),
      recommended(),
    ))
  assert string.contains(detail, "the bundle key")
  assert count(env, "SELECT count(*) FROM decisions_occurrences WHERE id = $1", [
      pog.text(id),
    ])
    == 0
}

pub fn the_schema_keeps_a_bundle_whole_test() {
  let #(name, store) = kit.store()
  use env <- kit.run(name, store, kit.options(), [], [])
  let port = decisions_postgres.port(env.store)
  let id = kit.tag("raw_bundle")
  let assert Ok(Nil) =
    kit.within(env, port.append(
      _,
      id,
      head(kit.tag("p"), Some(bundle_of(kit.tag("b"), 2))),
      recommended(),
    ))
  let violated = fn(sql) {
    case pog.query(sql) |> pog.parameter(pog.text(id)) |> pog.execute(env.db) {
      Ok(_) -> "accepted"
      Error(pog.ConstraintViolated(constraint:, ..)) -> constraint
      Error(error) -> string.inspect(error)
    }
  }
  assert violated(
      "UPDATE decisions_occurrences SET bundle_size = NULL WHERE id = $1",
    )
    == "decisions_occurrences_bundle"
  assert violated(
      "UPDATE decisions_occurrences SET bundle_size = 0 WHERE id = $1",
    )
    == "decisions_occurrences_bundle"
  assert violated(
      "UPDATE decisions_occurrences SET bundle_key = NULL WHERE id = $1",
    )
    == "decisions_occurrences_bundle"
}

/// A node still on the previous release calls the version 1 append: it
/// still writes, and leaves the bundle columns empty.
pub fn the_version_1_append_still_writes_test() {
  let #(name, store) = kit.store()
  use env <- kit.run(name, store, kit.options(), [], [])
  let id = kit.tag("v1")
  let assert Ok(_) =
    pog.query(
      "SELECT decisions_append($1, 'v1.point', 'person', 'ana', 'recommended',
         '{}'::text[], '{}'::text[], '{}'::text[], NULL, 1800000000000, false,
         ARRAY[1], ARRAY[1800000000000]::bigint[], ARRAY['recommended'],
         ARRAY['{}'])",
    )
    |> pog.parameter(pog.text(id))
    |> pog.execute(env.db)
  let assert Ok(Some(written)) =
    kit.within(env, decisions_postgres.inspection().head(_, id))
  assert written.bundle == None
  assert written.status == store.Recommended
}

pub fn members_reads_a_bundle_in_id_order_across_points_test() {
  let #(name, store) = kit.store()
  use env <- kit.run(name, store, kit.options(), [], [])
  let port = decisions_postgres.port(env.store)
  let bundle = bundle_of(kit.tag("b"), 3)
  let ids = [kit.tag("m-c"), kit.tag("m-a"), kit.tag("m-b")]
  list.index_map(ids, fn(id, n) {
    let assert Ok(Nil) =
      kit.within(env, port.append(
        _,
        id,
        head("point-" <> int.to_string(n % 2), Some(bundle)),
        recommended(),
      ))
  })
  let assert Ok(Nil) =
    kit.within(env, port.append(
      _,
      kit.tag("other"),
      head("point-0", None),
      recommended(),
    ))
  let assert Ok(found) =
    kit.within(env, port.members(_, vocabulary.bundle_key(bundle)))
  assert list.map(found, fn(pair) { pair.0 }) == list.sort(ids, string.compare)
  assert list.all(found, fn(pair) { { pair.1 }.bundle == Some(bundle) })
}

fn bundle_of(key: String, size: Int) -> vocabulary.Bundle {
  let assert Ok(made) = vocabulary.bundle(key:, size:)
  made
}
