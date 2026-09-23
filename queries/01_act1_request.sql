-- =============================================================================
-- ACT-1  Request a ride  —  "Is Renata free to ride right now, and on what?"
--
-- Answers the settle-first gate (TRP-01: no open trip -> may request) and the
-- payment precondition (RDR-01: she needs a default instrument on file).
-- Served by: uq_payment_default_per_rider (default instrument lookup)
--            uq_trips_one_active_per_rider (open-trip existence)
-- Run: psql -d nimbus_step5 -f queries/01_act1_request.sql
-- =============================================================================
SELECT pm.id   AS default_payment_method_id,
       pm.kind AS default_kind,
       pm.last4,
       (SELECT count(*)
          FROM trips t
         WHERE t.rider_id = :'rider_id'
           AND t.status NOT IN ('CANCELLED', 'PAID')) AS open_trips
  FROM payment_methods pm
 WHERE pm.rider_id = :'rider_id'
   AND pm.is_default
   AND pm.deleted_at IS NULL;