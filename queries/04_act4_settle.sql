-- =============================================================================
-- ACT-4  Pay & settle  —  "show me the whole money trail for this trip."
--
-- Full double-entry posting set for a trip, so any auditor can prove the
-- settlement balanced (PAY-03: every transaction group nets to zero) and that
-- exactly one captured payment exists (PAY-01/04).
-- Served by: idx_ledger_entries_trip  (every posting for one trip — added by
--                                      the Step-5 EXPLAIN pass)
--            ledger_accounts PK
-- Run: psql -d nimbus_step5 -f queries/04_act4_settle.sql
-- =============================================================================
SELECT e.transaction_id,
       a.owner_type,
       e.side,
       e.entry_type,
       e.amount_cents,
       e.currency,
       e.created_at
  FROM ledger_entries e
  JOIN ledger_accounts a ON a.id = e.account_id
 WHERE e.trip_id = :'trip_id'
 ORDER BY e.created_at;

-- confirm the two guarantees the settle flow depends on:
SELECT count(*) AS payments,
       max(CASE WHEN p.status = 'CAPTURED' THEN 1 ELSE 0 END) AS captured
  FROM payments p
 WHERE p.trip_id = :'trip_id';