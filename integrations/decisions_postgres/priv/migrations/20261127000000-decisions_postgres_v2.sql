--- migration:up

SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('decisions-postgres-migrate', 0))) AS l;

ALTER TABLE decisions_occurrences ADD COLUMN bundle_key text COLLATE "C", ADD COLUMN bundle_size integer;

ALTER TABLE decisions_occurrences ADD CONSTRAINT decisions_occurrences_bundle CHECK ((bundle_key IS NULL) = (bundle_size IS NULL) AND (bundle_size IS NULL OR bundle_size >= 1) AND (bundle_key IS NULL OR octet_length(bundle_key) <= 255)) NOT VALID;

CREATE INDEX decisions_occurrences_bundle ON decisions_occurrences (bundle_key, id) WHERE bundle_key IS NOT NULL;

CREATE FUNCTION decisions_append(p_id text, p_point text, p_subject_kind text, p_subject_id text, p_status text, p_awaiting text[], p_approved text[], p_may_not_decide text[], p_due_ms bigint, p_arrived_ms bigint, p_review boolean, p_seqs integer[], p_ats_ms bigint[], p_kinds text[], p_events text[], p_bundle_key text, p_bundle_size integer) RETURNS integer LANGUAGE plpgsql VOLATILE AS $$ DECLARE v_last integer := p_seqs[array_upper(p_seqs, 1)]; v_found boolean; v_set_aside boolean := false; p_due timestamptz := decisions_at(p_due_ms); p_arrived timestamptz := decisions_at(p_arrived_ms); BEGIN IF coalesce(p_seqs[1] = 1, false) THEN INSERT INTO decisions_occurrences (id, point, subject_kind, subject_id, status, awaiting, approved, may_not_decide, due, arrived, review_pending, last_seq, bundle_key, bundle_size) VALUES (p_id, p_point, p_subject_kind, p_subject_id, p_status, p_awaiting, p_approved, p_may_not_decide, p_due, p_arrived, p_review, v_last, p_bundle_key, p_bundle_size); ELSE UPDATE decisions_occurrences SET point = p_point, subject_kind = p_subject_kind, subject_id = p_subject_id, status = p_status, awaiting = p_awaiting, approved = p_approved, may_not_decide = p_may_not_decide, due = p_due, arrived = p_arrived, review_pending = p_review, bundle_key = p_bundle_key, bundle_size = p_bundle_size, last_seq = coalesce(v_last, last_seq), updated_at = clock_timestamp() WHERE id = p_id RETURNING set_aside_at IS NOT NULL, last_seq INTO v_set_aside, v_last; v_found := FOUND; IF NOT v_found AND array_length(p_seqs, 1) IS NULL THEN RETURN NULL; END IF; END IF; INSERT INTO decisions_entries (occurrence_id, seq, at, kind, event) SELECT p_id, u.seq, decisions_at(u.at_ms), u.kind, u.event FROM unnest(p_seqs, p_ats_ms, p_kinds, p_events) AS u (seq, at_ms, kind, event); DELETE FROM decisions_awaiting a WHERE a.occurrence_id = p_id AND (v_set_aside OR NOT (a.set_name = ANY (p_awaiting))); IF NOT coalesce(v_set_aside, false) THEN INSERT INTO decisions_awaiting (occurrence_id, set_name, point, due_order, arrived, may_not_decide) SELECT DISTINCT p_id, s, p_point, coalesce(p_due, 'infinity'::timestamptz), p_arrived, p_may_not_decide FROM unnest(p_awaiting) AS s ON CONFLICT (occurrence_id, set_name) DO UPDATE SET due_order = EXCLUDED.due_order, arrived = EXCLUDED.arrived, may_not_decide = EXCLUDED.may_not_decide; END IF; PERFORM pg_notify('decisions_changed', json_build_object('id', p_id, 'point', p_point, 'status', p_status, 'seq', v_last)::text); RETURN v_last; END $$;

INSERT INTO decisions_schema_migrations (version) VALUES (2);

--- migration:down

SELECT true FROM (SELECT pg_advisory_xact_lock(hashtextextended('decisions-postgres-migrate', 0))) AS l;

DROP FUNCTION decisions_append(text, text, text, text, text, text[], text[], text[], bigint, bigint, boolean, integer[], bigint[], text[], text[], text, integer);

DROP INDEX decisions_occurrences_bundle;

ALTER TABLE decisions_occurrences DROP CONSTRAINT decisions_occurrences_bundle;

ALTER TABLE decisions_occurrences DROP COLUMN bundle_size, DROP COLUMN bundle_key;

DELETE FROM decisions_schema_migrations WHERE version = 2;

--- migration:end
