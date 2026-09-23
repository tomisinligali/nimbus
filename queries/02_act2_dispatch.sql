-- =============================================================================
-- ACT-2  Accept / match a ride  —  "who is the nearest AVAILABLE driver?"
--
-- Dispatch candidate selection (DRV-02: only AVAILABLE drivers):
-- rank the online drivers by straight-line distance to the pickup.
-- Served by: idx_drivers_available  (partial index on drivers(status)
--                                     WHERE status = 'AVAILABLE')
-- Run: psql -d nimbus_step5 -f queries/02_act2_dispatch.sql
-- =============================================================================
SELECT d.id,
       u.full_name,
       v.plate,
       v.make || ' ' || v.model AS vehicle,
       dl.lat,
       dl.lng
  FROM drivers d
  JOIN users u            ON u.id = d.id
  LEFT JOIN vehicles v
         ON v.driver_id = d.id AND v.is_active AND v.deleted_at IS NULL
  LEFT JOIN driver_locations dl ON dl.driver_id = d.id
 WHERE d.status = 'AVAILABLE'
 ORDER BY abs(dl.lat - :pickup_lat) + abs(dl.lng - :pickup_lng)
 LIMIT 3;