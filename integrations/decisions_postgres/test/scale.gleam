//// The scale run: H1 to H6 of STRESS.md against a real PostgreSQL, the
//// savepoint's cost and the NOTIFY latency. Not part of `gleam test`; run
//// it with `bash scripts/test-postgres.sh scale` from the repository root.
//// It prints one line per measurement.

import decisions.{type Desk}
import decisions/store
import decisions/vocabulary.{Approve, Subject}
import decisions_postgres
import decisions_postgres/live
import decisions_postgres/queue
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleam/time/timestamp
import kit
import pog

@external(erlang, "kit_ffi", "machine")
fn machine() -> String

const pool_size = 24

pub fn main() -> Nil {
  io.println("machine: " <> machine())
  let #(name, store) = kit.store()
  let proceeding = kit.Spec(..kit.spec("h1"), policy: kit.proceed())
  let proceeding_desk = kit.desk(store, proceeding)
  let no_savepoint_desk =
    kit.desk_over(
      store.Port(..decisions_postgres.port(store), atomically: fn(tx, body) {
        Ok(body(tx))
      }),
      kit.Spec(..proceeding, name: kit.tag("h1_no_savepoint")),
    )
  let waiting = kit.spec("h2")
  let waiting_desk = kit.desk(store, waiting)
  let held = kit.Spec(..kit.spec("h5"), policy: kit.proceed())
  let options =
    kit.Options(
      ..kit.delivering(),
      pool_size:,
      concurrency: 16,
      deadline: duration.seconds(4),
    )
  // H5's holds are created over a frozen store clock (below), so they all
  // end in one millisecond; the waker that releases them reads the real
  // clock.
  let held_desk =
    kit.desk(store, kit.Spec(..held, hold: Some(duration.seconds(12))))
  use env <- kit.run(name, store, options, [decisions.waker(held_desk)], [])
  io.println(
    "database: "
    <> kit.scalar(env.db, "SELECT version()", [], decode.string)
    <> "; pool of "
    <> int.to_string(pool_size)
    <> " connections shared by the workers and Grind",
  )
  h1(env, proceeding_desk, proceeding.name, no_savepoint_desk)
  h1_decomposed(proceeding.name)
  h2(env, waiting_desk, waiting.name)
  // An assessment needs a settled occurrence: H3 grows released ones.
  h3(env, proceeding_desk, proceeding.name)
  h4(env)
  h5(env, store, held)
  h6(env, waiting_desk)
  notify_latency(env, waiting_desk, waiting.name)
}

// -- H1 -----------------------------------------------------------------------------

fn h1(
  env: kit.Env,
  desk: Desk(String, decisions_postgres.Tx),
  point: String,
  no_savepoint: Desk(String, decisions_postgres.Tx),
) -> Nil {
  list.each([1, 4, 16], fn(processes) {
    let #(wall, latencies) =
      spread(10_000, processes, fn(_) {
        let assert Ok(_) =
          kit.tx(env, decisions.recommend(desk, _, kit.proposal(point, kit.ana)))
        Nil
      })
    report(
      "H1 10 000 recommendations the policy proceeds, "
        <> int.to_string(processes)
        <> " processes",
      wall,
      10_000,
      latencies,
    )
  })
  let #(wall, latencies) =
    spread(10_000, 16, fn(_) {
      let assert Ok(_) =
        kit.tx(env, decisions.recommend(
          no_savepoint,
          _,
          kit.proposal(point, kit.ana),
        ))
      Nil
    })
  report(
    "H1 the same without the savepoint (atomically runs the tool bare), 16 processes",
    wall,
    10_000,
    latencies,
  )
}

/// Where H1's time at one connection goes: each variant removes one more
/// cost, 3 000 recommendations each, one process.
fn h1_decomposed(point: String) -> Nil {
  let #(name, store) = kit.store()
  let spec =
    kit.Spec(
      ..kit.spec("h1_parts"),
      policy: kit.proceed(),
      name: point <> "-parts",
    )
  let options = kit.Options(..kit.options(), pool_size: pool_size)
  use env <- kit.run(name, store, options, [], [])
  let base = decisions_postgres.port(store)
  let node_clock = store.Port(..base, now: fn(_) { timestamp.system_time() })
  let bare = store.Port(..node_clock, atomically: fn(tx, body) { Ok(body(tx)) })
  let run = fn(what: String, port: store.Port(decisions_postgres.Tx)) {
    let desk = kit.desk_over(port, spec)
    let #(wall, latencies) =
      spread(3000, 1, fn(_) {
        let assert Ok(_) =
          kit.tx(env, decisions.recommend(
            desk,
            _,
            kit.proposal(spec.name, kit.ana),
          ))
        Nil
      })
    report("H1 parts, 1 process, " <> what, wall, 3000, latencies)
  }
  let clock_reads =
    list.map(kit.int_range(500), fn(_) {
      let started = kit.monotonic_us()
      let _ = kit.within(env, base.now)
      kit.monotonic_us() - started
    })
  report_latency(
    "H1 parts: one read of the store's clock (a query)",
    clock_reads,
  )
  run("no Grind consumers on the pool", base)
  run("and the node's clock instead of the database's", node_clock)
  run("and no savepoint", bare)
  let assert Ok(_) =
    pog.query(
      "ALTER TABLE decisions_entries DROP CONSTRAINT decisions_entries_no_gap",
    )
    |> pog.execute(env.db)
  run("and no gap-check foreign key", bare)
  let assert Ok(_) =
    pog.query(
      "ALTER TABLE decisions_entries ADD CONSTRAINT decisions_entries_no_gap
       FOREIGN KEY (occurrence_id, previous)
       REFERENCES decisions_entries (occurrence_id, seq)",
    )
    |> pog.execute(env.db)
  Nil
}

// -- H2 -----------------------------------------------------------------------------

fn h2(
  env: kit.Env,
  desk: Desk(String, decisions_postgres.Tx),
  point: String,
) -> Nil {
  let made =
    collect(10_000, 16, fn(_) {
      let assert Ok(made) =
        kit.tx(env, decisions.recommend(desk, _, kit.proposal(point, kit.ana)))
      made.id
    })
  report("H2 make 10 000 waiting, 16 processes", made.0, 10_000, made.1)
  let ids = made.2
  let assert Ok(_) = pog.query("ANALYZE") |> pog.execute(env.db)
  let viewer = vocabulary.Validator("viewer", ["finance"])
  let pages =
    list.map(kit.int_range(200), fn(_) {
      let started = kit.monotonic_us()
      let assert Ok(page) =
        queue.page(env.pool, for: viewer, limit: 50, after: None)
      let assert 50 = list.length(page)
      kit.monotonic_us() - started
    })
  report_latency("H2 a queue page of 50 from 10 000 waiting, 200 reads", pages)
  // Sixteen validators decide 10 000 between them, each its own share.
  let shares = chunk(ids, 16)
  let started = kit.monotonic_us()
  let latencies =
    kit.race(16, 600_000, fn(n) {
      let assert Ok(share) = list.drop(shares, n) |> list.first
      let validator = kit.finance("validator-" <> int.to_string(n))
      list.map(share, fn(id) {
        let begun = kit.monotonic_us()
        let assert Ok(_) =
          kit.tx(env, kit.open_and_decide(desk, _, id, validator, Approve))
        kit.monotonic_us() - begun
      })
    })
    |> list.flatten
  report(
    "H2 open and decide all 10 000 (one transaction each), 16 validators",
    kit.monotonic_us() - started,
    10_000,
    latencies,
  )
}

// -- H3 -----------------------------------------------------------------------------

fn h3(
  env: kit.Env,
  desk: Desk(String, decisions_postgres.Tx),
  point: String,
) -> Nil {
  let port = decisions_postgres.port(env.store)
  list.each([10, 100, 1000], fn(size) {
    let assert Ok(made) =
      kit.tx(env, decisions.recommend(desk, _, kit.proposal(point, kit.ana)))
    // Assessments make up the entries the recommendation did not make.
    list.each(kit.int_range(size - list.length(made.entries)), fn(_) {
      let assert Ok(_) =
        kit.tx(env, decisions.assess(
          desk,
          _,
          occurrence: made.id,
          finding: vocabulary.Assessment(
            finding: vocabulary.Right,
            evidence: vocabulary.Ref("scale", "assessment", "1"),
            source: "scale",
            known_at: timestamp.system_time(),
          ),
        ))
    })
    let reads =
      list.map(kit.int_range(40), fn(_) {
        let started = kit.monotonic_us()
        let assert Ok(known) =
          kit.tx(env, decisions.read(desk, _, occurrence: made.id))
        let assert True = list.length(known.entries) == size
        kit.monotonic_us() - started
      })
    report_latency(
      "H3 read (load, decode, fold) of "
        <> int.to_string(size)
        <> " entries, 40 reads",
      reads,
    )
    let loads =
      list.map(kit.int_range(40), fn(_) {
        let started = kit.monotonic_us()
        let assert Ok(rows) = kit.within(env, port.load(_, made.id))
        let assert True = list.length(rows) == size
        kit.monotonic_us() - started
      })
    report_latency(
      "H3 the port's load alone of " <> int.to_string(size) <> " entries",
      loads,
    )
    let appends =
      list.map(kit.int_range(20), fn(_) {
        let started = kit.monotonic_us()
        let assert Ok(_) =
          kit.tx(env, decisions.assess(
            desk,
            _,
            occurrence: made.id,
            finding: vocabulary.Assessment(
              finding: vocabulary.Right,
              evidence: vocabulary.Ref("scale", "assessment", "1"),
              source: "scale",
              known_at: timestamp.system_time(),
            ),
          ))
        kit.monotonic_us() - started
      })
    report_latency(
      "H3 one more append (assess) at " <> int.to_string(size) <> " entries",
      appends,
    )
  })
}

// -- H4 -----------------------------------------------------------------------------

fn h4(env: kit.Env) -> Nil {
  let spec = kit.Spec(..kit.spec("h4"), superseded_by: ["closed"])
  let desk = kit.desk(env.store, spec)
  let subject = Subject("person", kit.tag("h4"))
  let _ =
    collect(1000, 16, fn(_) {
      let assert Ok(_) =
        kit.tx(env, decisions.recommend(
          desk,
          _,
          kit.proposal(spec.name, subject),
        ))
      Nil
    })
  let started = kit.monotonic_us()
  let assert Ok(done) =
    kit.tx(env, decisions.happened(desk, _, "closed", about: subject))
  let took = kit.monotonic_us() - started
  io.println(
    "H4 1 000 waiting about one subject, one happened: "
    <> ms(took)
    <> " ms, "
    <> int.to_string(list.length(done.expired))
    <> " expired in one transaction",
  )
}

// -- H5 -----------------------------------------------------------------------------

fn h5(env: kit.Env, store: decisions_postgres.Store, held: kit.Spec) -> Nil {
  // Every hold is created with the store's clock frozen at `start`, so all
  // 5 000 end at the same millisecond, `start + 12 s`.
  let port = decisions_postgres.port(store)
  let start = kit.within(env, port.now)
  let frozen = store.Port(..port, now: fn(_) { start })
  let creating =
    kit.desk_over(frozen, kit.Spec(..held, hold: Some(duration.seconds(12))))
  let made =
    collect(5000, 16, fn(_) {
      let assert Ok(_) =
        kit.tx(env, decisions.recommend(
          creating,
          _,
          kit.proposal(held.name, kit.ana),
        ))
      Nil
    })
  let ends = timestamp.add(start, duration.seconds(12))
  let created_in = made.0
  let assert True =
    kit.eventually(120_000, fn() { kit.effects(env.db, held.name) == 5000 })
  let last =
    kit.scalar(
      env.db,
      "SELECT decisions_ms(max(written_at)) FROM test_effects WHERE point = $1",
      [pog.text(held.name)],
      decode.int,
    )
  let took = last - wire_ms(ends)
  io.println(
    "H5 5 000 holds end in the same millisecond (created in "
    <> ms(created_in)
    <> " ms), released through Grind, 16 jobs at once, poll 50 ms: "
    <> int.to_string(took)
    <> " ms from the hold's end to the 5 000th release, "
    <> rate(5000, took * 1000)
    <> "/s",
  )
}

fn wire_ms(at: timestamp.Timestamp) -> Int {
  let #(seconds, nanoseconds) = timestamp.to_unix_seconds_and_nanoseconds(at)
  seconds * 1000 + nanoseconds / 1_000_000
}

// -- H6 -----------------------------------------------------------------------------

/// The database's half of a replay: read 10 000 records (load, decode and
/// fold), with 1 and 16 processes. The candidate itself is pure and runs
/// in `decisions/learning` and `decisions_otp/replay`.
fn h6(env: kit.Env, desk: Desk(String, decisions_postgres.Tx)) -> Nil {
  let point = decisions.name(decisions.point_of(desk))
  let assert Ok(ids) =
    kit.within(env, decisions_postgres.inspection().occurrences(_, point))
  let ids = list.take(ids, 10_000)
  list.each([1, 16], fn(processes) {
    let shares = chunk(ids, processes)
    let started = kit.monotonic_us()
    let _ =
      kit.race(processes, 600_000, fn(n) {
        let assert Ok(share) = list.drop(shares, n) |> list.first
        list.each(share, fn(id) {
          let assert Ok(_) =
            kit.tx(env, decisions.read(desk, _, occurrence: id))
        })
      })
    let wall = kit.monotonic_us() - started
    io.println(
      "H6 read "
      <> int.to_string(list.length(ids))
      <> " records for replay, "
      <> int.to_string(processes)
      <> " processes: "
      <> ms(wall)
      <> " ms, "
      <> rate(list.length(ids), wall)
      <> "/s",
    )
  })
}

// -- NOTIFY -------------------------------------------------------------------------

fn notify_latency(
  env: kit.Env,
  desk: Desk(String, decisions_postgres.Tx),
  point: String,
) -> Nil {
  let assert Ok(started) = live.start(env.config)
  let changes = process.new_subject()
  let assert Ok(_) =
    live.subscribe(started.data, changes, to: live.Point(point))
  let waits =
    list.map(kit.int_range(300), fn(_) {
      let begun = kit.monotonic_us()
      let assert Ok(made) =
        kit.tx(env, decisions.recommend(desk, _, kit.proposal(point, kit.ana)))
      let returned = kit.monotonic_us()
      let assert Ok(change) = process.receive(changes, 5000)
      let assert True = change.occurrence == made.id
      let received = kit.monotonic_us()
      #(received - begun, received - returned)
    })
  report_latency(
    "NOTIFY from the start of the appending transaction to the subscriber, 300 appends",
    list.map(waits, fn(w) { w.0 }),
  )
  report_latency(
    "NOTIFY after the transaction returned to the writer (0 when it arrived first)",
    list.map(waits, fn(w) { int.max(0, w.1) }),
  )
  process.unlink(started.pid)
  process.kill(started.pid)
}

// -- Helpers -------------------------------------------------------------------------

/// Run `count` calls of `work` spread over `processes`, and return the wall
/// time and each call's latency, in microseconds.
fn spread(
  count: Int,
  processes: Int,
  work: fn(Int) -> Nil,
) -> #(Int, List(Int)) {
  let #(wall, latencies, _) = collect(count, processes, work)
  #(wall, latencies)
}

fn collect(
  count: Int,
  processes: Int,
  work: fn(Int) -> a,
) -> #(Int, List(Int), List(a)) {
  let shares = chunk(kit.int_range(count), processes)
  let started = kit.monotonic_us()
  let results =
    kit.race(processes, 600_000, fn(n) {
      let assert Ok(share) = list.drop(shares, n) |> list.first
      list.map(share, fn(item) {
        let begun = kit.monotonic_us()
        let value = work(item)
        #(kit.monotonic_us() - begun, value)
      })
    })
    |> list.flatten
  #(
    kit.monotonic_us() - started,
    list.map(results, fn(r) { r.0 }),
    list.map(results, fn(r) { r.1 }),
  )
}

/// `items` in `parts` shares of nearly equal size.
fn chunk(items: List(a), parts: Int) -> List(List(a)) {
  let indexed = list.index_map(items, fn(item, i) { #(i % parts, item) })
  list.map(kit.int_range(parts), fn(part) {
    list.filter_map(indexed, fn(pair) {
      case pair.0 == part {
        True -> Ok(pair.1)
        False -> Error(Nil)
      }
    })
  })
}

fn report(what: String, wall: Int, count: Int, latencies: List(Int)) -> Nil {
  io.println(
    what
    <> ": "
    <> ms(wall)
    <> " ms, "
    <> rate(count, wall)
    <> "/s; per call median "
    <> ms(percentile(latencies, 50))
    <> " ms, p95 "
    <> ms(percentile(latencies, 95))
    <> " ms",
  )
}

fn report_latency(what: String, latencies: List(Int)) -> Nil {
  io.println(
    what
    <> ": median "
    <> ms(percentile(latencies, 50))
    <> " ms, p95 "
    <> ms(percentile(latencies, 95))
    <> " ms, max "
    <> ms(list.fold(latencies, 0, int.max))
    <> " ms",
  )
}

fn percentile(values: List(Int), p: Int) -> Int {
  let sorted = list.sort(values, int.compare)
  let n = list.length(sorted)
  let index = int.min(n - 1, { n * p } / 100)
  list.drop(sorted, index) |> list.first |> result_or(0)
}

fn result_or(result: Result(a, Nil), default: a) -> a {
  case result {
    Ok(value) -> value
    Error(Nil) -> default
  }
}

fn ms(microseconds: Int) -> String {
  float.to_string(int.to_float(microseconds / 10) /. 100.0)
}

fn rate(count: Int, microseconds: Int) -> String {
  case microseconds {
    0 -> "inf"
    _ -> int.to_string(count * 1_000_000 / microseconds)
  }
}
