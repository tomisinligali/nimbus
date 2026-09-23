-- =============================================================================
-- Nimbus — MIGRATION 0002: seed a small, realistic dataset.
-- Requirement: "Seed a small dataset."  Two drivers, one rider, a rate card, a
-- payment instrument, ledger accounts, and ONE fully-settled historical trip
-- (request -> matched -> completed -> paid -> settled) so every action query
-- and both heavy query-plans have real data to chew on.
--
-- All ids are fixed, readable UUIDs (the same IDN-01 UUID policy as the rest of
-- the schema). Idempotent: re-running is a no-op.
-- =============================================================================

BEGIN;

INSERT INTO users (id, full_name, phone) VALUES
    ('10000000-0000-4000-8000-000000000001', 'Renata Rider', '+14155550101'),
    ('20000000-0000-4000-8000-000000000001', 'Dara Driver',  '+14155550102'),
    ('30000000-0000-4000-8000-000000000001', 'Marco Driver', '+14155550103'),
    ('40000000-0000-4000-8000-000000000001', 'Omar Rider',   '+14155550104')
ON CONFLICT (id) DO NOTHING;

INSERT INTO riders (id, rating, rides_count) VALUES
    ('10000000-0000-4000-8000-000000000001', 4.9, 12),
    ('40000000-0000-4000-8000-000000000001', 4.7, 3)
ON CONFLICT (id) DO NOTHING;

INSERT INTO drivers (id, status, rating, rides_count) VALUES
    ('20000000-0000-4000-8000-000000000001', 'AVAILABLE', 4.8, 340),
    ('30000000-0000-4000-8000-000000000001', 'AVAILABLE', 4.9, 210)
ON CONFLICT (id) DO NOTHING;

INSERT INTO vehicles (id, driver_id, make, model, plate, capacity, is_active) VALUES
    ('d1000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001', 'Toyota', 'Prius',    '7ABC123', 4, TRUE),
    ('d2000000-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001', 'Tesla',  'Model 3', '9XYZ456', 4, TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO driver_locations (driver_id, lat, lng, captured_at) VALUES
    ('20000000-0000-4000-8000-000000000001', 37.7749, -122.4194, now()),
    ('30000000-0000-4000-8000-000000000001', 37.7803, -122.4120, now())
ON CONFLICT (driver_id) DO NOTHING;

INSERT INTO payment_methods (id, rider_id, kind, provider_token, last4, is_default) VALUES
    ('c1000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'CARD', 'tok_visa_4242', '4242', TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO rate_cards (id, name, currency, base_fare_cents, per_km_cents, per_min_cents, surge_max_bps, is_active) VALUES
    ('b1000000-0000-4000-8000-000000000001', 'SFO-default', 'USD', 250, 80, 30, 150, TRUE)
ON CONFLICT (id) DO NOTHING;

INSERT INTO ledger_accounts (id, owner_type, owner_id, currency) VALUES
    ('a0000000-0000-4000-8000-000000000001', 'PLATFORM', NULL, 'USD'),
    ('a1000000-0000-4000-8000-000000000001', 'RIDER',    '10000000-0000-4000-8000-000000000001', 'USD'),
    ('a2000000-0000-4000-8000-000000000001', 'DRIVER',   '20000000-0000-4000-8000-000000000001', 'USD'),
    ('a3000000-0000-4000-8000-000000000001', 'DRIVER',   '30000000-0000-4000-8000-000000000001', 'USD')
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- One fully-settled trip:  Renata  ->  Dara,  $13.00 metered fare, paid.
-- Every frozen/snapshot constraint is satisfied explicitly so the row is a
-- faithful example of the aggregate (quote 1500c, fare 1300c, 20% = 260c).
-- -----------------------------------------------------------------------------
INSERT INTO trips (
    id, rider_id, driver_id, status, payment_method_id,
    pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
    rate_card_id, currency, base_fare_cents, per_km_cents, per_min_cents, surge_bps,
    estimated_km, estimated_minutes, quote_total_cents,
    actual_km, actual_minutes, fare_cents, cancellation_fee_cents,
    driver_name_snapshot, vehicle_plate_snapshot,
    requested_at, accepted_at, completed_at)
VALUES (
    'f0000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001',
    '20000000-0000-4000-8000-000000000001',
    'PAID',
    'c1000000-0000-4000-8000-000000000001',
    37.7710, -122.4100, 37.7840, -122.3970,
    'b1000000-0000-4000-8000-000000000001', 'USD', 250, 80, 30, 150,
    5, 10, 1500,
    4, 8, 1300, 0,
    'Dara Driver', '7ABC123',
    now() - interval '1 day', now() - interval '1 day' + interval '7 minutes',
    now() - interval '1 day' + interval '19 minutes')
ON CONFLICT (id) DO NOTHING;

-- The single captured payment (PAY-01/04: amount == fare == 1300, USD).
INSERT INTO payments (id, trip_id, payment_method_id, amount_cents, currency, status, provider_txn_id, captured_at) VALUES
    ('e1000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001',
     'c1000000-0000-4000-8000-000000000001', 1300, 'USD', 'CAPTURED', 'psp_txn_1300',
     now() - interval '1 day' + interval '20 minutes')
ON CONFLICT (id) DO NOTHING;

-- Double-entry settlement for the fare (PAY-03, ADR-2: three balanced pairs
-- through the platform clearing account).  rider -1300 / driver +1040 / plat +260.
INSERT INTO ledger_entries (id, transaction_id, account_id, trip_id, entry_type, side, amount_cents, currency) VALUES
    -- settle  (transaction_id #...01)
    ('a4000000-0000-4000-8000-000000000001', '90000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001', 'FARE', 'DEBIT',  1300, 'USD'),
    ('a4000000-0000-4000-8000-000000000002', '90000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001', 'FARE', 'CREDIT', 1300, 'USD'),
    -- payout  (transaction_id #...02)
    ('a4000000-0000-4000-8000-000000000003', '90000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001', 'FARE', 'DEBIT',  1040, 'USD'),
    ('a4000000-0000-4000-8000-000000000004', '90000000-0000-4000-8000-000000000002', 'a2000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001', 'FARE', 'CREDIT', 1040, 'USD'),
    -- commission  (transaction_id #...03)
    ('a4000000-0000-4000-8000-000000000005', '90000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001', 'COMMISSION', 'DEBIT',  260, 'USD'),
    ('a4000000-0000-4000-8000-000000000006', '90000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000001', 'COMMISSION', 'CREDIT', 260, 'USD')
ON CONFLICT (id) DO NOTHING;

COMMIT;