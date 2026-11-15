//// The record's rules are the database's rules: SQL that bypasses the
//// port cannot repeat a sequence number, leave a gap, release twice, store
//// an unknown entry kind, or change or remove an entry.

import decisions/store.{Head, Stored}
import decisions/wire
import decisions_postgres
import gleam/option.{None}
import gleam/string
import kit
import pog

fn first(env: kit.Env) -> String {
  let id = kit.tag("raw")
  let head =
    Head(
      point: kit.tag("raw_point"),
      subject: kit.ana,
      status: store.Recommended,
      awaiting: [],
      due: None,
      arrived: wire.from_milliseconds(1_800_000_000_000),
      approved: [],
      may_not_decide: [],
      review_pending: False,
    )
  let port = decisions_postgres.port(env.store)
  let assert Ok(Nil) =
    port.append(env.db, id, head, [
      Stored(1, wire.from_milliseconds(1_800_000_000_000), "recommended", "{}"),
      Stored(2, wire.from_milliseconds(1_800_000_000_001), "released", "{}"),
    ])
  id
}

fn insert(env: kit.Env, id: String, seq: Int, kind: String) -> String {
  case
    pog.query(
      "INSERT INTO decisions_entries (occurrence_id, seq, at, kind, event)
       VALUES ($1, $2, clock_timestamp(), $3, '{}')",
    )
    |> pog.parameter(pog.text(id))
    |> pog.parameter(pog.int(seq))
    |> pog.parameter(pog.text(kind))
    |> pog.execute(env.db)
  {
    Ok(_) -> "accepted"
    Error(pog.ConstraintViolated(constraint:, ..)) -> constraint
    Error(error) -> string.inspect(error)
  }
}

fn statement(env: kit.Env, sql: String, id: String) -> String {
  case pog.query(sql) |> pog.parameter(pog.text(id)) |> pog.execute(env.db) {
    Ok(_) -> "accepted"
    Error(pog.ConstraintViolated(constraint:, ..)) -> constraint
    Error(pog.PostgresqlError(code:, message:, ..)) -> code <> " " <> message
    Error(error) -> string.inspect(error)
  }
}

pub fn the_database_refuses_what_breaks_the_record_test() {
  let #(name, store) = kit.store()
  use env <- kit.run(name, store, kit.options(), [], [])
  let id = first(env)
  assert insert(env, id, 2, "noted") == "decisions_entries_pkey"
  assert insert(env, id, 4, "noted") == "decisions_entries_no_gap"
  assert insert(env, id, 3, "released") == "decisions_entries_one_release"
  assert insert(env, id, 3, "shadowed") == "decisions_entries_kind"
  assert insert(env, id, 3, "noted") == "accepted"
  assert statement(
      env,
      "UPDATE decisions_entries SET event = '{\"x\":1}' WHERE occurrence_id = $1",
      id,
    )
    == "23001 decisions_entries is append-only"
  assert statement(
      env,
      "DELETE FROM decisions_entries WHERE occurrence_id = $1",
      id,
    )
    == "23001 decisions_entries is append-only"
}
