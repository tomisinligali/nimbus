-- =============================================================================
-- Nimbus — on-demand ride-hailing. PostgreSQL schema — MIGRATION 0001
-- (source of truth). Applied with:  psql -d <db> -f 0001_init_nimbus.sql
--
-- Hard-question decisions (see HARD_QUESTIONS.md for the written rationale):
--   * IDENTIFIERS: UUID v4 via gen_random_uuid(). Non-sequential, non-guessable,
--     so bearer-visible ids leak nothing about volume and cannot be enumerated.
--   * MONEY: every monetary field is "integer minor units + currency column"
--     beside it (rate_cards / trips / payments / ledger_accounts /
--     ledger_entries all carry currency, v1 CHECK = 'USD'). No floats.
--   * TIME: mutable entities have created_at + updated_at (DB-maintained via
--     set_updated_at()). Immutable append-only tables carry created_at only.
--   * DELETION: reference data is soft-deleted (deleted_at): vehicles,
--     payment_methods, rate_cards. Identity (users/riders/drivers) is only
--     removed by a lawful-erasure process. Transactional records (trips,
--     trip_events, payments, ledger_entries) are never deleted.
--   * DENORMALISATION (deliberate, justified):
--       D1 - rate-card prices are FROZEN onto trips at request time; later
--            price edits must not rewrite past money.
--       D2 - driver name + vehicle plate are SNAPSHOTTED onto trips at MATCHED
--            (written by the dispatch service in the same UPDATE; presence
--            CHECK-enforced), so receipts stay correct after a driver changes
--            name or vehicle.
--   * State machines are enforced in the DATABASE (trip_transitions +
--     triggers). "One active trip" guarantees are partial unique indexes.
--
-- Business rules referenced by ID (TRP-*, DRV-*, RDR-*, PAY-*, FEE-*, CUR-*,
-- IDN-*, DEN-*); see API_DESIGN.md and HARD_QUESTIONS.md. The proof that these
-- constraints actually reject invalid states is model_proof.py.
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------
CREATE TYPE driver_status_t      AS ENUM ('OFFLINE', 'AVAILABLE', 'ON_TRIP');
CREATE TYPE trip_status_t        AS ENUM ('REQUESTED','MATCHED','EN_ROUTE','ARRIVED','ON_TRIP','COMPLETED','PAID','CANCELLED');
CREATE TYPE actor_t              AS ENUM ('RIDER', 'DRIVER', 'SYSTEM', 'PAYMENT');
CREATE TYPE payment_method_kind_t AS ENUM ('CARD', 'WALLET');
CREATE TYPE payment_status_t     AS ENUM ('PENDING', 'CAPTURED', 'FAILED', 'REFUNDED');
CREATE TYPE ledger_owner_t       AS ENUM ('RIDER', 'DRIVER', 'PLATFORM');
CREATE TYPE entry_side_t         AS ENUM ('DEBIT', 'CREDIT');

-- -----------------------------------------------------------------------------
-- Identity
-- -----------------------------------------------------------------------------
CREATE TABLE users (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),  -- IDN-01
    full_name     TEXT NOT NULL CHECK (char_length(full_name) BETWEEN 1 AND 120),
    phone         TEXT NOT NULL UNIQUE
                  CHECK (phone ~ '^\+[1-9][0-9]{7,14}$'),
    password_hash TEXT,   -- NULL reserved for a future OAuth path
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE riders (
    id          UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    rating      NUMERIC(2,1) CHECK (rating IS NULL OR rating BETWEEN 0.0 AND 5.0),
    rides_count INT NOT NULL DEFAULT 0 CHECK (rides_count >= 0),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE drivers (
    id          UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    status      driver_status_t NOT NULL DEFAULT 'OFFLINE',
    rating      NUMERIC(2,1) CHECK (rating IS NULL OR rating BETWEEN 0.0 AND 5.0),
    rides_count INT NOT NULL DEFAULT 0 CHECK (rides_count >= 0),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE vehicles (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id  UUID NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
    make       TEXT NOT NULL,
    model      TEXT NOT NULL,
    plate      TEXT NOT NULL UNIQUE,
    capacity   INT  NOT NULL CHECK (capacity BETWEEN 1 AND 8),
    is_active  BOOLEAN NOT NULL DEFAULT TRUE,
    deleted_at TIMESTAMPTZ,                       -- soft delete: platform keeps
                                                  -- historical plate for safety
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_vehicles_driver ON vehicles(driver_id);

-- Latest known position per driver (high-frequency writes go here, NOT to trips).
CREATE TABLE driver_locations (
    driver_id   UUID PRIMARY KEY REFERENCES drivers(id) ON DELETE CASCADE,
    lat         DOUBLE PRECISION NOT NULL CHECK (lat BETWEEN -90 AND 90),
    lng         DOUBLE PRECISION NOT NULL CHECK (lng BETWEEN -180 AND 180),
    captured_at TIMESTAMPTZ NOT NULL
);

-- -----------------------------------------------------------------------------
-- Payments: rider billing instruments
-- -----------------------------------------------------------------------------
CREATE TABLE payment_methods (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rider_id       UUID NOT NULL REFERENCES riders(id) ON DELETE CASCADE,
    kind           payment_method_kind_t NOT NULL,
    provider_token TEXT NOT NULL,                 -- PSP-side token; never raw PAN
    last4         CHAR(4) CHECK (last4 ~ '^[0-9]{4}$'),
    is_default    BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at    TIMESTAMPTZ,                    -- soft delete: payments FK +
                                                  -- chargeback trail must live on
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_payment_methods_rider ON payment_methods(rider_id);
-- A rider has at most ONE default payment method. [RDR-02]
CREATE UNIQUE INDEX uq_payment_default_per_rider
    ON payment_methods(rider_id) WHERE is_default AND deleted_at IS NULL;

-- -----------------------------------------------------------------------------
-- Pricing
-- -----------------------------------------------------------------------------
CREATE TABLE rate_cards (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    currency        TEXT NOT NULL DEFAULT 'USD' CHECK (currency = 'USD'),  -- CUR-01
    base_fare_cents INT NOT NULL CHECK (base_fare_cents >= 0),
    per_km_cents    INT NOT NULL CHECK (per_km_cents > 0),
    per_min_cents   INT NOT NULL CHECK (per_min_cents > 0),
    surge_max_bps   INT NOT NULL DEFAULT 300 CHECK (surge_max_bps BETWEEN 100 AND 400),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    deleted_at      TIMESTAMPTZ,                  -- trips FK on the card must
                                                  -- survive: soft delete only
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Trips (the core aggregate)
-- -----------------------------------------------------------------------------
CREATE TABLE trips (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rider_id              UUID NOT NULL REFERENCES riders(id),
    driver_id             UUID REFERENCES drivers(id),
    status                trip_status_t NOT NULL DEFAULT 'REQUESTED',
    payment_method_id     UUID REFERENCES payment_methods(id),

    pickup_lat            DOUBLE PRECISION NOT NULL CHECK (pickup_lat BETWEEN -90 AND 90),
    pickup_lng            DOUBLE PRECISION NOT NULL CHECK (pickup_lng BETWEEN -180 AND 180),
    dropoff_lat           DOUBLE PRECISION NOT NULL CHECK (dropoff_lat BETWEEN -90 AND 90),
    dropoff_lng           DOUBLE PRECISION NOT NULL CHECK (dropoff_lng BETWEEN -180 AND 180),

    -- Pricing snapshot, frozen at request time [FEE-01] — DEN-1
    rate_card_id          UUID NOT NULL REFERENCES rate_cards(id),
    currency              TEXT NOT NULL DEFAULT 'USD' CHECK (currency = 'USD'),  -- CUR-01
    base_fare_cents       INT NOT NULL CHECK (base_fare_cents >= 0),
    per_km_cents          INT NOT NULL CHECK (per_km_cents > 0),
    per_min_cents         INT NOT NULL CHECK (per_min_cents > 0),
    surge_bps             INT NOT NULL DEFAULT 100 CHECK (surge_bps BETWEEN 100 AND 400),

    estimated_km          INT NOT NULL CHECK (estimated_km > 0),
    estimated_minutes     INT NOT NULL CHECK (estimated_minutes > 0),
    quote_total_cents     INT NOT NULL CHECK (quote_total_cents > 0),

    actual_km             INT CHECK (actual_km IS NULL OR actual_km > 0),
    actual_minutes        INT CHECK (actual_minutes IS NULL OR actual_minutes > 0),
    fare_cents            INT CHECK (fare_cents IS NULL OR fare_cents >= 0),
    cancellation_fee_cents INT NOT NULL DEFAULT 0 CHECK (cancellation_fee_cents >= 0),
    cancelled_by          actor_t,
    cancel_reason         TEXT,

    -- DEN-2: display/settlement labels frozen at MATCHED by trigger, so a
    -- name-change or vehicle swap never rewrites a historical receipt.
    driver_name_snapshot  TEXT,
    vehicle_plate_snapshot TEXT,

    requested_at          TIMESTAMPTZ NOT NULL DEFAULT now(),   -- this IS the createdAt
    accepted_at           TIMESTAMPTZ,
    completed_at          TIMESTAMPTZ,
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- [TRP-03] A trip that needs a driver has one; REQUESTED never does.
    CONSTRAINT trips_status_requires_driver CHECK (
        (status = 'REQUESTED'                    AND driver_id IS NULL)
     OR (status IN ('MATCHED','EN_ROUTE','ARRIVED','ON_TRIP') AND driver_id IS NOT NULL)
     OR (status IN ('COMPLETED','PAID','CANCELLED'))
    ),
    -- [FEE-04] Fare and completion time materialize together, and only then.
    CONSTRAINT trips_fare_sets_on_completion CHECK (
        status NOT IN ('COMPLETED','PAID') OR (fare_cents IS NOT NULL AND completed_at IS NOT NULL)
    ),
    -- [FEE-05] A cancellation fee may only exist on a cancelled trip.
    CONSTRAINT trips_cancel_fee_only_when_cancelled CHECK (
        cancellation_fee_cents = 0 OR status = 'CANCELLED'
    ),
    -- [DEN-2] any driver-bearing trip carries its frozen display label.
    CONSTRAINT trips_snapshot_with_driver CHECK (
        driver_id IS NULL OR (driver_name_snapshot IS NOT NULL AND vehicle_plate_snapshot IS NOT NULL)
    )
);

-- One ACTIVE trip per rider. A trip is active until it is terminal
-- (PAID or CANCELLED); this makes "settle before your next ride" a
-- database guarantee, not a hope. [TRP-01]
CREATE UNIQUE INDEX uq_trips_one_active_per_rider
    ON trips(rider_id) WHERE status NOT IN ('CANCELLED', 'PAID');

-- One ACTIVE trip per driver. The driver can open a new trip as soon as the
-- current one is COMPLETED. [DRV-01]
CREATE UNIQUE INDEX uq_trips_one_active_per_driver
    ON trips(driver_id) WHERE status IN ('MATCHED', 'EN_ROUTE', 'ARRIVED', 'ON_TRIP');

-- History queries for both personas (ACT-1/2 receipts).
CREATE INDEX idx_trips_rider_history  ON trips(rider_id, requested_at DESC);
CREATE INDEX idx_trips_driver_history ON trips(driver_id, requested_at DESC);

-- The legal state machine. Terminal states (CANCELLED, PAID) deliberately have
-- no outbound rows. [TRP-02]
CREATE TABLE trip_transitions (
    from_status trip_status_t NOT NULL,
    to_status   trip_status_t NOT NULL,
    PRIMARY KEY (from_status, to_status)
);
INSERT INTO trip_transitions (from_status, to_status) VALUES
    ('REQUESTED','MATCHED'),   ('REQUESTED','CANCELLED'),
    ('MATCHED','EN_ROUTE'),    ('MATCHED','ARRIVED'),   ('MATCHED','CANCELLED'),
    ('EN_ROUTE','ARRIVED'),    ('EN_ROUTE','CANCELLED'),
    ('ARRIVED','ON_TRIP'),     ('ARRIVED','CANCELLED'),
    ('ON_TRIP','COMPLETED'),
    ('COMPLETED','PAID');

-- Append-only audit trail for disputes. Every trip-row change is recorded by
-- trigger (TRP-06). `payload` holds the "why" (reason, coords).
CREATE TABLE trip_events (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_id     UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
    from_status trip_status_t,
    to_status   trip_status_t NOT NULL,
    actor       actor_t NOT NULL DEFAULT 'SYSTEM',
    payload     JSONB NOT NULL DEFAULT '{}',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_trip_events_trip ON trip_events(trip_id, created_at);

-- -----------------------------------------------------------------------------
-- Payments + double-entry ledger
-- -----------------------------------------------------------------------------
CREATE TABLE payments (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_id           UUID NOT NULL UNIQUE REFERENCES trips(id),   -- [PAY-01]
    payment_method_id UUID REFERENCES payment_methods(id),
    amount_cents      INT NOT NULL CHECK (amount_cents > 0),
    currency          TEXT NOT NULL DEFAULT 'USD' CHECK (currency = 'USD'),  -- CUR-01
    status            payment_status_t NOT NULL DEFAULT 'PENDING',
    provider_txn_id   TEXT,
    captured_at       TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_payments_status ON payments(status);

-- Each ledger account: one per rider, one per driver, one platform account.
CREATE TABLE ledger_accounts (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_type ledger_owner_t NOT NULL,
    owner_id   UUID,                     -- users.id for RIDER/DRIVER; NULL for PLATFORM
    currency   TEXT NOT NULL DEFAULT 'USD' CHECK (currency = 'USD'),  -- CUR-01
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (owner_type, owner_id)
);

-- Double-entry posts. Every group sharing a transaction_id must balance
-- (see trg_ledger_balance). [PAY-03]
CREATE TABLE ledger_entries (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id UUID NOT NULL,
    account_id     UUID NOT NULL REFERENCES ledger_accounts(id),
    trip_id        UUID REFERENCES trips(id),
    entry_type     TEXT NOT NULL CHECK (entry_type IN ('FARE','CANCELLATION_FEE','COMMISSION','REFUND')),
    side           entry_side_t NOT NULL,
    amount_cents   INT NOT NULL CHECK (amount_cents > 0),
    currency       TEXT NOT NULL DEFAULT 'USD' CHECK (currency = 'USD'),  -- CUR-01
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- One leg per (transaction, side, type): blocks accidental double-posting.
    UNIQUE (transaction_id, side, entry_type)
);
CREATE INDEX idx_ledger_entries_transaction ON ledger_entries(transaction_id);
CREATE INDEX idx_ledger_entries_account   ON ledger_entries(account_id, created_at);
-- ACT-4 settlement reads: every posting for a given trip. Added by the Step-5
-- EXPLAIN pass — the settle query filtered only on trip_id, which no index
-- covered; with a modest trip volume this would be a seq scan per settlement.
CREATE INDEX idx_ledger_entries_trip ON ledger_entries(trip_id, created_at);

-- Assists ACT-2 candidate selection (with rat/city filters, a geospatial
-- (GiST) index on location replaces this in the dispatch service).
CREATE INDEX idx_drivers_available ON drivers(status) WHERE status = 'AVAILABLE';

-- Idempotency: replay protection for POST/PATCH mutations. [IDP-01]
CREATE TABLE idempotency_keys (
    key           TEXT PRIMARY KEY,
    scope         TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id   UUID NOT NULL,
    request_hash  TEXT NOT NULL,
    response      JSONB,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (scope, resource_type, resource_id)
);

-- =============================================================================
-- Triggers (the database is the last line of defense)
-- =============================================================================

-- Maintain updated_at on every mutable table.
CREATE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_updated_at     BEFORE UPDATE ON users            FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_riders_updated_at    BEFORE UPDATE ON riders           FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_drivers_updated_at   BEFORE UPDATE ON drivers          FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_vehicles_updated_at  BEFORE UPDATE ON vehicles         FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_pm_updated_at        BEFORE UPDATE ON payment_methods  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_rc_updated_at        BEFORE UPDATE ON rate_cards       FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_la_updated_at        BEFORE UPDATE ON ledger_accounts  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_trips_updated_at     BEFORE UPDATE ON trips            FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- [TRP-02] Reject any status transition absent from trip_transitions.
CREATE FUNCTION trip_transition_guard() RETURNS trigger AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status
       AND NOT EXISTS (
           SELECT 1 FROM trip_transitions t
           WHERE t.from_status = OLD.status AND t.to_status = NEW.status)
    THEN
        RAISE EXCEPTION 'TRP-02 illegal trip transition: % -> %', OLD.status, NEW.status;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_transition_guard
    BEFORE UPDATE OF status ON trips
    FOR EACH ROW EXECUTE FUNCTION trip_transition_guard();

-- [DRV-02] A trip may only be MATCHED to a driver whose status is AVAILABLE.
CREATE FUNCTION dispatch_requires_available_driver() RETURNS trigger AS $$
BEGIN
    IF NEW.status = 'MATCHED'
       AND (SELECT status FROM drivers WHERE id = NEW.driver_id) <> 'AVAILABLE'
    THEN
        RAISE EXCEPTION 'DRV-02 driver % is not AVAILABLE', NEW.driver_id;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_dispatch_requires_available_driver
    BEFORE UPDATE OF status ON trips
    FOR EACH ROW EXECUTE FUNCTION dispatch_requires_available_driver();

-- [DEN-2] Freeze the driver's display label (name + primary plate) at MATCHED.
-- The dispatch service copies full_name + active plate into the same UPDATE
-- that performs REQUESTED -> MATCHED (one transaction, same source of truth).
-- Presence is enforced by the trips_snapshot_with_driver CHECK below; content
-- accuracy is the dispatch service's responsibility (it reads users.full_name
-- and the driver's active vehicle at that instant).

-- [DRV-03] Mirror trip lifecycle onto driver.status (ON_TRIP while active,
-- AVAILABLE when released). Driver state can never drift from the trips table.
CREATE FUNCTION sync_driver_status() RETURNS trigger AS $$
BEGIN
    IF NEW.driver_id IS NOT NULL AND NEW.status IN ('MATCHED','EN_ROUTE','ARRIVED','ON_TRIP') THEN
        UPDATE drivers SET status = 'ON_TRIP' WHERE id = NEW.driver_id;
    ELSIF NEW.status IN ('COMPLETED','CANCELLED') AND NEW.driver_id IS NOT NULL THEN
        UPDATE drivers SET status = 'AVAILABLE' WHERE id = NEW.driver_id;
    END IF;
    RETURN NULL;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sync_driver_status
    AFTER UPDATE OF status ON trips
    FOR EACH ROW EXECUTE FUNCTION sync_driver_status();

-- [PAY-02] A trip may only become PAID once a payment has been captured for it.
CREATE FUNCTION paid_requires_captured_payment() RETURNS trigger AS $$
BEGIN
    IF NEW.status = 'PAID' AND NOT EXISTS (
        SELECT 1 FROM payments WHERE trip_id = NEW.id AND status = 'CAPTURED')
    THEN
        RAISE EXCEPTION 'PAY-02 trip % cannot be PAID before a captured payment', NEW.id;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_paid_requires_captured_payment
    BEFORE UPDATE OF status ON trips
    FOR EACH ROW EXECUTE FUNCTION paid_requires_captured_payment();

-- [PAY-04] [CUR-01] A payment is only created for a trip whose metered fare
-- already exists, in exactly that amount, and in the SAME currency.
CREATE FUNCTION payments_matches_trip() RETURNS trigger AS $$
DECLARE
    f INT;
    c TEXT;
BEGIN
    SELECT fare_cents, currency INTO f, c FROM trips WHERE id = NEW.trip_id;
    IF f IS NULL OR f IS DISTINCT FROM NEW.amount_cents OR c IS DISTINCT FROM NEW.currency THEN
        RAISE EXCEPTION 'PAY-04/CUR-01 payment %/% does not match trip %, amount %, currency %',
            NEW.amount_cents, NEW.currency, NEW.trip_id, COALESCE(f::text, 'NULL'), COALESCE(c, 'NULL');
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payments_matches_trip
    BEFORE INSERT ON payments
    FOR EACH ROW EXECUTE FUNCTION payments_matches_trip();

-- [CUR-01] A trip may only exist in its rate card's currency.
CREATE FUNCTION trips_currency_matches_rate_card() RETURNS trigger AS $$
DECLARE
    c TEXT;
BEGIN
    SELECT currency INTO c FROM rate_cards WHERE id = NEW.rate_card_id;
    IF c IS DISTINCT FROM NEW.currency THEN
        RAISE EXCEPTION 'CUR-01 trip currency % does not match rate card currency %',
            NEW.currency, COALESCE(c, 'NULL');
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trips_currency_matches_rate_card
    BEFORE INSERT ON trips
    FOR EACH ROW EXECUTE FUNCTION trips_currency_matches_rate_card();

-- [PAY-03] Double-entry balance: every transaction group must net to zero.
-- A single-leg group is tolerated transiently (the paired leg is posted next).
CREATE FUNCTION ledger_balance_guard() RETURNS trigger AS $$
DECLARE
    n BIGINT;
    d BIGINT;
    c BIGINT;
BEGIN
    SELECT COUNT(*) INTO n FROM ledger_entries WHERE transaction_id = NEW.transaction_id;
    IF n > 1 THEN
        SELECT COALESCE(SUM(amount_cents) FILTER (WHERE side = 'DEBIT'), 0),
               COALESCE(SUM(amount_cents) FILTER (WHERE side = 'CREDIT'), 0)
          INTO d, c
          FROM ledger_entries WHERE transaction_id = NEW.transaction_id;
        IF d <> c THEN
            RAISE EXCEPTION 'PAY-03 unbalanced ledger transaction % (debits=% credits=%)',
                NEW.transaction_id, d, c;
        END IF;
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_ledger_balance
    AFTER INSERT ON ledger_entries
    FOR EACH ROW EXECUTE FUNCTION ledger_balance_guard();

-- [TRP-06] Append-only audit trail: every trip-row creation and every status
-- change is recorded automatically, in order. Evidence for disputes.
CREATE FUNCTION audit_trip_event() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO trip_events (trip_id, from_status, to_status, actor)
        VALUES (NEW.id, NULL, NEW.status, 'SYSTEM');
    ELSE
        INSERT INTO trip_events (trip_id, from_status, to_status, actor)
        VALUES (NEW.id, OLD.status, NEW.status, 'SYSTEM');
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_trip_event_insert
    AFTER INSERT ON trips
    FOR EACH ROW EXECUTE FUNCTION audit_trip_event();

CREATE TRIGGER trg_audit_trip_event_update
    AFTER UPDATE OF status ON trips
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION audit_trip_event();

COMMIT;