//// The queue queries read heads only. Their order and filters, and, at
//// volume, that each is served by its index.

import decisions
import decisions/policy.{AnyoneHolding, Ask, PerCent, Policy, Proceed, Several}
import decisions/store
import decisions/vocabulary.{Approve, Subject, Validator}
import decisions_postgres
import decisions_postgres/queue
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import kit
import pog

/// A queue across points: the soonest due first, those without a due time
/// last, arrival order within one due time. Left out: another set's
/// occurrences, those this validator already approved under four eyes,
/// and those they asked for under `SomeoneElseHolding`.
pub fn a_page_orders_by_due_time_and_leaves_out_what_is_not_mine_test() {
  let #(name, store) = kit.store()
  let set = kit.tag("finance")
  let ask = fn(eligible) {
    Policy(version: 1, rules: [], otherwise: Ask(eligible))
  }
  let short =
    kit.Spec(
      ..kit.spec("short"),
      policy: ask(AnyoneHolding(set)),
      validity: Some(duration.minutes(30)),
    )
  let long =
    kit.Spec(
      ..kit.spec("long"),
      policy: ask(AnyoneHolding(set)),
      validity: Some(duration.hours(2)),
    )
  let open_ended = kit.Spec(..kit.spec("open"), policy: ask(AnyoneHolding(set)))
  let four_eyes =
    kit.Spec(
      ..kit.spec("four_eyes"),
      policy: ask(Several(2, AnyoneHolding(set))),
    )
  let someone_else =
    kit.Spec(
      ..kit.spec("someone_else"),
      policy: ask(policy.SomeoneElseHolding(set)),
    )
  let elsewhere =
    kit.Spec(
      ..kit.spec("elsewhere"),
      policy: ask(AnyoneHolding(kit.tag("ops"))),
    )
  let desks =
    list.map(
      [short, long, open_ended, four_eyes, elsewhere, someone_else],
      kit.desk(store, _),
    )
  let assert [
    short_desk,
    long_desk,
    open_desk,
    four_desk,
    elsewhere_desk,
    someone_else_desk,
  ] = desks
  use env <- kit.run(name, store, kit.options(), [], [])
  let recommend = fn(desk, spec: kit.Spec) {
    let assert Ok(made) =
      kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
    made.id
  }
  let open_1 = recommend(open_desk, open_ended)
  let long_1 = recommend(long_desk, long)
  let short_1 = recommend(short_desk, short)
  let short_2 = recommend(short_desk, short)
  let four_1 = recommend(four_desk, four_eyes)
  let _ = recommend(elsewhere_desk, elsewhere)
  let bia = Validator(kit.tag("bia"), [set])
  let caio = Validator(kit.tag("caio"), [set])
  // Caio asked for this one, so only someone else may decide it.
  let assert Ok(asked) =
    kit.tx(env, decisions.recommend(
      someone_else_desk,
      _,
      kit.proposal(someone_else.name, kit.ana)
        |> decisions.asked_by(caio.subject),
    ))
  // Bia gives the first of two approvals.
  let assert Ok(_) =
    kit.tx(env, kit.open_and_decide(four_desk, _, four_1, bia, Approve))
  let ids = fn(validator) {
    let assert Ok(page) =
      queue.page(env.db, for: validator, limit: 50, after: None)
    list.map(page, fn(card) { card.occurrence })
  }
  assert ids(bia) == [short_1, short_2, long_1, open_1, asked.id]
  assert ids(caio) == [short_1, short_2, long_1, open_1, four_1]
  // Pages follow on from the last card.
  let assert Ok([first, second]) =
    queue.page(env.db, for: caio, limit: 2, after: None)
  let assert Ok(rest) =
    queue.page(env.db, for: caio, limit: 50, after: Some(second))
  assert [
      first.occurrence,
      second.occurrence,
      ..list.map(rest, fn(c) { c.occurrence })
    ]
    == ids(caio)
  let assert Ok(next) =
    queue.page(env.db, for: caio, limit: 2, after: Some(second))
  assert list.map(next, fn(c) { c.occurrence }) == [long_1, open_1]
  // Neither card Caio may not decide is anywhere on his pages.
  assert !list.contains(ids(caio), asked.id)
  // A validator holding no set sees nothing.
  assert ids(Validator(kit.tag("nobody"), [])) == []
  kit.check(env, desks)
}

pub fn counts_subjects_reviews_and_positions_test() {
  let #(name, store) = kit.store()
  let sampled =
    kit.Spec(
      ..kit.spec("sampled"),
      policy: Policy(version: 1, rules: [], otherwise: Proceed(PerCent(100))),
    )
  let waiting = kit.spec("counted")
  let sampled_desk = kit.desk(store, sampled)
  let waiting_desk = kit.desk(store, waiting)
  use env <- kit.run(name, store, kit.options(), [], [])
  let subject = Subject("company", kit.tag("clinica"))
  let assert Ok(released) =
    kit.tx(env, decisions.recommend(
      sampled_desk,
      _,
      kit.proposal(sampled.name, subject),
    ))
  let made =
    list.map(kit.int_range(3), fn(_) {
      let assert Ok(made) =
        kit.tx(env, decisions.recommend(
          waiting_desk,
          _,
          kit.proposal(waiting.name, subject),
        ))
      made.id
    })
  let assert [one, ..] = made
  let assert Ok(_) =
    kit.tx(env, kit.open_and_decide(
      waiting_desk,
      _,
      one,
      kit.finance("bia"),
      Approve,
    ))
  let assert Ok(counts) = queue.counts(env.db, waiting.name)
  assert counts
    == [queue.Count(store.Awaiting, 2), queue.Count(store.Released, 1)]
  let assert Ok(about) = queue.about(env.db, subject, limit: 10)
  assert list.length(about) == 4
  let assert Ok(last) = list.last(about)
  assert last.occurrence == released.id
  let assert Ok(reviews) = queue.review_queue(env.db, sampled.name, limit: 10)
  assert reviews == [released.id]
  let assert Ok(positions) = queue.positions(env.db, [one, kit.tag("absent")])
  let assert [#(id, seq)] = positions
  assert id == one
  assert seq >= 4
  kit.check(env, [sampled_desk, waiting_desk])
}

/// A desk for one point reads its own page; the review queue across
/// points; every occurrence of a point and those settled since a time,
/// paged, for learning and export.
pub fn point_pages_reviews_and_exports_test() {
  let #(name, store) = kit.store()
  let one = kit.spec("one_point")
  let other = kit.spec("other_point")
  let sampled =
    kit.Spec(
      ..kit.spec("sampled_all"),
      policy: Policy(version: 1, rules: [], otherwise: Proceed(PerCent(100))),
    )
  let one_desk = kit.desk(store, one)
  let other_desk = kit.desk(store, other)
  let sampled_desk = kit.desk(store, sampled)
  use env <- kit.run(name, store, kit.options(), [], [])
  let recommend = fn(desk, spec: kit.Spec) {
    let assert Ok(made) =
      kit.tx(env, decisions.recommend(desk, _, kit.proposal(spec.name, kit.ana)))
    made.id
  }
  let mine = list.map(kit.int_range(5), fn(_) { recommend(one_desk, one) })
  let _ = list.map(kit.int_range(3), fn(_) { recommend(other_desk, other) })
  let viewer = kit.finance(kit.tag("viewer"))
  let assert Ok(page) =
    queue.page_at(env.db, point: one.name, for: viewer, limit: 3, after: None)
  let assert Ok(last) = list.last(page)
  let assert Ok(rest) =
    queue.page_at(
      env.db,
      point: one.name,
      for: viewer,
      limit: 50,
      after: Some(last),
    )
  assert list.map(list.append(page, rest), fn(c) { c.occurrence }) == mine
  // Reviews across points.
  let reviewed = recommend(sampled_desk, sampled)
  let assert Ok(reviews) = queue.review_queue_all(env.db, limit: 1000)
  assert list.any(reviews, fn(r) { r.occurrence == reviewed })
  // Every record of a point, two at a time.
  let all =
    page_through(
      fn(after) {
        let assert Ok(found) =
          queue.occurrences_of(env.db, point: one.name, limit: 2, after:)
        list.map(found, fn(r) { r.occurrence })
      },
      None,
      [],
    )
  assert all == list.sort(mine, string.compare)
  // Settled since a time: decide three, then read them in pages of two.
  let since = decisions_postgres.port(store).now(env.db)
  let decided =
    list.map(list.take(mine, 3), fn(id) {
      let assert Ok(_) =
        kit.tx(env, kit.open_and_decide(one_desk, _, id, viewer, Approve))
      id
    })
  let assert Ok(first) =
    queue.settled_since(env.db, point: one.name, since:, limit: 2, after: None)
  let assert Ok(last_settled) = list.last(first)
  let assert Ok(second) =
    queue.settled_since(
      env.db,
      point: one.name,
      since:,
      limit: 2,
      after: Some(last_settled),
    )
  let settled = list.append(first, second)
  assert list.sort(list.map(settled, fn(s) { s.occurrence }), string.compare)
    == list.sort(decided, string.compare)
  assert list.all(settled, fn(s) { s.status == store.Released })
  kit.check(env, [one_desk, other_desk, sampled_desk])
}

fn page_through(
  read: fn(option.Option(String)) -> List(String),
  after: option.Option(String),
  found: List(String),
) -> List(String) {
  case read(after) {
    [] -> found
    page -> {
      let assert Ok(last) = list.last(page)
      page_through(read, Some(last), list.append(found, page))
    }
  }
}

/// 10 000 heads and 20 000 queue rows over many points and subjects, then
/// the plan of each query. Each names its index and none scans a table.
pub fn every_query_is_served_by_its_index_at_volume_test() {
  let #(name, store) = kit.store()
  use env <- kit.run(name, store, kit.options(), [], [])
  let tag = kit.tag("vol")
  let assert Ok(_) =
    pog.query(
      "INSERT INTO decisions_occurrences
         (id, point, subject_kind, subject_id, status, awaiting, approved,
          may_not_decide, due, arrived, review_pending, last_seq)
       SELECT $1 || '-' || n, $1 || '-p' || (n % 20), 'person', 's' || (n % 500),
              CASE WHEN n % 3 = 0 THEN 'released' ELSE 'awaiting' END,
              ARRAY['set' || (n % 10)], ARRAY[]::text[], ARRAY[]::text[],
              clock_timestamp() + (n % 97) * interval '1 minute',
              clock_timestamp() - n * interval '1 second', n % 50 = 0, 2
       FROM generate_series(1, 10000) AS n",
    )
    |> pog.parameter(pog.text(tag))
    |> pog.execute(env.db)
  let assert Ok(_) =
    pog.query(
      "INSERT INTO decisions_awaiting
         (occurrence_id, set_name, point, due_order, arrived, may_not_decide)
       SELECT id, s, point, due, arrived, ARRAY[]::text[]
       FROM decisions_occurrences, unnest(ARRAY['set' || (last_seq), awaiting[1]]) AS s
       WHERE id LIKE $1 || '-%' AND status = 'awaiting'
       ON CONFLICT DO NOTHING",
    )
    |> pog.parameter(pog.text(tag))
    |> pog.execute(env.db)
  let assert Ok(_) =
    pog.query(
      "INSERT INTO decisions_settled (point, occurrence_id, admitted_at)
       SELECT $1 || '-export', id, arrived FROM decisions_occurrences
       WHERE id LIKE $1 || '-%' AND status = 'released'",
    )
    |> pog.parameter(pog.text(tag))
    |> pog.execute(env.db)
  let assert Ok(_) = pog.query("ANALYZE") |> pog.execute(env.db)
  let plan = fn(sql: String, parameters: List(pog.Value)) {
    let query =
      list.fold(parameters, pog.query("EXPLAIN " <> sql), pog.parameter)
      |> pog.returning(decode.at([0], decode.string))
    let assert Ok(returned) = pog.execute(query, env.db)
    string.join(returned.rows, "\n")
  }
  let served_by = fn(text: String, index: String) {
    case string.contains(text, index) && !string.contains(text, "Seq Scan") {
      True -> Nil
      False -> panic as { "expected " <> index <> " in\n" <> text }
    }
  }
  served_by(
    plan(
      "SELECT a.occurrence_id FROM unnest($1::text[]) AS s (set_name)
       CROSS JOIN LATERAL (
         SELECT a.occurrence_id FROM decisions_awaiting a
         WHERE a.set_name = s.set_name AND NOT ($2 = ANY (a.may_not_decide))
           AND (a.due_order, a.arrived, a.occurrence_id) > ('-infinity', '-infinity', '')
         ORDER BY a.due_order, a.arrived, a.occurrence_id LIMIT 50) AS a",
      [pog.array(pog.text, ["set1", "set2"]), pog.text("bia")],
    ),
    "decisions_awaiting_queue",
  )
  served_by(
    plan(
      "SELECT a.occurrence_id FROM unnest($1::text[]) AS s (set_name)
       CROSS JOIN LATERAL (
         SELECT a.occurrence_id FROM decisions_awaiting a
         WHERE a.set_name = s.set_name AND a.point = $3
           AND NOT ($2 = ANY (a.may_not_decide))
           AND (a.due_order, a.arrived, a.occurrence_id) > ('-infinity', '-infinity', '')
         ORDER BY a.due_order, a.arrived, a.occurrence_id LIMIT 50) AS a",
      [
        pog.array(pog.text, ["set1", "set2"]),
        pog.text("bia"),
        pog.text(tag <> "-p1"),
      ],
    ),
    "decisions_awaiting_point_queue",
  )
  served_by(
    plan(
      "SELECT id FROM decisions_occurrences WHERE review_pending
       ORDER BY arrived, id LIMIT 20",
      [],
    ),
    "decisions_occurrences_review_all",
  )
  served_by(
    plan(
      "SELECT id FROM decisions_occurrences
       WHERE point = $1 AND (point, id) > ($1, $2::text COLLATE \"C\")
       ORDER BY point, id LIMIT 100",
      [pog.text(tag <> "-p1"), pog.text("")],
    ),
    "decisions_occurrences_point",
  )
  served_by(
    plan(
      "SELECT s.occurrence_id FROM decisions_settled s
       WHERE s.point = $1
         AND (s.admitted_xid, s.id) > ('0'::xid8, 0)
         AND s.admitted_xid < pg_snapshot_xmin(pg_current_snapshot())
       ORDER BY s.admitted_xid, s.id LIMIT 100",
      [pog.text(tag <> "-export")],
    ),
    "decisions_settled_point",
  )
  served_by(
    plan(
      "SELECT status, count(*) FROM decisions_occurrences WHERE point = $1 GROUP BY status",
      [pog.text(tag <> "-p3")],
    ),
    "decisions_occurrences_status",
  )
  served_by(
    plan(
      "SELECT id FROM decisions_occurrences WHERE subject_kind = $1 AND subject_id = $2
       ORDER BY arrived DESC, id DESC LIMIT 20",
      [pog.text("person"), pog.text("s7")],
    ),
    "decisions_occurrences_subject",
  )
  served_by(
    plan(
      "SELECT id FROM decisions_occurrences WHERE point = $1 AND review_pending
       ORDER BY arrived, id LIMIT 20",
      [pog.text(tag <> "-p0")],
    ),
    "decisions_occurrences_review",
  )
  served_by(
    plan(
      "SELECT id FROM decisions_occurrences
       WHERE point = $1 AND subject_kind = $2 AND subject_id = $3
         AND status IN ('recommended', 'awaiting') AND set_aside_at IS NULL
       ORDER BY id",
      [pog.text(tag <> "-p1"), pog.text("person"), pog.text("s1")],
    ),
    "decisions_occurrences_waiting",
  )
  // The page itself, as `queue.page` runs it, returns a full page; its
  // cost is the plan above, and the scale run measures it.
  let assert Ok(page) =
    queue.page(
      env.db,
      for: Validator("bia", ["set1", "set2"]),
      limit: 50,
      after: None,
    )
  assert list.length(page) == 50
}
