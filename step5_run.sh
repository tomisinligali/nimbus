#!/usr/bin/env bash
# =============================================================================
# Nimbus Step 5 — prove the model holds, against a REAL PostgreSQL 14 server.
#
#   1. create a throwaway database (nimbus_step5)   -- dropped if it exists
#   2. apply the migration  (migrations/0001_init_nimbus.sql)
#   3. seed a small dataset (migrations/0002_seed_nimbus.sql)
#   4. run the five action queries  (queries/01..05)
#   5. EXPLAIN the two heaviest queries and ASSERT the expected indexes appear
#   6. attempt three invalid states and ASSERT each is rejected
#
# Depends on: psql, createdb, dropdb from PostgreSQL 14 (Homebrew).
# Run from anywhere:  bash design/ride-hailing/step5_run.sh
# =============================================================================
set -u
cd "$(dirname "$0")" || exit 1

DB="nimbus_step5"
RIDER='10000000-0000-4000-8000-000000000001'   # Renata
TRIP='f0000000-0000-4000-8000-000000000001'    # the settled historical trip
PICKUP_LAT=37.7720
PICKUP_LNG=-122.4080
LOG="step5_run.out"

fail() { echo "  ✗ $*" | tee -a "$LOG"; exit 1; }
ok()   { echo "  ✓ $*" | tee -a "$LOG"; }

echo "==  Nimbus Step-5 proof  (PostgreSQL 14, live)  ==" | tee "$LOG"

# ---- 1. database ------------------------------------------------------------
dropdb --if-exists "$DB" 2>/dev/null || true
createdb "$DB" || fail "createdb"

# ---- 2. + 3. migration + seed -----------------------------------------------
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f migrations/0001_init_nimbus.sql \
    || fail "migration 0001 failed"
ok "migration 0001_init_nimbus.sql applied"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f migrations/0002_seed_nimbus.sql \
    || fail "seed 0002 failed"
ok "seed 0002_seed_nimbus.sql applied"

# ---- 4. the five action queries ----------------------------------------------
echo; echo "==  5 queries that answer ACT-1..ACT-5  ==" | tee -a "$LOG"
run_q() { # $1 = file, $2 = label, rest = -v vars
    local f="$1" label="$2"; shift 2
    echo "--- $label ($f)" | tee -a "$LOG"
    psql -q -d "$DB" "$@" -f "queries/$f" | tee -a "$LOG" || fail "$f"
    ok "$f ran"
}
run_q 01_act1_request.sql  "ACT-1 request: is Renata free, and on what?"  -v rider_id="$RIDER"
run_q 02_act2_dispatch.sql "ACT-2 dispatch: nearest AVAILABLE drivers"    -v pickup_lat="$PICKUP_LAT" -v pickup_lng="$PICKUP_LNG"
run_q 03_act3_complete.sql "ACT-3 complete: trip state + audit timeline"  -v trip_id="$TRIP"
run_q 04_act4_settle.sql   "ACT-4 settle: full money trail of the trip"    -v trip_id="$TRIP"
run_q 05_act5_cancel.sql   "ACT-5 cancel: window + fee for the trip"       -v trip_id="$TRIP"

# ---- 5. query plans on the two heaviest ---------------------------------------
echo; echo "==  EXPLAIN the two heaviest queries — indexes must be used  ==" | tee -a "$LOG"
PLAN=$(psql -q -t -d "$DB" -v trip_id="$TRIP" -v pickup_lat="$PICKUP_LAT" -v pickup_lng="$PICKUP_LNG" \
       -f queries/explain_heaviest.sql 2>&1)
echo "$PLAN" | tee -a "$LOG"

grep -q "idx_drivers_available"  <<<"$PLAN" || fail "ACT-2 plan does not use idx_drivers_available"
ok "ACT-2 dispatch plan uses idx_drivers_available"
grep -q "idx_ledger_entries_trip" <<<"$PLAN" || fail "ACT-4 plan does not use idx_ledger_entries_trip"
ok "ACT-4 settle plan uses idx_ledger_entries_trip"

# ---- 6. three invalid states ---------------------------------------------------
echo; echo "==  three invalid states — the database rejects each  ==" | tee -a "$LOG"
psql -q -d "$DB" -f queries/invalid_states.sql 2>&1 | tee -a "$LOG"

grep -q "uq_trips_one_active_per_rider"     <<<"$(cat "$LOG")" || fail "IND-1 not rejected by unique index"
ok "IND-1  second active trip for one rider rejected (partial unique index)"
grep -q "TRP-02"                            <<<"$(cat "$LOG")" || fail "IND-2 not rejected by trigger"
ok "IND-2  REQUESTED -> ON_TRIP rejected (transition-guard trigger)"
grep -q "trips_cancel_fee_only_when_cancelled" <<<"$(cat "$LOG")" || fail "IND-3 not rejected by CHECK"
ok "IND-3  fee on a non-cancelled trip rejected (CHECK constraint)"

echo; echo "RESULT: Step-5 proof complete — all assertions green." | tee -a "$LOG"
echo "Full output: $LOG"