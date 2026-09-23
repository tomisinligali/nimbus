-- =============================================================================
-- ACT-3  Drive the ride to completion  —  the state + its evidence timeline.
--
-- The per-trip read the driver app needs to advance the lifecycle and the
-- dispute evidence (TRP-06): the append-only event trail in order.
-- Served by: trips PK               (the trip row)
--            idx_trip_events_trip   (timeline)
-- Run: psql -d nimbus_step5 -f queries/03_act3_complete.sql
-- =============================================================================
-- (a) current trip snapshot
SELECT id,
       status,
       driver_id,
       actual_km,
       actual_minutes,
       fare_cents,
       completed_at,
       updated_at
  FROM trips
 WHERE id = :'trip_id';

-- (b) same trip's audit trail — the evidence that the lifecycle was legal
SELECT from_status,
       to_status,
       actor,
       payload,
       created_at
  FROM trip_events
 WHERE trip_id = :'trip_id'
 ORDER BY created_at;