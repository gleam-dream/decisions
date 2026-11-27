//// The schema: `migrate` applies it once however often and from however
//// many callers it runs, the SQL shipped in `priv/migrations` is the same
//// statements, and the constraints name exactly the core's entry kinds and
//// head statuses.

import decisions/entry
import decisions/store
import decisions_postgres
import decisions_postgres/internal/migrations
import gleam/dynamic/decode
import gleam/list
import gleam/string
import kit

/// The SQL file a migration ships, as `migrations.all` states it.
fn expected_file(migration: migrations.Migration) -> String {
  let section = fn(statements) {
    list.map(statements, fn(statement) { statement <> ";" })
    |> string.join("\n\n")
  }
  "--- migration:up\n\n"
  <> section(migration.up)
  <> "\n\n--- migration:down\n\n"
  <> section(migration.down)
  <> "\n\n--- migration:end\n"
}

pub fn the_shipped_sql_is_the_statements_migrate_runs_test() {
  list.each(migrations.all(), fn(migration) {
    let expected = expected_file(migration)
    let path = "priv/migrations/" <> migration.file
    case kit.read_file(path) {
      Ok(found) if found == expected -> Nil
      _ -> {
        kit.write_file("build/expected/" <> migration.file, expected)
        panic as {
          path
          <> " differs from migrations.all(); the expected text is in build/expected/"
          <> migration.file
        }
      }
    }
  })
}

pub fn the_schema_accepts_exactly_the_core_entry_kinds_test() {
  assert migrations.kinds_v1 == entry.kinds
  let assert [first, ..] = migrations.all()
  let quoted =
    list.map(entry.kinds, fn(kind) { "'" <> kind <> "'" })
    |> string.join(", ")
  assert list.any(first.up, string.contains(_, "kind IN (" <> quoted <> ")"))
}

pub fn the_schema_accepts_exactly_the_core_statuses_test() {
  assert migrations.statuses_v1 == list.map(store.statuses, store.status_name)
  let assert [first, ..] = migrations.all()
  let quoted =
    list.map(migrations.statuses_v1, fn(status) { "'" <> status <> "'" })
    |> string.join(", ")
  assert list.any(first.up, string.contains(_, "status IN (" <> quoted <> ")"))
}

/// `waiting` and its index name the statuses `store.is_waiting` accepts.
pub fn waiting_reads_the_statuses_the_core_calls_waiting_test() {
  let waiting =
    list.filter(store.statuses, store.is_waiting)
    |> list.map(store.status_name)
  assert waiting == ["pending", "recommended", "awaiting", "held"]
}

pub fn migrate_again_and_at_once_applies_each_step_once_test() {
  let #(name, store) = kit.store()
  use env <- kit.run(name, store, kit.options(), [], [])
  let results =
    kit.race(8, 30_000, fn(_) { decisions_postgres.migrate(env.pool) })
  assert list.unique(results) == [Ok(Nil)]
  assert decisions_postgres.migrate(env.pool) == Ok(Nil)
  let versions =
    kit.scalar(
      env.db,
      "SELECT array_agg(version ORDER BY version) FROM decisions_schema_migrations",
      [],
      decode.list(decode.int),
    )
  assert versions == [1, 2]
}
