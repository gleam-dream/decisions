//// The schema's forward-only migrations, numbered from 1. `migrate` runs
//// these statements; `priv/migrations/*.sql` holds the same statements for
//// an application that applies its migrations with its own tool
//// (`--- migration:up` ... `--- migration:down` ... `--- migration:end`,
//// cigogne's format). `migrations_test` checks that the two agree
//// statement for statement.
////
//// The statements name no schema: they create the tables in the first
//// schema of the `search_path` the migrating transaction runs with. The
//// first statement of every step takes the migration lock; the last
//// records the step in `decisions_schema_migrations`.
////
//// Adding a step: append a `Migration` with the next version, add its SQL
//// file, and never change a released step.

pub type Migration {
  Migration(version: Int, file: String, up: List(String), down: List(String))
}

/// The advisory lock every migration step takes first, so two nodes that
/// migrate at once apply each step once.
pub const lock =
  "SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('decisions-postgres-migrate', 0))) AS l"

/// Every head status the version 1 schema accepts. `migrations_test`
/// checks it against `decisions/store.statuses`.
pub const statuses_v1 = [
  "pending", "recommended", "awaiting", "accepted", "held", "released",
  "rejected", "expired", "withdrawn", "refused",
]

/// Every entry kind the version 1 schema accepts. `migrations_test` checks
/// it against `decisions/entry.kinds`.
pub const kinds_v1 = [
  "attempt_failed", "expected", "recommended", "informed", "policy_applied",
  "opened", "expanded", "noted", "decided", "verdict_refused", "reviewed",
  "held", "withdrawn", "released", "effected", "refused", "expired", "assessed",
]

pub fn all() -> List(Migration) {
  [
    Migration(
      version: 1,
      file: "20261115000000-decisions_postgres_v1.sql",
      up: [
        lock,
        "CREATE TABLE decisions_schema_migrations (version integer PRIMARY KEY, installed_at timestamptz NOT NULL DEFAULT clock_timestamp())",
        "CREATE FUNCTION decisions_at(ms bigint) RETURNS timestamptz LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE RETURN 'epoch'::timestamptz + ms * interval '1 millisecond'",
        "CREATE FUNCTION decisions_ms(at timestamptz) RETURNS bigint LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE RETURN floor(extract(epoch FROM at) * 1000)::bigint",
        "CREATE TABLE decisions_occurrences (id text COLLATE \"C\" PRIMARY KEY, point text NOT NULL, subject_kind text NOT NULL, subject_id text NOT NULL, status text NOT NULL, awaiting text[] NOT NULL, approved text[] NOT NULL, may_not_decide text[] NOT NULL, due timestamptz, arrived timestamptz NOT NULL, review_pending boolean NOT NULL, last_seq integer NOT NULL CHECK (last_seq >= 1), updated_at timestamptz NOT NULL DEFAULT clock_timestamp(), set_aside_at timestamptz, set_aside_reason text, CONSTRAINT decisions_occurrences_id_length CHECK (octet_length(id) <= 255), CONSTRAINT decisions_occurrences_point_length CHECK (octet_length(point) <= 255), CONSTRAINT decisions_occurrences_status CHECK (status IN ('pending', 'recommended', 'awaiting', 'accepted', 'held', 'released', 'rejected', 'expired', 'withdrawn', 'refused')), CONSTRAINT decisions_occurrences_set_aside CHECK ((set_aside_at IS NULL) = (set_aside_reason IS NULL)))",
        "CREATE INDEX decisions_occurrences_waiting ON decisions_occurrences (point, subject_kind, subject_id, id) WHERE status IN ('pending', 'recommended', 'awaiting', 'held')",
        "CREATE INDEX decisions_occurrences_subject ON decisions_occurrences (subject_kind, subject_id, arrived DESC, id DESC)",
        "CREATE INDEX decisions_occurrences_status ON decisions_occurrences (point, status)",
        "CREATE INDEX decisions_occurrences_review ON decisions_occurrences (point, arrived, id) WHERE review_pending",
        "CREATE INDEX decisions_occurrences_review_all ON decisions_occurrences (arrived, id) WHERE review_pending",
        "CREATE INDEX decisions_occurrences_point ON decisions_occurrences (point, id)",
        "CREATE INDEX decisions_occurrences_pending ON decisions_occurrences (point, arrived, id) WHERE status = 'pending'",
        "CREATE INDEX decisions_occurrences_set_aside ON decisions_occurrences (set_aside_at, id) WHERE set_aside_at IS NOT NULL",
        "CREATE TABLE decisions_entries (occurrence_id text COLLATE \"C\" NOT NULL REFERENCES decisions_occurrences (id), seq integer NOT NULL CHECK (seq >= 1), previous integer GENERATED ALWAYS AS (NULLIF(seq - 1, 0)) STORED, at timestamptz NOT NULL, kind text NOT NULL, event text NOT NULL, CONSTRAINT decisions_entries_pkey PRIMARY KEY (occurrence_id, seq), CONSTRAINT decisions_entries_no_gap FOREIGN KEY (occurrence_id, previous) REFERENCES decisions_entries (occurrence_id, seq), CONSTRAINT decisions_entries_kind CHECK (kind IN ('attempt_failed', 'expected', 'recommended', 'informed', 'policy_applied', 'opened', 'expanded', 'noted', 'decided', 'verdict_refused', 'reviewed', 'held', 'withdrawn', 'released', 'effected', 'refused', 'expired', 'assessed')))",
        "CREATE UNIQUE INDEX decisions_entries_one_release ON decisions_entries (occurrence_id) WHERE kind = 'released'",
        "CREATE FUNCTION decisions_entries_append_only() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION USING ERRCODE = 'restrict_violation', MESSAGE = 'decisions_entries is append-only', CONSTRAINT = 'decisions_entries_append_only'; END $$",
        "CREATE TRIGGER decisions_entries_append_only BEFORE UPDATE OR DELETE OR TRUNCATE ON decisions_entries FOR EACH STATEMENT EXECUTE FUNCTION decisions_entries_append_only()",
        "CREATE TABLE decisions_awaiting (occurrence_id text COLLATE \"C\" NOT NULL REFERENCES decisions_occurrences (id), set_name text NOT NULL, point text NOT NULL, due_order timestamptz NOT NULL, arrived timestamptz NOT NULL, may_not_decide text[] NOT NULL, PRIMARY KEY (occurrence_id, set_name))",
        "CREATE INDEX decisions_awaiting_queue ON decisions_awaiting (set_name, due_order, arrived, occurrence_id)",
        "CREATE INDEX decisions_awaiting_point_queue ON decisions_awaiting (set_name, point, due_order, arrived, occurrence_id)",
        "CREATE TABLE decisions_wakes (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, point text NOT NULL, occurrence_id text NOT NULL, at timestamptz NOT NULL, job_id bigint, set_aside_at timestamptz, set_aside_reason text, CONSTRAINT decisions_wakes_set_aside CHECK ((set_aside_at IS NULL) = (set_aside_reason IS NULL)))",
        "CREATE UNIQUE INDEX decisions_wakes_pending ON decisions_wakes (point, occurrence_id, at) WHERE set_aside_at IS NULL",
        "CREATE TABLE decisions_settled (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, point text NOT NULL, occurrence_id text COLLATE \"C\" NOT NULL, admitted_at timestamptz NOT NULL DEFAULT date_trunc('milliseconds', clock_timestamp()), admitted_xid xid8 NOT NULL DEFAULT pg_current_xact_id(), job_id bigint, delivered_at timestamptz, set_aside_at timestamptz, set_aside_reason text, CONSTRAINT decisions_settled_once UNIQUE (point, occurrence_id), CONSTRAINT decisions_settled_set_aside CHECK ((set_aside_at IS NULL) = (set_aside_reason IS NULL)))",
        "CREATE INDEX decisions_settled_point ON decisions_settled (point, admitted_xid, id)",
        "CREATE FUNCTION decisions_load(p_id text, p_lock_timeout text) RETURNS TABLE (seq integer, at_ms bigint, kind text, event text) LANGUAGE plpgsql VOLATILE AS $$ BEGIN IF current_setting('transaction_isolation') <> 'read committed' THEN RAISE EXCEPTION USING ERRCODE = 'invalid_transaction_state', MESSAGE = 'decisions requires READ COMMITTED; this transaction is ' || current_setting('transaction_isolation'); END IF; IF p_lock_timeout IS NOT NULL THEN PERFORM set_config('lock_timeout', p_lock_timeout, true); END IF; PERFORM 1 FROM decisions_occurrences o WHERE o.id = p_id FOR UPDATE; IF NOT FOUND THEN PERFORM pg_advisory_xact_lock(hashtextextended('decisions-occurrence:' || p_id, 0)); PERFORM 1 FROM decisions_occurrences o WHERE o.id = p_id FOR UPDATE; IF NOT FOUND THEN RETURN; END IF; END IF; RETURN QUERY SELECT e.seq, decisions_ms(e.at), e.kind, e.event FROM decisions_entries e WHERE e.occurrence_id = p_id ORDER BY e.seq; END $$",
        "CREATE FUNCTION decisions_append(p_id text, p_point text, p_subject_kind text, p_subject_id text, p_status text, p_awaiting text[], p_approved text[], p_may_not_decide text[], p_due_ms bigint, p_arrived_ms bigint, p_review boolean, p_seqs integer[], p_ats_ms bigint[], p_kinds text[], p_events text[]) RETURNS integer LANGUAGE plpgsql VOLATILE AS $$ DECLARE v_last integer := p_seqs[array_upper(p_seqs, 1)]; v_found boolean; v_set_aside boolean := false; p_due timestamptz := decisions_at(p_due_ms); p_arrived timestamptz := decisions_at(p_arrived_ms); BEGIN IF coalesce(p_seqs[1] = 1, false) THEN INSERT INTO decisions_occurrences (id, point, subject_kind, subject_id, status, awaiting, approved, may_not_decide, due, arrived, review_pending, last_seq) VALUES (p_id, p_point, p_subject_kind, p_subject_id, p_status, p_awaiting, p_approved, p_may_not_decide, p_due, p_arrived, p_review, v_last); ELSE UPDATE decisions_occurrences SET point = p_point, subject_kind = p_subject_kind, subject_id = p_subject_id, status = p_status, awaiting = p_awaiting, approved = p_approved, may_not_decide = p_may_not_decide, due = p_due, arrived = p_arrived, review_pending = p_review, last_seq = coalesce(v_last, last_seq), updated_at = clock_timestamp() WHERE id = p_id RETURNING set_aside_at IS NOT NULL, last_seq INTO v_set_aside, v_last; v_found := FOUND; IF NOT v_found AND array_length(p_seqs, 1) IS NULL THEN RETURN NULL; END IF; END IF; INSERT INTO decisions_entries (occurrence_id, seq, at, kind, event) SELECT p_id, u.seq, decisions_at(u.at_ms), u.kind, u.event FROM unnest(p_seqs, p_ats_ms, p_kinds, p_events) AS u (seq, at_ms, kind, event); DELETE FROM decisions_awaiting a WHERE a.occurrence_id = p_id AND (v_set_aside OR NOT (a.set_name = ANY (p_awaiting))); IF NOT coalesce(v_set_aside, false) THEN INSERT INTO decisions_awaiting (occurrence_id, set_name, point, due_order, arrived, may_not_decide) SELECT DISTINCT p_id, s, p_point, coalesce(p_due, 'infinity'::timestamptz), p_arrived, p_may_not_decide FROM unnest(p_awaiting) AS s ON CONFLICT (occurrence_id, set_name) DO UPDATE SET due_order = EXCLUDED.due_order, arrived = EXCLUDED.arrived, may_not_decide = EXCLUDED.may_not_decide; END IF; PERFORM pg_notify('decisions_changed', json_build_object('id', p_id, 'point', p_point, 'status', p_status, 'seq', v_last)::text); RETURN v_last; END $$",
        "INSERT INTO decisions_schema_migrations (version) VALUES (1)",
      ],
      down: [
        lock,
        "DROP FUNCTION decisions_append(text, text, text, text, text, text[], text[], text[], bigint, bigint, boolean, integer[], bigint[], text[], text[])",
        "DROP FUNCTION decisions_load(text, text)",
        "DROP TABLE decisions_settled",
        "DROP TABLE decisions_wakes",
        "DROP TABLE decisions_awaiting",
        "DROP TABLE decisions_entries",
        "DROP FUNCTION decisions_entries_append_only()",
        "DROP TABLE decisions_occurrences",
        "DROP FUNCTION decisions_ms(timestamptz)",
        "DROP FUNCTION decisions_at(bigint)",
        "DROP TABLE decisions_schema_migrations",
      ],
    ),
  ]
}
