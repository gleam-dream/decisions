//// Queries for screens and reports, read from the heads alone: no entry is
//// ever decoded. Each query is served by one index, named in its doc
//// comment.
////
//// ```gleam
//// import decisions_postgres/queue
//// import gleam/option.{None, Some}
////
//// // The first page of what Bia may decide, soonest due first.
//// let assert Ok(first) = queue.page(db, for: bia, limit: 50, after: None)
//// // The next page starts after the last card of this one.
//// let assert Ok(next) = case list.last(first) {
////   Ok(last) -> queue.page(db, for: bia, limit: 50, after: Some(last))
////   Error(Nil) -> Ok([])
//// }
//// ```
////
//// `db` is the application's pool (`decisions_postgres.pool`). What
//// these queries return is what was committed when they ran. A card
//// on a page may be decided by someone else a moment later; the verdict
//// then gets `decisions.AlreadyDecided`, which the page cannot prevent.

import decisions/store.{type Status}
import decisions/vocabulary.{type Subject, type Validator}
import decisions_postgres.{type Pool}
import decisions_postgres/internal/sql
import gleam/dynamic/decode
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import pog

/// One card in a validator's queue.
pub type Queued {
  Queued(
    occurrence: String,
    point: String,
    /// When its validity ends; `None` when it has none.
    due: Option(Timestamp),
    /// When the recommendation arrived.
    arrived: Timestamp,
  )
}

/// A page of what `validator` may decide, across decision points: the
/// occurrences waiting in a decision set they hold, leaving out those the
/// head names in `may_not_decide` (the person who asked or recommended
/// their own act under `SomeoneElseHolding`, and under `Several` whoever
/// already approved the output that stands). The soonest due first, those
/// without a due time last, then by arrival, then by id. `after` is the
/// last card of the previous page, or `None` for the first.
///
/// Index: `decisions_awaiting_queue (set_name, due_order, arrived,
/// occurrence_id)`, scanned once per set the validator holds and stopped
/// after `limit` rows each; `due_order` is the due time, or `infinity`.
pub fn page(
  db: Pool,
  for validator: Validator,
  limit limit: Int,
  after after: Option(Queued),
) -> Result(List(Queued), pog.QueryError) {
  page_of(db, None, validator, limit, after)
}

/// `page`, for one decision point only: a desk for one point reads its
/// own queue without filtering in the application. The order, the
/// exclusions and the paging are `page`'s.
///
/// Index: `decisions_awaiting_point_queue (set_name, point, due_order,
/// arrived, occurrence_id)`.
pub fn page_at(
  db: Pool,
  point point: String,
  for validator: Validator,
  limit limit: Int,
  after after: Option(Queued),
) -> Result(List(Queued), pog.QueryError) {
  page_of(db, Some(point), validator, limit, after)
}

fn page_of(
  db: Pool,
  point: Option(String),
  validator: Validator,
  limit: Int,
  after: Option(Queued),
) -> Result(List(Queued), pog.QueryError) {
  let #(start, due, arrived, id) = case after {
    None -> #(True, None, timestamp.unix_epoch, "")
    Some(last) -> #(False, last.due, last.arrived, last.occurrence)
  }
  let only_point = case point {
    Some(_) -> "AND a.point = $8"
    None -> ""
  }
  let query =
    pog.query("SELECT d.occurrence_id, d.point,
              CASE WHEN d.due_order = 'infinity' THEN NULL
                   ELSE decisions_ms(d.due_order) END,
              decisions_ms(d.arrived)
       FROM (
         SELECT DISTINCT ON (q.occurrence_id) q.*
         FROM unnest($1::text[]) AS s (set_name)
         CROSS JOIN LATERAL (
           SELECT a.occurrence_id, a.point, a.due_order, a.arrived
           FROM decisions_awaiting a
           WHERE a.set_name = s.set_name " <> only_point <> "
             AND NOT ($2 = ANY (a.may_not_decide))
             AND (a.due_order, a.arrived, a.occurrence_id) > (
               CASE WHEN $4 THEN '-infinity'::timestamptz
                    ELSE coalesce(decisions_at($5::bigint), 'infinity') END,
               CASE WHEN $4 THEN '-infinity'::timestamptz
                    ELSE decisions_at($6::bigint) END,
               CASE WHEN $4 THEN '' ELSE $7::text END COLLATE \"C\")
           ORDER BY a.due_order, a.arrived, a.occurrence_id
           LIMIT $3
         ) AS q
         ORDER BY q.occurrence_id
       ) AS d
       ORDER BY d.due_order, d.arrived, d.occurrence_id
       LIMIT $3")
    |> pog.parameter(pog.array(pog.text, validator.holds))
    |> pog.parameter(pog.text(validator.subject))
    |> pog.parameter(pog.int(limit))
    |> pog.parameter(pog.bool(start))
    |> pog.parameter(pog.nullable(sql.at, due))
    |> pog.parameter(sql.at(arrived))
    |> pog.parameter(pog.text(id))
  let query = case point {
    Some(point) -> pog.parameter(query, pog.text(point))
    None -> query
  }
  query
  |> pog.returning({
    use occurrence <- decode.field(0, decode.string)
    use point <- decode.field(1, decode.string)
    use due <- decode.field(2, decode.optional(sql.time()))
    use arrived <- decode.field(3, sql.time())
    decode.success(Queued(occurrence:, point:, due:, arrived:))
  })
  |> rows(db)
}

/// How many occurrences of a point have one status.
pub type Count {
  Count(status: Status, count: Int)
}

/// How many occurrences of `point` have each status, by status name.
///
/// Index: `decisions_occurrences_status (point, status)`, read without the
/// table (an index-only scan once the table is vacuumed). It counts every
/// occurrence of the point, so its cost grows with the point's history.
pub fn counts(db: Pool, point: String) -> Result(List(Count), pog.QueryError) {
  pog.query(
    "SELECT status, count(*) FROM decisions_occurrences
     WHERE point = $1 GROUP BY status ORDER BY status",
  )
  |> pog.parameter(pog.text(point))
  |> pog.returning({
    use status <- decode.field(0, decisions_postgres.status_decoder())
    use count <- decode.field(1, decode.int)
    decode.success(Count(status:, count:))
  })
  |> rows(db)
}

/// An occurrence as its head describes it.
pub type Summary {
  Summary(
    occurrence: String,
    point: String,
    status: Status,
    arrived: Timestamp,
    due: Option(Timestamp),
  )
}

/// The occurrences about `subject`, of every point, the most recent first,
/// at most `limit`.
///
/// Index: `decisions_occurrences_subject (subject_kind, subject_id,
/// arrived DESC, id DESC)`.
pub fn about(
  db: Pool,
  subject: Subject,
  limit limit: Int,
) -> Result(List(Summary), pog.QueryError) {
  pog.query(
    "SELECT id, point, status, decisions_ms(arrived), decisions_ms(due)
     FROM decisions_occurrences
     WHERE subject_kind = $1 AND subject_id = $2
     ORDER BY arrived DESC, id DESC LIMIT $3",
  )
  |> pog.parameter(pog.text(subject.kind))
  |> pog.parameter(pog.text(subject.id))
  |> pog.parameter(pog.int(limit))
  |> pog.returning({
    use occurrence <- decode.field(0, decode.string)
    use point <- decode.field(1, decode.string)
    use status <- decode.field(2, decisions_postgres.status_decoder())
    use arrived <- decode.field(3, sql.time())
    use due <- decode.field(4, decode.optional(sql.time()))
    decode.success(Summary(occurrence:, point:, status:, arrived:, due:))
  })
  |> rows(db)
}

/// Sampled, released occurrences of `point` that nobody has reviewed yet,
/// the oldest first, at most `limit`.
///
/// Index: `decisions_occurrences_review (point, arrived, id) WHERE
/// review_pending`.
pub fn review_queue(
  db: Pool,
  point: String,
  limit limit: Int,
) -> Result(List(String), pog.QueryError) {
  pog.query(
    "SELECT id FROM decisions_occurrences
     WHERE point = $1 AND review_pending
     ORDER BY arrived, id LIMIT $2",
  )
  |> pog.parameter(pog.text(point))
  |> pog.parameter(pog.int(limit))
  |> pog.returning(decode.at([0], decode.string))
  |> rows(db)
}

/// Sampled, released occurrences of every point that nobody has reviewed
/// yet, the oldest first, at most `limit`.
///
/// Index: `decisions_occurrences_review_all (arrived, id) WHERE
/// review_pending`.
pub fn review_queue_all(
  db: Pool,
  limit limit: Int,
) -> Result(List(Summary), pog.QueryError) {
  pog.query(
    "SELECT id, point, status, decisions_ms(arrived), decisions_ms(due)
     FROM decisions_occurrences WHERE review_pending
     ORDER BY arrived, id LIMIT $1",
  )
  |> pog.parameter(pog.int(limit))
  |> pog.returning(summary_decoder())
  |> rows(db)
}

/// Every occurrence of `point`, in id order, `limit` at a time, for
/// learning and export: read each with `decisions.read` (or a desk's
/// replay) and judge or export the record. `after` is the last id of the
/// previous page, or `None` for the first. It reads heads only; no entry
/// is decoded to find them, and a page reads from its cursor.
///
/// Each page reads what was committed when it ran: an occurrence made
/// during an export whose id sorts before the cursor is not returned. For
/// an export that runs again and again, read what settled since the last
/// run with `settled_since`, which never skips one.
///
/// Index: `decisions_occurrences_point (point, id)`.
pub fn occurrences_of(
  db: Pool,
  point point: String,
  limit limit: Int,
  after after: Option(String),
) -> Result(List(Summary), pog.QueryError) {
  pog.query(
    "SELECT id, point, status, decisions_ms(arrived), decisions_ms(due)
     FROM decisions_occurrences
     WHERE point = $1 AND (point, id) > ($1, $2::text COLLATE \"C\")
     ORDER BY point, id LIMIT $3",
  )
  |> pog.parameter(pog.text(point))
  |> pog.parameter(pog.text(option.unwrap(after, "")))
  |> pog.parameter(pog.int(limit))
  |> pog.returning(summary_decoder())
  |> rows(db)
}

/// The records of `point` that have stayed pending: a trigger was
/// expected (`decisions.expect` or `decisions.expect_until`) or only failed
/// attempts are recorded, and no recommendation has arrived. The oldest
/// first, so "which triggers are still expected, and since when" is this
/// one query: each `Summary`'s `arrived` is when the record began, and its
/// `due` the record's own deadline, when it has one. `after` is the last record of the
/// previous page, or `None` for the first. A pending record is never in a
/// validator's queue (`page`, `page_at`): it waits for no verdict.
/// `counts` reports them under `store.Pending`.
///
/// Index: `decisions_occurrences_pending (point, arrived, id) WHERE status
/// = 'pending'`; a page reads from its cursor.
pub fn pending(
  db: Pool,
  point point: String,
  limit limit: Int,
  after after: Option(Summary),
) -> Result(List(Summary), pog.QueryError) {
  let #(start, arrived, id) = case after {
    None -> #(True, timestamp.unix_epoch, "")
    Some(last) -> #(False, last.arrived, last.occurrence)
  }
  pog.query(
    "SELECT id, point, status, decisions_ms(arrived), decisions_ms(due)
     FROM decisions_occurrences
     WHERE point = $1 AND status = 'pending'
       AND (arrived, id) > (
         CASE WHEN $2 THEN '-infinity'::timestamptz ELSE decisions_at($3) END,
         CASE WHEN $2 THEN '' ELSE $4::text END COLLATE \"C\")
     ORDER BY arrived, id LIMIT $5",
  )
  |> pog.parameter(pog.text(point))
  |> pog.parameter(pog.bool(start))
  |> pog.parameter(sql.at(arrived))
  |> pog.parameter(pog.text(id))
  |> pog.parameter(pog.int(limit))
  |> pog.returning(summary_decoder())
  |> rows(db)
}

/// An occurrence that settled, and when its settlement was recorded.
pub type Settlement {
  Settlement(
    occurrence: String,
    point: String,
    /// The status it settled in, as its head holds it now.
    status: Status,
    /// When the settlement notice was admitted, by the database's clock,
    /// to the millisecond. A store's test clock offset does not apply.
    at: Timestamp,
    /// Where the settlement stands in commit order: pass the last
    /// settlement of a page back as `after` to read the next.
    position: Position,
  )
}

/// A settlement's place in the order `settled_since` pages by: the id of
/// the transaction that admitted it, then the notice's row.
pub opaque type Position {
  Position(transaction: Int, row: Int)
}

/// The occurrences of `point` that settled at or after `since`, `limit` at
/// a time: what an export or a learning job reads since its last run.
/// `after` is the last settlement of the previous page, or `None` for the
/// first.
///
/// Pages follow the order of the transactions that admitted the
/// settlements, and a page holds only settlements whose transaction ended
/// before every transaction still running began
/// (`pg_snapshot_xmin(pg_current_snapshot())`). So a reader that keeps its
/// cursor reads each settlement exactly once, including one whose
/// transaction began earlier and committed later than another's: it
/// appears on a later page once it committed. A transaction left open
/// holds back every later settlement until it ends. `since` filters by the
/// time the notice was admitted; it does not move the cursor.
///
/// Index: `decisions_settled_point (point, admitted_xid, id)`; a page reads
/// from its cursor.
pub fn settled_since(
  db: Pool,
  point point: String,
  since since: Timestamp,
  limit limit: Int,
  after after: Option(Settlement),
) -> Result(List(Settlement), pog.QueryError) {
  let #(transaction, row) = case after {
    Some(Settlement(position: Position(transaction:, row:), ..)) -> #(
      transaction,
      row,
    )
    None -> #(0, 0)
  }
  pog.query(
    "SELECT s.occurrence_id, s.point, o.status, decisions_ms(s.admitted_at),
            s.admitted_xid::text::bigint, s.id
     FROM decisions_settled s
     JOIN decisions_occurrences o ON o.id = s.occurrence_id
     WHERE s.point = $1
       AND (s.admitted_xid, s.id) > ($2::text::xid8, $3)
       AND s.admitted_xid < pg_snapshot_xmin(pg_current_snapshot())
       AND s.admitted_at >= decisions_at($4)
     ORDER BY s.admitted_xid, s.id LIMIT $5",
  )
  |> pog.parameter(pog.text(point))
  |> pog.parameter(pog.text(int.to_string(transaction)))
  |> pog.parameter(pog.int(row))
  |> pog.parameter(sql.at(since))
  |> pog.parameter(pog.int(limit))
  |> pog.returning({
    use occurrence <- decode.field(0, decode.string)
    use point <- decode.field(1, decode.string)
    use status <- decode.field(2, decisions_postgres.status_decoder())
    use at <- decode.field(3, sql.time())
    use transaction <- decode.field(4, decode.int)
    use row <- decode.field(5, decode.int)
    decode.success(Settlement(
      occurrence:,
      point:,
      status:,
      at:,
      position: Position(transaction:, row:),
    ))
  })
  |> rows(db)
}

fn summary_decoder() -> decode.Decoder(Summary) {
  use occurrence <- decode.field(0, decode.string)
  use point <- decode.field(1, decode.string)
  use status <- decode.field(2, decisions_postgres.status_decoder())
  use arrived <- decode.field(3, sql.time())
  use due <- decode.field(4, decode.optional(sql.time()))
  decode.success(Summary(occurrence:, point:, status:, arrived:, due:))
}

/// The last sequence number of each of these occurrences, for a client
/// that holds cards and polls instead of, or beside, listening
/// (`decisions_postgres/live`). Absent ids are left out.
///
/// Index: the primary key of `decisions_occurrences`.
pub fn positions(
  db: Pool,
  ids: List(String),
) -> Result(List(#(String, Int)), pog.QueryError) {
  pog.query(
    "SELECT id, last_seq FROM decisions_occurrences
     WHERE id = ANY ($1::text[]) ORDER BY id",
  )
  |> pog.parameter(pog.array(pog.text, ids))
  |> pog.returning({
    use id <- decode.field(0, decode.string)
    use seq <- decode.field(1, decode.int)
    decode.success(#(id, seq))
  })
  |> rows(db)
}

/// An occurrence set aside because its record does not decode.
pub type Aside {
  Aside(occurrence: String, point: String, reason: String, at: Timestamp)
}

/// The occurrences set aside (`decisions_postgres.set_aside`), the most
/// recent first, at most `limit`.
///
/// Index: `decisions_occurrences_set_aside (set_aside_at, id) WHERE
/// set_aside_at IS NOT NULL`.
pub fn set_aside(
  db: Pool,
  limit limit: Int,
) -> Result(List(Aside), pog.QueryError) {
  pog.query(
    "SELECT id, point, set_aside_reason, decisions_ms(set_aside_at)
     FROM decisions_occurrences
     WHERE set_aside_at IS NOT NULL
     ORDER BY set_aside_at DESC, id DESC LIMIT $1",
  )
  |> pog.parameter(pog.int(limit))
  |> pog.returning({
    use occurrence <- decode.field(0, decode.string)
    use point <- decode.field(1, decode.string)
    use reason <- decode.field(2, decode.string)
    use at <- decode.field(3, sql.time())
    decode.success(Aside(occurrence:, point:, reason:, at:))
  })
  |> rows(db)
}

fn rows(query: pog.Query(a), db: Pool) -> Result(List(a), pog.QueryError) {
  pog.execute(query, sql.pool_connection(db))
  |> result.map(fn(returned) { returned.rows })
}
