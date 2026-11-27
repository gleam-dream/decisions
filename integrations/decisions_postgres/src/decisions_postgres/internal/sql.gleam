//// What every module of the package shares below pog: the pool, how a
//// query error becomes a `store.StoreError`, and the clock.

import decisions/store.{type StoreError, Conflict, Contended, Unavailable}
import decisions/wire
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import pog

/// A connection pool of the application's. It is made from the pool's
/// name, so it is never the connection of an open transaction: every
/// transaction of the package starts on one, and none starts inside
/// another.
pub opaque type Pool {
  Pool(connection: pog.Connection)
}

/// The pool registered under `name` (`pog.Config.pool_name`).
pub fn pool(name: process.Name(pog.Message)) -> Pool {
  Pool(pog.named_connection(name))
}

/// The pool's connection, for a statement that commits by itself or for
/// `pog.transaction`.
pub fn pool_connection(pool: Pool) -> pog.Connection {
  pool.connection
}

/// A positive integer unique on this node.
@external(erlang, "decisions_postgres_ffi", "unique")
pub fn unique() -> Int

@external(erlang, "decisions_postgres_ffi", "system_ms")
fn system_ms() -> Int

/// A new occurrence id: a UUID version 7, so ids made later sort later.
@external(erlang, "decisions_postgres_ffi", "new_id")
pub fn new_id() -> String

/// The error as one line, with the SQLSTATE when there is one.
pub fn describe(error: pog.QueryError) -> String {
  case error {
    pog.ConstraintViolated(message:, constraint:, ..) ->
      "constraint " <> constraint <> ": " <> message
    pog.PostgresqlError(code:, name:, message:) ->
      "postgres " <> code <> " " <> name <> ": " <> message
    pog.UnexpectedArgumentCount(expected:, got:) ->
      "expected "
      <> int.to_string(expected)
      <> " arguments, got "
      <> int.to_string(got)
    pog.UnexpectedArgumentType(expected:, got:) ->
      "expected an argument of type " <> expected <> ", got " <> got
    pog.UnexpectedResultType(errors) ->
      "unexpected result: " <> string.inspect(errors)
    pog.QueryTimeout -> "the query timed out"
    pog.ConnectionUnavailable -> "no connection was available"
  }
}

/// A query error as the port reports it, as `decisions/store.StoreError`
/// defines the three kinds:
///
/// - an integrity violation (SQLSTATE class 23: a key, the gap constraint,
///   the one-release index, the kind check, the append-only trigger) is
///   the database refusing a write that breaks the record's rules, and a
///   transaction at another isolation level than READ COMMITTED (25000,
///   raised by `decisions_load`) breaks the port's contract: `Conflict`;
/// - a deadlock (`40P01`), a serialization failure (`40001`) or a lock
///   wait that timed out (`55P03`) wrote nothing: `Contended`;
/// - everything else, a lost connection or a query timeout among them, is
///   `Unavailable`: the outcome may be unknown.
pub fn store_error(error: pog.QueryError) -> StoreError {
  case error {
    pog.ConstraintViolated(..) -> Conflict(describe(error))
    pog.PostgresqlError(code: "23" <> _, ..) -> Conflict(describe(error))
    // `decisions_load` refuses a transaction that is not READ COMMITTED.
    pog.PostgresqlError(code: "25000", ..) -> Conflict(describe(error))
    pog.PostgresqlError(code: "40P01", ..)
    | pog.PostgresqlError(code: "40001", ..)
    | pog.PostgresqlError(code: "55P03", ..) -> Contended(describe(error))
    _ -> Unavailable(describe(error))
  }
}

/// Run `body`; when it raises, run `cleanup` and raise again.
@external(erlang, "decisions_postgres_ffi", "on_raise")
pub fn on_raise(body: fn() -> a, cleanup: fn() -> b) -> a

/// Run a query, reporting a failure as a `StoreError`.
pub fn run(
  query: pog.Query(a),
  on connection: pog.Connection,
) -> Result(List(a), StoreError) {
  pog.execute(query, connection)
  |> result.map(fn(returned) { returned.rows })
  |> result.map_error(store_error)
}

/// The database's clock, to the millisecond, read now (not at the start of
/// the transaction). The desk reduces it to whole milliseconds as well; it
/// is read here as an integer of milliseconds because that is how every
/// time crosses the wire in this package (see `time`). When the query fails the
/// node's clock stands in: the transaction has failed by then, and its
/// next write fails with it.
pub fn now(connection: pog.Connection) -> Timestamp {
  let read =
    pog.query(
      "SELECT floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint",
    )
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(connection)
  case read {
    Ok(pog.Returned(rows: [ms], ..)) -> wire.from_milliseconds(ms)
    _ -> wire.from_milliseconds(system_ms())
  }
}

/// A time read as whole Unix milliseconds (`decisions_ms(column)`). The
/// package never hands pgo a `timestamptz` value: how pgo encodes and
/// decodes one depends on a node-wide setting that `pog.start` makes and a
/// pool started otherwise does not.
pub fn time() -> decode.Decoder(Timestamp) {
  decode.map(decode.int, wire.from_milliseconds)
}

/// A time as a parameter, in whole Unix milliseconds; the statement turns
/// it into a `timestamptz` with `decisions_at($n)`.
pub fn at(time: Timestamp) -> pog.Value {
  pog.int(wire.milliseconds(time))
}

/// Run `body`; a raise becomes `Error` with its description.
@external(erlang, "decisions_postgres_ffi", "rescue")
pub fn rescue(body: fn() -> a) -> Result(a, String)
