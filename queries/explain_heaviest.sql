-- =============================================================================
-- Query plans for the TWO HEAVIEST action queries — do the indexes get used?
--
--   Heaviest #1: ACT-2 dispatch  (4-table join + distance sort) -> must use
--                idx_drivers_available.
--   Heaviest #2: ACT-4 settle    (posting trail for a trip + account join)
--                -> must use idx_ledger_entries_trip.
--
-- Caveat, made explicit: the seed dataset is deliberately TINY (6-10 rows).
-- On such a table PostgreSQL's cost model is right to prefer Seq Scan, so a
-- default EXPLAIN would show a seq scan and prove nothing. The standard way
-- to validate that an index CAN serve a query is to forbid seq scans for the
-- plan run (`SET LOCAL enable_seqscan = off`) and inspect which index the
-- planner then picks. That is what this file does; the assertion lives in
-- step5_run.sh (grep for the two index names, exit non-zero if absent).
-- =============================================================================

BEGIN;
SET LOCAL enable_seqscan = off;

EXPLAIN
SELECT d.id, u.full_name, v.plate, v.make || ' ' || v.model AS vehicle, dl.lat, dl.lng
  FROM drivers d
  JOIN users u ON u.id = d.id
  LEFT JOIN vehicles v ON v.driver_id = d.id AND v.is_active AND v.deleted_at IS NULL
  LEFT JOIN driver_locations dl ON dl.driver_id = d.id
 WHERE d.status = 'AVAILABLE'
 ORDER BY abs(dl.lat - :pickup_lat) + abs(dl.lng - :pickup_lng)
 LIMIT 3;

EXPLAIN
SELECT e.transaction_id, a.owner_type, e.side, e.entry_type, e.amount_cents, e.currency, e.created_at
  FROM ledger_entries e
  JOIN ledger_accounts a ON a.id = e.account_id
 WHERE e.trip_id = :'trip_id'
 ORDER BY e.created_at;

ROLLBACK;