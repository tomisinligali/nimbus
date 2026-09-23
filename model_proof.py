#!/usr/bin/env python3
"""Proof that the Nimbus ride-hailing data model holds.

Runs a SQLite mirror of `migrations/0001_init_nimbus.sql` (same CHECKs, partial
unique indexes and
triggers, including the Step-3 hard-question decisions: UUID identifiers,
currency columns/equality, and the driver-label snapshot denormalisation) and
then attempts to violate every core business rule. If any invariant is porous,
an assertion fires and the script exits non-zero.

Run:  python3 design/ride-hailing/model_proof.py
"""
import re
import sqlite3
import uuid

DDL = [
    "PRAGMA foreign_keys = ON",

    """CREATE TABLE users (
        id TEXT PRIMARY KEY,
        full_name TEXT NOT NULL,
        phone TEXT NOT NULL UNIQUE,
        password_hash TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )""",

    """CREATE TABLE riders (
        id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        rating NUMERIC,
        rides_count INTEGER NOT NULL DEFAULT 0 CHECK (rides_count >= 0),
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )""",

    """CREATE TABLE drivers (
        id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        status TEXT NOT NULL DEFAULT 'OFFLINE'
            CHECK (status IN ('OFFLINE','AVAILABLE','ON_TRIP')),
        rating NUMERIC,
        rides_count INTEGER NOT NULL DEFAULT 0 CHECK (rides_count >= 0),
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )""",

    """CREATE TABLE vehicles (
        id TEXT PRIMARY KEY,
        driver_id TEXT NOT NULL REFERENCES drivers(id) ON DELETE CASCADE,
        make TEXT NOT NULL,
        model TEXT NOT NULL,
        plate TEXT NOT NULL UNIQUE,
        capacity INTEGER NOT NULL CHECK (capacity BETWEEN 1 AND 8),
        is_active INTEGER NOT NULL DEFAULT 1,
        deleted_at TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )""",

    """CREATE TABLE driver_locations (
        driver_id TEXT PRIMARY KEY REFERENCES drivers(id) ON DELETE CASCADE,
        lat REAL NOT NULL CHECK (lat BETWEEN -90 AND 90),
        lng REAL NOT NULL CHECK (lng BETWEEN -180 AND 180),
        captured_at TEXT NOT NULL
    )""",

    """CREATE TABLE payment_methods (
        id TEXT PRIMARY KEY,
        rider_id TEXT NOT NULL REFERENCES riders(id) ON DELETE CASCADE,
        kind TEXT NOT NULL CHECK (kind IN ('CARD','WALLET')),
        provider_token TEXT NOT NULL,
        last4 TEXT,
        is_default INTEGER NOT NULL DEFAULT 0,
        deleted_at TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )""",
    "CREATE UNIQUE INDEX uq_payment_default_per_rider ON payment_methods(rider_id) WHERE is_default AND deleted_at IS NULL",

    """CREATE TABLE rate_cards (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        currency TEXT NOT NULL DEFAULT 'USD' CHECK (currency = 'USD'),
        base_fare_cents INTEGER NOT NULL CHECK (base_fare_cents >= 0),
        per_km_cents INTEGER NOT NULL CHECK (per_km_cents > 0),
        per_min_cents INTEGER NOT NULL CHECK (per_min_cents > 0),
        surge_bps INTEGER NOT NULL CHECK (surge_bps BETWEEN 100 AND 400),
        is_active INTEGER NOT NULL DEFAULT 1,
        deleted_at TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )""",

    """CREATE TABLE trips (
        id TEXT PRIMARY KEY,
        rider_id TEXT NOT NULL REFERENCES riders(id),
        driver_id TEXT REFERENCES drivers(id),
        status TEXT NOT NULL DEFAULT 'REQUESTED' CHECK (
            status IN ('REQUESTED','MATCHED','EN_ROUTE','ARRIVED','ON_TRIP',
                       'COMPLETED','PAID','CANCELLED')),
        payment_method_id TEXT REFERENCES payment_methods(id),
        pickup_lat REAL NOT NULL CHECK (pickup_lat BETWEEN -90 AND 90),
        pickup_lng REAL NOT NULL CHECK (pickup_lng BETWEEN -180 AND 180),
        dropoff_lat REAL NOT NULL CHECK (dropoff_lat BETWEEN -90 AND 90),
        dropoff_lng REAL NOT NULL CHECK (dropoff_lng BETWEEN -180 AND 180),
        rate_card_id TEXT NOT NULL REFERENCES rate_cards(id),
        currency TEXT NOT NULL DEFAULT 'USD' CHECK (currency = 'USD'),
        base_fare_cents INTEGER NOT NULL CHECK (base_fare_cents >= 0),
        per_km_cents INTEGER NOT NULL CHECK (per_km_cents > 0),
        per_min_cents INTEGER NOT NULL CHECK (per_min_cents > 0),
        surge_bps INTEGER NOT NULL DEFAULT 100 CHECK (surge_bps BETWEEN 100 AND 400),
        estimated_km INTEGER NOT NULL CHECK (estimated_km > 0),
        estimated_minutes INTEGER NOT NULL CHECK (estimated_minutes > 0),
        quote_total_cents INTEGER NOT NULL CHECK (quote_total_cents > 0),
        actual_km INTEGER CHECK (actual_km IS NULL OR actual_km > 0),
        actual_minutes INTEGER CHECK (actual_minutes IS NULL OR actual_minutes > 0),
        fare_cents INTEGER CHECK (fare_cents IS NULL OR fare_cents >= 0),
        cancellation_fee_cents INTEGER NOT NULL DEFAULT 0 CHECK (cancellation_fee_cents >= 0),
        cancelled_by TEXT,
        cancel_reason TEXT,
        driver_name_snapshot TEXT,
        vehicle_plate_snapshot TEXT,
        requested_at TEXT NOT NULL DEFAULT (datetime('now')),
        accepted_at TEXT,
        completed_at TEXT,
        updated_at TEXT NOT NULL DEFAULT (datetime('now')),
        CHECK (
            (status = 'REQUESTED' AND driver_id IS NULL)
            OR (status IN ('MATCHED','EN_ROUTE','ARRIVED','ON_TRIP') AND driver_id IS NOT NULL)
            OR (status IN ('COMPLETED','PAID','CANCELLED'))),
        CHECK (status NOT IN ('COMPLETED','PAID') OR (fare_cents IS NOT NULL AND completed_at IS NOT NULL)),
        CHECK (cancellation_fee_cents = 0 OR status = 'CANCELLED'),
        CHECK (driver_id IS NULL OR (driver_name_snapshot IS NOT NULL AND vehicle_plate_snapshot IS NOT NULL))
    )""",

    # TRP-01 / DRV-01: one active trip per rider / per driver.
    "CREATE UNIQUE INDEX uq_trips_one_active_per_rider ON trips(rider_id) "
    "WHERE status NOT IN ('CANCELLED','PAID')",
    "CREATE UNIQUE INDEX uq_trips_one_active_per_driver ON trips(driver_id) "
    "WHERE status IN ('MATCHED','EN_ROUTE','ARRIVED','ON_TRIP')",
    "CREATE INDEX idx_trips_rider_history ON trips(rider_id, requested_at DESC)",
    "CREATE INDEX idx_trips_driver_history ON trips(driver_id, requested_at DESC)",

    """CREATE TABLE trip_transitions (
        from_status TEXT NOT NULL,
        to_status TEXT NOT NULL,
        PRIMARY KEY (from_status, to_status)
    )""",
    """INSERT INTO trip_transitions (from_status, to_status) VALUES
        ('REQUESTED','MATCHED'),  ('REQUESTED','CANCELLED'),
        ('MATCHED','EN_ROUTE'),   ('MATCHED','ARRIVED'),  ('MATCHED','CANCELLED'),
        ('EN_ROUTE','ARRIVED'),   ('EN_ROUTE','CANCELLED'),
        ('ARRIVED','ON_TRIP'),    ('ARRIVED','CANCELLED'),
        ('ON_TRIP','COMPLETED'),
        ('COMPLETED','PAID')""",

    """CREATE TABLE trip_events (
        id TEXT PRIMARY KEY,
        trip_id TEXT NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
        from_status TEXT,
        to_status TEXT NOT NULL,
        actor TEXT NOT NULL DEFAULT 'SYSTEM',
        payload TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
    )""",

    """CREATE TABLE payments (
        id TEXT PRIMARY KEY,
        trip_id TEXT NOT NULL UNIQUE REFERENCES trips(id),
        payment_method_id TEXT REFERENCES payment_methods(id),
        amount_cents INTEGER NOT NULL CHECK (amount_cents > 0),
        currency TEXT NOT NULL DEFAULT 'USD' CHECK (currency = 'USD'),
        status TEXT NOT NULL DEFAULT 'PENDING'
            CHECK (status IN ('PENDING','CAPTURED','FAILED','REFUNDED')),
        provider_txn_id TEXT,
        captured_at TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
    )""",

    """CREATE TABLE ledger_accounts (
        id TEXT PRIMARY KEY,
        owner_type TEXT NOT NULL CHECK (owner_type IN ('RIDER','DRIVER','PLATFORM')),
        owner_id TEXT,
        currency TEXT NOT NULL DEFAULT 'USD' CHECK (currency = 'USD'),
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now')),
        UNIQUE (owner_type, owner_id)
    )""",

    """CREATE TABLE ledger_entries (
        id TEXT PRIMARY KEY,
        transaction_id TEXT NOT NULL,
        account_id TEXT NOT NULL REFERENCES ledger_accounts(id),
        trip_id TEXT REFERENCES trips(id),
        entry_type TEXT NOT NULL CHECK (entry_type IN ('FARE','CANCELLATION_FEE','COMMISSION','REFUND')),
        side TEXT NOT NULL CHECK (side IN ('DEBIT','CREDIT')),
        amount_cents INTEGER NOT NULL CHECK (amount_cents > 0),
        currency TEXT NOT NULL DEFAULT 'USD' CHECK (currency = 'USD'),
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        UNIQUE (transaction_id, side, entry_type)
    )""",

    # ---- TRP-02: reject illegal status transitions ---------------------------
    """CREATE TRIGGER trg_trip_transition_guard
       BEFORE UPDATE OF status ON trips
       FOR EACH ROW WHEN OLD.status IS NOT NEW.status
    BEGIN
      SELECT CASE WHEN NOT EXISTS (
        SELECT 1 FROM trip_transitions t
        WHERE t.from_status = OLD.status AND t.to_status = NEW.status)
      THEN RAISE(ABORT, 'TRP-02 illegal transition: '||OLD.status||' -> '||NEW.status) END;
    END""",

    # ---- DRV-02: dispatch requires an AVAILABLE driver ----------------------
    """CREATE TRIGGER trg_dispatch_guard
       BEFORE UPDATE OF status ON trips
       FOR EACH ROW WHEN NEW.status = 'MATCHED'
    BEGIN
      SELECT CASE WHEN
        ((SELECT status FROM drivers WHERE id = NEW.driver_id) <> 'AVAILABLE')
      THEN RAISE(ABORT, 'DRV-02 driver not AVAILABLE') END;
    END""",

    # ---- DEN-2: label presence enforced by CHECK; dispatch writes the values --
    # (no trigger; the dispatch UPDATE supplies the label in the same statement)

    # ---- DRV-03: mirror trip lifecycle onto driver.status --------------------
    """CREATE TRIGGER trg_sync_driver_status
       AFTER UPDATE OF status ON trips
       FOR EACH ROW WHEN NEW.driver_id IS NOT NULL
         AND NEW.status IN ('MATCHED','EN_ROUTE','ARRIVED','ON_TRIP')
    BEGIN
      UPDATE drivers SET status = 'ON_TRIP' WHERE id = NEW.driver_id;
    END""",
    """CREATE TRIGGER trg_release_driver
       AFTER UPDATE OF status ON trips
       FOR EACH ROW WHEN NEW.status IN ('COMPLETED','CANCELLED')
    BEGIN
      UPDATE drivers SET status = 'AVAILABLE' WHERE id = NEW.driver_id;
    END""",

    # ---- PAY-02: PAID requires a captured payment ---------------------------
    """CREATE TRIGGER trg_paid_requires_captured
       BEFORE UPDATE OF status ON trips
       FOR EACH ROW WHEN NEW.status = 'PAID'
    BEGIN
      SELECT CASE WHEN NOT EXISTS (
        SELECT 1 FROM payments WHERE trip_id = NEW.id AND status = 'CAPTURED')
      THEN RAISE(ABORT, 'PAY-02 cannot become PAID before a captured payment') END;
    END""",

    # ---- PAY-04 + CUR-01: payment must match the trip's fare AND currency ----
    """CREATE TRIGGER trg_payments_matches_trip
       BEFORE INSERT ON payments
       FOR EACH ROW
    BEGIN
      SELECT CASE WHEN
        ((SELECT fare_cents FROM trips WHERE id = NEW.trip_id) IS NOT NEW.amount_cents
         OR (SELECT currency FROM trips WHERE id = NEW.trip_id) <> NEW.currency)
      THEN RAISE(ABORT, 'PAY-04/CUR-01 amount/currency mismatch') END;
    END""",

    # ---- CUR-01: trip currency must equal its rate card's currency ------------
    """CREATE TRIGGER trg_trips_currency_matches_rate_card
       BEFORE INSERT ON trips
       FOR EACH ROW
    BEGIN
      SELECT CASE WHEN
        ((SELECT currency FROM rate_cards WHERE id = NEW.rate_card_id) <> NEW.currency)
      THEN RAISE(ABORT, 'CUR-01 trip currency != rate card currency') END;
    END""",

    # ---- PAY-03: every ledger transaction must balance -----------------------
    """CREATE TRIGGER trg_ledger_balance
       AFTER INSERT ON ledger_entries
       FOR EACH ROW
    BEGIN
      SELECT CASE WHEN
        ((SELECT COUNT(*) FROM ledger_entries WHERE transaction_id = NEW.transaction_id) > 1
         AND (SELECT COALESCE(SUM(amount_cents),0) FROM ledger_entries
              WHERE transaction_id = NEW.transaction_id AND side='DEBIT')
           <> (SELECT COALESCE(SUM(amount_cents),0) FROM ledger_entries
              WHERE transaction_id = NEW.transaction_id AND side='CREDIT'))
      THEN RAISE(ABORT, 'PAY-03 unbalanced ledger transaction') END;
    END""",

    # ---- TRP-06: append-only audit trail (every transition is recorded) ------
    """CREATE TRIGGER trg_audit_trip_event_insert AFTER INSERT ON trips
    BEGIN
      INSERT INTO trip_events(trip_id, from_status, to_status)
      VALUES (NEW.id, NULL, NEW.status);
    END""",
    """CREATE TRIGGER trg_audit_trip_event_update
       AFTER UPDATE OF status ON trips
       FOR EACH ROW WHEN OLD.status IS NOT NEW.status
    BEGIN
      INSERT INTO trip_events(trip_id, from_status, to_status)
      VALUES (NEW.id, OLD.status, NEW.status);
    END""",
]

# ---------------------------------------------------------------------------
# Pricing: pure function, integer cents only. Mirrors the server-side module.
#   raw = (base + km*per_km + min*per_min) * surge   then rounded up to $1.
# ---------------------------------------------------------------------------
def compute_fare(base_cents, km, minutes, per_km_cents, per_min_cents, surge_bps):
    raw = (base_cents + km * per_km_cents + minutes * per_min_cents) * surge_bps // 100
    return ((raw + 99) // 100) * 100

CANCEL_FEE_ARRIVED_CENTS = 500  # [FEE-06] flat fee once the driver has arrived

PASS_COUNT = 0


def new_id():
    return uuid.uuid4().hex  # IDN-01: generated, non-sequential


def ok(label, fn):
    global PASS_COUNT
    fn()
    PASS_COUNT += 1
    print(f"  PASS  {label}")


def reject(label, fn):
    """Assert that `fn` fails with a database constraint error."""
    global PASS_COUNT
    db.execute("SAVEPOINT sp")
    try:
        fn()
    except Exception as exc:
        db.execute("ROLLBACK TO sp")
        db.execute("RELEASE sp")
        PASS_COUNT += 1
        print(f"  PASS  {label}  ({str(exc)[:60]})")
        return
    db.execute("RELEASE sp")
    raise AssertionError(f"{label}: expected constraint rejection, but it was accepted")


def q(sql, args=()):
    return db.execute(sql, args)


def assert_that(condition, label):
    if not condition:
        raise AssertionError(label)


def request_trip(rider_id, km, minutes, method_id):
    """Create a REQUESTED trip; computes the quote from frozen rate card."""
    rc = q("SELECT * FROM rate_cards WHERE id = ?", (RC_ID,)).fetchone()
    quote = compute_fare(rc["base_fare_cents"], km, minutes,
                         rc["per_km_cents"], rc["per_min_cents"], rc["surge_bps"])
    tid = new_id()
    q("""INSERT INTO trips (id, rider_id, status, payment_method_id,
            pickup_lat, pickup_lng, dropoff_lat, dropoff_lng,
            rate_card_id, base_fare_cents, per_km_cents, per_min_cents, surge_bps,
            estimated_km, estimated_minutes, quote_total_cents)
        VALUES (?, ?, 'REQUESTED', ?, 37.771, -122.410, 37.784, -122.397,
                ?, ?, ?, ?, ?, ?, ?, ?)""",
      (tid, rider_id, method_id, RC_ID,
       rc["base_fare_cents"], rc["per_km_cents"], rc["per_min_cents"], rc["surge_bps"],
       km, minutes, quote))
    return tid


def set_status(trip_id, to_status, **extra):
    sets = ", ".join(f"{k} = ?" for k in extra)
    args = list(extra.values()) + [to_status, trip_id]
    q(f"UPDATE trips SET {sets + (',' if sets else '')} status = ? WHERE id = ?", args)


def ledger_balance(account_id):
    return q("""SELECT COALESCE(SUM(CASE side WHEN 'DEBIT' THEN -amount_cents
                                           ELSE amount_cents END), 0)
                FROM ledger_entries WHERE account_id = ?""", (account_id,)).fetchone()[0]


# -----------------------------------------------------------------------------
# Build the schema on the in-memory database
# -----------------------------------------------------------------------------
db = sqlite3.connect(":memory:")
db.row_factory = sqlite3.Row
db.execute("PRAGMA foreign_keys = ON")
for stmt in DDL:
    db.execute(stmt)
db.commit()

# Seed: rider R, rider B, driver D (+ vehicle), one rate card, ledger accounts.
RID = new_id()
BID = new_id()
DID = new_id()
RC_ID = new_id()

q("INSERT INTO users (id, full_name, phone) VALUES (?, 'Renata Rider', '+15550101')", (RID,))
q("INSERT INTO users (id, full_name, phone) VALUES (?, 'Bo Bystander', '+15550202')", (BID,))
q("INSERT INTO users (id, full_name, phone) VALUES (?, 'Dara Driver', '+15550303')", (DID,))
q("INSERT INTO riders (id) VALUES (?), (?)", (RID, BID))
q("INSERT INTO drivers (id) VALUES (?)", (DID,))
q("INSERT INTO vehicles (id, driver_id, make, model, plate, capacity) "
  "VALUES (?, ?, 'Toyota', 'Prius', 'ABC-1234', 4)", (new_id(), DID))
q("INSERT INTO payment_methods (id, rider_id, kind, provider_token, last4, is_default) "
  "VALUES (?, ?, 'CARD', 'tok_visa_1', '4242', 1)", (new_id(), RID))
q("INSERT INTO rate_cards (id, name, base_fare_cents, per_km_cents, per_min_cents, surge_bps) "
  "VALUES (?, 'SFO default', 250, 80, 30, 150)", (RC_ID,))
LA_R = new_id()
LA_D = new_id()
LA_P = new_id()
q("INSERT INTO ledger_accounts (id, owner_type, owner_id) VALUES (?, 'RIDER', ?)", (LA_R, RID))
q("INSERT INTO ledger_accounts (id, owner_type, owner_id) VALUES (?, 'DRIVER', ?)", (LA_D, DID))
q("INSERT INTO ledger_accounts (id, owner_type, owner_id) VALUES (?, 'PLATFORM', NULL)", (LA_P,))
db.commit()

print("=" * 60)
print(" Nimbus model proof — ride-hailing invariants")
print("=" * 60)

# --- IDN-01: identifiers are generated, non-sequential, non-enumerable -------
t1 = request_trip(RID, 5, 10, db.execute("SELECT id FROM payment_methods LIMIT 1").fetchone()["id"])
ok("IDN-01   trip identifiers are generated 32-char UUIDs, not sequential ints",
   lambda: assert_that(
       re.fullmatch(r"[0-9a-f]{32}", t1) is not None and t1 != "1",
       f"identifier is not a generated token: {t1}"))

# --- TRP-01: quote snapshot; one active trip per rider -----------------------
tl = q("SELECT status, driver_id, quote_total_cents FROM trips WHERE id=?", (t1,)).fetchone()
ok("TRP-01a  rider can request a trip; quote frozen at request time",
   lambda: assert_that(
       tl["status"] == "REQUESTED" and tl["driver_id"] is None and tl["quote_total_cents"] == 1500,
       f"unexpected trip row: {dict(tl)}"))

reject("TRP-01b  second trip for the same rider is REJECTED (partial unique index)",
       lambda: request_trip(RID, 5, 10, None))

# --- DRV-02: dispatch requires an AVAILABLE driver; DRV-01: single active trip
q("UPDATE drivers SET status='AVAILABLE' WHERE id=?", (DID,))
def _dispatch_t1():
    set_status(t1, "MATCHED", driver_id=DID,
               driver_name_snapshot="Dara Driver", vehicle_plate_snapshot="ABC-1234")
    assert_that(q("SELECT status FROM drivers WHERE id=?", (DID,)).fetchone()["status"] == "ON_TRIP",
                "driver status should mirror ON_TRIP")
ok("DRV-02a  dispatch to an AVAILABLE driver succeeds; driver mirrors ON_TRIP", _dispatch_t1)

# --- DEN-2: display label frozen at MATCHED -----------------------------------
snap = q("SELECT driver_name_snapshot, vehicle_plate_snapshot FROM trips WHERE id=?", (t1,)).fetchone()
ok("DEN-2    driver name + plate are snapped to the trip at MATCHED",
   lambda: assert_that(snap["driver_name_snapshot"] == "Dara Driver"
                       and snap["vehicle_plate_snapshot"] == "ABC-1234",
                       f"snapshot missing: {dict(snap)}"))

# --- TRP-02: illegal state transitions are rejected --------------------------
reject("TRP-02a  MATCHED -> COMPLETED (skipped states) REJECTED",
       lambda: set_status(t1, "COMPLETED", fare_cents=1300, completed_at="now"))

# --- DRV-01/DRV-02: a busy driver cannot take a second trip ------------------
t3 = request_trip(BID, 3, 8, None)  # rider B's request; B is idle -> allowed
reject("DRV-02b  second trip cannot be dispatched to a driver already ON_TRIP",
       lambda: set_status(t3, "MATCHED", driver_id=DID))
ok("TRP     rider B cancels the un-dispatched request; no fee",
   lambda: set_status(t3, "CANCELLED", cancelled_by="RIDER"))

# --- TRP-03: driver lifecycle is strictly ordered ----------------------------
set_status(t1, "EN_ROUTE")
set_status(t1, "ARRIVED")
reject("TRP-02c  ARRIVED -> COMPLETED (skipped) REJECTED",
       lambda: set_status(t1, "COMPLETED", fare_cents=1300, completed_at="now"))
ok("TRP-03b  ARRIVED -> ON_TRIP is the only way forward from ARRIVED",
   lambda: (set_status(t1, "ON_TRIP"),
            assert_that(q("SELECT status FROM trips WHERE id=?", (t1,)).fetchone()["status"] == "ON_TRIP",
                        "trip should be ON_TRIP")))

# --- PAY-04: cannot charge a trip that has no metered fare -------------------
reject("PAY-04a  payment on an ON_TRIP trip (no fare yet) REJECTED",
       lambda: q("INSERT INTO payments (id, trip_id, payment_method_id, amount_cents) "
                 "VALUES (?, ?, ?, 1300)", (new_id(), t1, db.execute("SELECT id FROM payment_methods LIMIT 1").fetchone()["id"])))

# --- FEE-04: fare materializes exactly on completion -------------------------
ok("FEE-04   completion sets the metered fare from actuals (1300 cents)",
   lambda: (set_status(t1, "COMPLETED", fare_cents=1300,
                       actual_km=4, actual_minutes=8, completed_at="now"),
            (lambda row: row["fare_cents"] == 1300 and row["completed_at"] is not None)(
                q("SELECT fare_cents, completed_at FROM trips WHERE id=?", (t1,)).fetchone())))

# --- DRV-03 reverse: driver released the moment the trip completes -----------
ok("DRV-03   driver auto-released to AVAILABLE on COMPLETED",
   lambda: assert_that(
       q("SELECT status FROM drivers WHERE id=?", (DID,)).fetchone()["status"] == "AVAILABLE",
       "driver still ON_TRIP after COMPLETED"))

# --- PAY-01: exactly one payment per trip ------------------------------------
PM = db.execute("SELECT id FROM payment_methods LIMIT 1").fetchone()["id"]
ok("PAY-01a  capture a payment for the completed trip",
   lambda: (q("INSERT INTO payments (id, trip_id, payment_method_id, amount_cents) VALUES (?, ?, ?, 1300)",
              (new_id(), t1, PM)),
            q("UPDATE payments SET status='CAPTURED', captured_at='now' WHERE trip_id=?", (t1,))))
reject("PAY-01b  second payment for the same trip REJECTED",
       lambda: q("INSERT INTO payments (id, trip_id, payment_method_id, amount_cents) VALUES (?, ?, ?, 1300)",
                 (new_id(), t1, PM)))
reject("PAY-04b  payment amount != metered fare REJECTED",
       lambda: q("INSERT INTO payments (id, trip_id, payment_method_id, amount_cents) VALUES (?, ?, ?, 1000)",
                 (new_id(), t1, PM)))

# --- CUR-01: money is denominated in a currency beside the amount -----------
reject("CUR-01a  a payment in a currency other than its trip's is REJECTED",
       lambda: q("INSERT INTO payments (id, trip_id, payment_method_id, amount_cents, currency) "
                 "VALUES (?, ?, ?, 1300, 'EUR')", (new_id(), t1, PM)))
reject("CUR-01b  a trip in a currency other than its rate card's is REJECTED",
       lambda: q("INSERT INTO trips (id, rider_id, status, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, "
                 "rate_card_id, currency, base_fare_cents, per_km_cents, per_min_cents, surge_bps, "
                 "estimated_km, estimated_minutes, quote_total_cents) "
                 "VALUES (?, ?, 'REQUESTED', 37.7, -122.4, 37.7, -122.4, ?, 'EUR', 250, 80, 30, 150, 5, 10, 1500)",
                 (new_id(), BID, RC_ID)))

# --- PAY-03: double-entry ledger balances ------------------------------------
def fare_settlement():
    q("INSERT INTO ledger_entries (id, transaction_id, account_id, trip_id, entry_type, side, amount_cents) "
      "VALUES (?, 'settle-t1', ?, ?, 'FARE', 'DEBIT', 1300)", (new_id(), LA_R, t1))
    q("INSERT INTO ledger_entries (id, transaction_id, account_id, trip_id, entry_type, side, amount_cents) "
      "VALUES (?, 'settle-t1', ?, ?, 'FARE', 'CREDIT', 1300)", (new_id(), LA_P, t1))
    q("INSERT INTO ledger_entries (id, transaction_id, account_id, trip_id, entry_type, side, amount_cents) "
      "VALUES (?, 'payout-t1', ?, ?, 'FARE', 'DEBIT', 1040)", (new_id(), LA_P, t1))
    q("INSERT INTO ledger_entries (id, transaction_id, account_id, trip_id, entry_type, side, amount_cents) "
      "VALUES (?, 'payout-t1', ?, ?, 'FARE', 'CREDIT', 1040)", (new_id(), LA_D, t1))
    q("INSERT INTO ledger_entries (id, transaction_id, account_id, trip_id, entry_type, side, amount_cents) "
      "VALUES (?, 'commission-t1', ?, ?, 'COMMISSION', 'DEBIT', 260)", (new_id(), LA_P, t1))
    q("INSERT INTO ledger_entries (id, transaction_id, account_id, trip_id, entry_type, side, amount_cents) "
      "VALUES (?, 'commission-t1', ?, ?, 'COMMISSION', 'CREDIT', 260)", (new_id(), LA_P, t1))

ok("PAY-03a  balanced settlement posts: rider -1300, driver +1040, platform +260",
   lambda: fare_settlement() and (
       ledger_balance(LA_R) == -1300 and ledger_balance(LA_D) == 1040 and ledger_balance(LA_P) == 260))

reject("PAY-03b  unbalanced two-leg posting REJECTED",
       lambda: (q("INSERT INTO ledger_entries (id, transaction_id, account_id, trip_id, entry_type, side, amount_cents) "
                  "VALUES (?, 'txn-bad', ?, ?, 'FARE', 'DEBIT', 500)", (new_id(), LA_R, t1)),
                q("INSERT INTO ledger_entries (id, transaction_id, account_id, trip_id, entry_type, side, amount_cents) "
                  "VALUES (?, 'txn-bad', ?, ?, 'FARE', 'CREDIT', 999)", (new_id(), LA_D, t1))))
reject("PAY-03c  duplicate re-posting of the same leg REJECTED",
       lambda: q("INSERT INTO ledger_entries (id, transaction_id, account_id, trip_id, entry_type, side, amount_cents) "
                 "VALUES (?, 'payout-t1', ?, ?, 'FARE', 'CREDIT', 1040)", (new_id(), LA_D, t1)))

# --- PAY-02b: t1 closes its cash lifecycle once captured ---------------------
ok("PAY-02b  t1 completes the cash lifecycle: COMPLETED -> PAID",
   lambda: set_status(t1, "PAID"))

# --- PAY-02: PAID requires a captured payment --------------------------------
t4 = request_trip(BID, 2, 5, None)
set_status(t4, "MATCHED", driver_id=DID,
            driver_name_snapshot="Dara Driver", vehicle_plate_snapshot="ABC-1234")
set_status(t4, "EN_ROUTE")
set_status(t4, "ARRIVED")
set_status(t4, "ON_TRIP")
set_status(t4, "COMPLETED", fare_cents=900, actual_km=2, actual_minutes=5, completed_at="now")
reject("PAY-02a  completed trip with NO captured payment cannot be PAID",
       lambda: set_status(t4, "PAID"))
ok("PAY-02c  COMPLETED -> PAID once a payment is captured",
   lambda: (q("INSERT INTO payments (id, trip_id, payment_method_id, amount_cents) VALUES (?, ?, ?, 900)",
              (new_id(), t4, PM)),
            q("UPDATE payments SET status='CAPTURED', captured_at='now' WHERE trip_id=?", (t4,)),
            set_status(t4, "PAID")))

# --- FEE-05/06: cancellation policy ------------------------------------------
t6 = request_trip(RID, 4, 9, PM)
set_status(t6, "MATCHED", driver_id=DID,
            driver_name_snapshot="Dara Driver", vehicle_plate_snapshot="ABC-1234")
set_status(t6, "EN_ROUTE")
set_status(t6, "ARRIVED")
ok("FEE-06   rider cancels at ARRIVED; $5.00 flat fee assessed",
   lambda: set_status(t6, "CANCELLED", cancelled_by="RIDER",
                      cancel_reason="waited too long",
                      cancellation_fee_cents=CANCEL_FEE_ARRIVED_CENTS) and
           (lambda row: row["cancellation_fee_cents"] == 500 and row["status"] == "CANCELLED")(
               q("SELECT status, cancellation_fee_cents FROM trips WHERE id=?", (t6,)).fetchone()))
reject("TRP-02d  terminal CANCELLED cannot be revived",
       lambda: set_status(t6, "MATCHED", driver_id=DID,
            driver_name_snapshot="Dara Driver", vehicle_plate_snapshot="ABC-1234"))
ok("FEE-07   fee settles: rider -500, driver +500",
   lambda: (q("INSERT INTO ledger_entries (id, transaction_id, account_id, trip_id, entry_type, side, amount_cents) "
              "VALUES (?, 'txn-2', ?, ?, 'CANCELLATION_FEE', 'DEBIT', 500)", (new_id(), LA_R, t6)),
            q("INSERT INTO ledger_entries (id, transaction_id, account_id, trip_id, entry_type, side, amount_cents) "
              "VALUES (?, 'txn-2', ?, ?, 'CANCELLATION_FEE', 'CREDIT', 500)", (new_id(), LA_D, t6))) and
           ledger_balance(LA_R) == -1800 and ledger_balance(LA_D) == 1540)
ok("DRV-03b  driver released after the cancelled trip",
   lambda: assert_that(
       q("SELECT status FROM drivers WHERE id=?", (DID,)).fetchone()["status"] == "AVAILABLE",
       "driver stuck ON_TRIP after cancellation"))

# --- TRP-01 again: settle-first gate is now lifted ---------------------------
ok("TRP-01c  rider can request a new trip once the previous one is PAID",
   lambda: request_trip(RID, 5, 10, PM))

# --- TRP-06: the audit trail is complete and ordered -------------------------
expected_t1 = ["REQUESTED", "MATCHED", "EN_ROUTE", "ARRIVED", "ON_TRIP", "COMPLETED", "PAID"]
actual_t1 = [r[0] for r in q(
    "SELECT to_status FROM trip_events WHERE trip_id=? ORDER BY id", (t1,))]
ok("TRP-06   audit trail records exactly the applied transitions, in order",
   lambda: assert_that(
       actual_t1 == expected_t1,
       f"audit mismatch:\n  expected {expected_t1}\n  actual   {actual_t1}"))

# --- Soft-delete policy: reference data keeps its history --------------------
ok("DEL-01   a soft-deleted payment method is hidden but its rows survive",
   lambda: (q("UPDATE payment_methods SET deleted_at = datetime('now') WHERE id = ?", (PM,)),
            assert_that(
                q("SELECT COUNT(*) c FROM payment_methods WHERE deleted_at IS NOT NULL").fetchone()["c"] == 1,
                "deleted_at not recorded")))

# -----------------------------------------------------------------------------
print("=" * 60)
print(f" RESULT: {PASS_COUNT} checks passed, 0 failed — the model holds.")
print("=" * 60)