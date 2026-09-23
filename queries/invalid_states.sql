-- =============================================================================
-- Three invalid states, and the database rejecting each one.
--
-- Three DIFFERENT enforcement layers, in an order that keeps every rejection
-- unambiguous (so the error names exactly one mechanism):
--
--   (a) IND-1 partial unique   a second active trip for RENATA while the first
--              index           is still open  -> uq_trips_one_active_per_rider.
--   (b) IND-2 trigger          UPDATE REQUESTED -> PAID is an illegal edge;
--                              trg_trip_transition_guard raises TRP-02.
--   (c) IND-3 CHECK constraint a $5 cancellation fee on a REQUESTED trip for
--                              OMAR (who has never ridden) ->
--                              trips_cancel_fee_only_when_cancelled.
--
-- Each statement is its own implicit transaction, so a failure never poisons
-- the next one. psql keeps going after errors (ON_ERROR_STOP off) so all
-- three rejections print in one run.
-- =============================================================================

\set ON_ERROR_STOP off

-- ===================  (a) IND-1 — partial unique index  =====================
-- first writer wins: an active trip for RENATA is fine...
INSERT INTO trips (
    id, rider_id, status,
    pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
    rate_card_id, currency, base_fare_cents, per_km_cents, per_min_cents, surge_bps,
    estimated_km, estimated_minutes, quote_total_cents)
VALUES (
    'f0000000-0000-4000-8000-000000000003',
    '10000000-0000-4000-8000-000000000001', 'REQUESTED',
    37.7750, -122.4150, 37.7870, -122.4010,
    'b1000000-0000-4000-8000-000000000001', 'USD', 250, 80, 30, 150,
    5, 10, 1500);

-- ...but the SECOND active trip must fail (TRP-01), at the index, not in code.
INSERT INTO trips (
    id, rider_id, status,
    pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
    rate_card_id, currency, base_fare_cents, per_km_cents, per_min_cents, surge_bps,
    estimated_km, estimated_minutes, quote_total_cents)
VALUES (
    'f0000000-0000-4000-8000-000000000004',
    '10000000-0000-4000-8000-000000000001', 'REQUESTED',
    37.7750, -122.4150, 37.7870, -122.4010,
    'b1000000-0000-4000-8000-000000000001', 'USD', 250, 80, 30, 150,
    5, 10, 1500);

-- =========================  (b) IND-2 — trigger  ============================
-- the trip that DID get through is still REQUESTED; jumping it straight to
-- ON_TRIP skips matching entirely — trg_trip_transition_guard raises TRP-02
-- (REQUESTED -> ON_TRIP has no row in trip_transitions). The guard runs
-- BEFORE UPDATE, so the illegal move never reaches the DB).
UPDATE trips
   SET status = 'ON_TRIP', accepted_at = now()
 WHERE id = 'f0000000-0000-4000-8000-000000000003';

-- =======================  (c) IND-3 — CHECK constraint  =====================
-- OMAR's trip is only REQUESTED — nobody has arrived yet — so it cannot
-- carry a $5.00 cancellation fee (FEE-05 / FEE-06): such a fee may exist only
-- on a CANCELLED row.
INSERT INTO trips (
    id, rider_id, status, cancellation_fee_cents,
    pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
    rate_card_id, currency, base_fare_cents, per_km_cents, per_min_cents, surge_bps,
    estimated_km, estimated_minutes, quote_total_cents)
VALUES (
    'f0000000-0000-4000-8000-000000000005',
    '40000000-0000-4000-8000-000000000001', 'REQUESTED', 500,
    37.7750, -122.4150, 37.7870, -122.4010,
    'b1000000-0000-4000-8000-000000000001', 'USD', 250, 80, 30, 150,
    5, 10, 1500);