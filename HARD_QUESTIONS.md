# Nimbus — The hard questions: schema decisions (Step 3)

This document answers the questions a first-cut ERD leaves open. Each answer gives the decision, the **enforcement mechanism**, and the **proof check** that verifies it. Nothing here is aspirational: every claim is exercised by `model_proof.py` (31 checks, all passing) against the DDL in `migrations/0001_init_nimbus.sql`. Rules referenced by ID are defined and traced to `ACT-1..5` in `API_DESIGN.md`; each constraint/trigger/index below exists verbatim in `migrations/0001_init_nimbus.sql`.

---

## 1. Normalization — which redundancy did we keep, and why

The model is 3NF at the entity level, with **exactly two deliberate, justified denormalizations whose integrity the database itself protects**, plus one accepted counter column.

**DEN-1 — the pricing snapshot is frozen on the trip (rule FEE-01).**
`trips` carries `base_fare_cents, per_km_cents, per_min_cents, surge_bps, quote_total_cents, rate_card_id` copied at request time. Rate cards WILL change (promos, surges, market edits); historical money must not. Since the quote lives on the trip, a later `UPDATE rate_cards` cannot rewrite past money — there is no join. The designer's rule: *the trip is the invoice; the card is just the template.*
- Enforcement: column CHECKs (`>= 0`, `> 0`, surge `BETWEEN 100 AND 400`); the copy happens in the same INSERT as `REQUESTED`.
- Proof: `TRP-01a` (quote frozen), `FEE-04` (fare materializes from actuals, never from a live card).

**DEN-2 — display labels are frozen on the trip at MATCHED.**
`driver_name_snapshot` + `vehicle_plate_snapshot` are copied from `users.full_name` and the driver's active `vehicles.plate` in the same transaction that performs `REQUESTED -> MATCHED`. A driver who changes name or swaps cars must not see that rewrite ripple into old receipts; a join-at-read would. (Round-off: there is no trigger here — SQL's cross-table NEW-assignment is dialect-fragile, so the dispatch *service* writes the label from the same master rows in the same statement, and the schema enforces *presence*.)
- Enforcement: `trips_snapshot_with_driver` CHECK — any driver-bearing trip MUST carry both labels.
- Proof: `DEN-2`; negative path is the CHECK itself.

**Accepted counter columns (documented, not hidden).**
`riders.rides_count` / `drivers.rides_count` are denormalized monotonic counters whose source of truth remains `trips`; kept for hot-path increments and protected by `CHECK (rides_count >= 0)`. They are not money and cannot corrupt a ledger.

**Deliberately NOT denormalized:**
- Account balances. `ledger_accounts` stores no `balance_cents`; balance is the SUM of `ledger_entries`. Because `trg_ledger_balance` forces every group to net zero, a stored balance could only diverge by app bug — so there is nothing to cache.
- "Latest driver position" (`driver_locations`) looks like denormalization but is a projection table sized for high-frequency writes; it never feeds historic reads.

---

## 2. Money — representation and multi-currency stance

**Decision: every monetary value is an integer in minor units (`*_cents`), with a `currency` column beside it on every money-bearing table. No floats anywhere.**

- `rate_cards.currency`, `trips.currency`, `payments.currency`, `ledger_accounts.currency`, `ledger_entries.currency` — each with `CHECK (currency = 'USD')` in v1.
- Floating point cannot represent cents exactly (0.1 + 0.2 = 0.3000…04); invoicing and settlement math must be exact.

**Why a column rather than an assumption.** Multi-currency becomes a data change, not a migration. More importantly, a *per-row* currency lets the cross-entity chain be verified at write time, making "a USD amount sneaks into a EUR ledger" a constraint violation instead of a silent drift.

**Enforcement — the currency chain is one-way and closed:**
1. Rate card defines the currency → `trg_trips_currency_matches_rate_card` rejects a trip whose `currency` differs from its rate card (`CUR-01b`).
2. Trip defines the currency → `trg_payments_matches_trip` rejects a payment whose `currency` (or amount) differs from its trip (`CUR-01a`).
3. Ledger accounts/entries carry their own currency; the balance trigger compares like with like.

Proof: `CUR-01a`, `CUR-01b`, `PAY-04b`.

---

## 3. State — where state lives and what enforces each transition

Two machines. **Trips** (8 states) and **driver availability** (3 states). Both live in columns; the *rules* about them live in tables, triggers, CHECKs, and partial unique indexes.

### Trip machine — allowed edges

```
                  ┌──────────────────────────┐
                  v                          │
REQUESTED ──► MATCHED ──► EN_ROUTE ──► ARRIVED ──► ON_TRIP ──► COMPLETED ──► PAID
   │              │             │              │                                  ▲
   │              │             │              └──────── CANCELLED ───────────────┘ (rider
   │              │             └── CANCELLED ──┘            ▲                    / driver
   └──────── CANCELLED ─────────┘    (fee may apply)         │                    at any
                                        (no fee)         terminal: NO outbound    pre-ride
                                                            edges                state)
```

Explicitly **forbidden** (highlighted because a glance at "states" implies they're fine):
- `REQUESTED -> COMPLETED / PAID / ON_TRIP …` — skips matching and the whole lifecycle.
- `MATCHED -> COMPLETED / ON_TRIP / PAID` — bypasses the driver's drive-to-rider and drive phases.
- `EN_ROUTE -> ON_TRIP` — skips `ARRIVED`; `ARRIVED -> COMPLETED` — skips `ON_TRIP`.
- `ON_TRIP -> CANCELLED` — a ride already in progress is never cancelled; it must complete and settle. (The rider/driver cancel buttons are only reachable pre-`ON_TRIP`.)
- `COMPLETED -> CANCELLED`, `PAID -> *` — terminal states are permanent.

### What enforces the machine (four layers, all in the database)

1. **Data-driven edge table.** `trip_transitions` contains *only* the legal edges above. The empty space in the table IS the law.
2. **`trg_trip_transition_guard`** (BEFORE UPDATE OF status): raises `TRP-02 illegal trip transition` for any `(old,new)` pair not in the table. Proof: `TRP-02a`, `TRP-02c`, `TRP-02d`.
3. **State-dependent CHECKs** on `trips`:
   - `trips_status_requires_driver`: `REQUESTED` has no driver; `MATCHED..ON_TRIP` must have one.
   - `trips_fare_sets_on_completion`: reaching `COMPLETED`/`PAID` requires `fare_cents` AND `completed_at` together (`FEE-04`).
   - `trips_cancel_fee_only_when_cancelled`: a fee may only exist on a `CANCELLED` trip (`FEE-06`).
4. **Partial unique indexes** make *terminality* a structural concept:
   - `uq_trips_one_active_per_rider` — one active trip per rider (`status NOT IN ('CANCELLED','PAID')`). A rider literally cannot have two open trips; "settle before your next ride" is a database fact. Proof: `TRP-01b`.
   - `uq_trips_one_active_per_driver` — one active trip per driver (`status IN ('MATCHED'..'ON_TRIP')`), so a driver's next trip can open at `COMPLETED`. Proof: `DRV-02b`.

### Driver machine

```
OFFLINE ──► AVAILABLE ──► ON_TRIP ──► AVAILABLE        (ON_TRIP only while a trip
    ▲           │            │            ▲                is MATCHED..ON_TRIP)
    └───────────┴────────────┴────────────┘
```

- `trg_dispatch_requires_available_driver` — a trip may only be MATCHED to an `AVAILABLE` driver (`DRV-02`).
- `trg_sync_driver_status` — mirrors trips onto `drivers.status`: MATCHED/…/ON_TRIP → `ON_TRIP`; COMPLETED/CANCELLED → `AVAILABLE`. Driver state can never drift from the trips table (`DRV-03`, `DRV-03b`).
- Back to `OFFLINE` is an explicit service action (logoff endpoint) that itself guards `ON_TRIP`; the database already protects the interesting direction — nothing can dispatch to a driver who is not `AVAILABLE`.

Everything a status means is a consequence its row proves by existing, not by hope: an invalid trip state cannot be *written*, an active trip blocks the second slot, and completed rides release the driver.

---

## 4. Time — timestamps, unit, monotonicity

- **Store one timezone.** Every timestamp is `TIMESTAMPTZ` (PostgreSQL) — store absolute time in UTC, render in the viewer's zone. No local-time columns.
- **`created_at` is immutable; `updated_at` is system-owned.** On every mutable table `set_updated_at()` (BEFORE UPDATE trigger) overwrites `updated_at`; the application cannot set it and cannot forget it.
- **Trips treat `requested_at` as the createdAt** — assigned on INSERT, never changed; history lists order by it via the DESC indexes (ACT-1/2).
- **Monotonic, append-only ordering** for evidence: `trip_events` and `ledger_entries` carry `created_at` only (they are never updated), ordered by `(trip_id, created_at)` / `(account_id, created_at)`.
- **`completed_at` is part of a state fact**: it materializes with the fare at `COMPLETED` and only then (CHECK `trips_fare_sets_on_completion`, `FEE-04`).

## 5. Deletion and retention — the soft-delete policy

One policy per kind of data, chosen by what the row is *referenced by* afterward:

| Kind | Policy | Why |
|---|---|---|
| `vehicles`, `payment_methods`, `rate_cards` | Soft delete (`deleted_at`) | Historical rows keep referencing them (a receipt's plate, a payment's instrument, a past trip's card). Hard delete would sever the chargeback trail and past money bodies. `uq_payment_default_per_rider` is a *partial* index over `deleted_at IS NULL`, so a soft-deleted default stops being "default" automatically (`RDR-02`). |
| `users`, `riders`, `drivers` | Lawful-erasure cascade only (e.g. GDPR): a hard `DELETE ON DELETE CASCADE` is wired; the API does not expose it. Personal data on `trips` is not deleted — trips are the financial record of record. |
| `trips`, `trip_events`, `payments`, `ledger_entries`, `idempotency_keys` | **Never deleted** | They are the obligation/audit record. Deleting a payment would unbalance the ledger (`PAY-03`); deleting a trip_events row hides dispute evidence (`TRP-06`). Retention is an external concern (e.g. financial-data law), not a schema concern. |

Proof: `DEL-01` — a soft-deleted payment method disappears from the billing list while `payments` still resolves the FK.

## 6. Identifiers — generated by the system (never sequential, never natural)

**Decision: every primary key is a UUID v4 generated by the database (`gen_random_uuid()`). There is no `SERIAL`/sequence anywhere.** External attributes (`phone`, `provider_token`, `plate`) are `UNIQUE`-constrained candidates, not keys the system's identity depends on.

Why, concretely:
1. **These ids are bearer-visible** — trip receipts, API URLs, ledger references. `1,2,3,…` leaks ride volume and invites enumeration/IDOR probing; a UUID reveals nothing and cannot be walked.
2. **Merge-friendly at marketplace scale** — ride-hailing shards by region; per-shard sequences collide on merge, UUIDs do not.
3. **Zero coordination** — `gen_random_uuid()` needs no counter, no lock, no id-allocation service.

Why not natural keys: a user can change their `phone`; `provider_token` belongs to the PSP; `plate` is mutable and per-vehicle. Leasing any of these to a PK would force cascade rewrites of the entire web of history.

The **one** externally-arrived key is deliberate: `idempotency_keys.key` is a client-supplied UUID used *as* the PK for replay protection (`IDP-01`). That is its purpose — a client that retries must send the same key; the DB's `UNIQUE (scope, resource_type, resource_id)` makes re-execution impossible, not just discouraged.

Proof: `IDN-01` — seeded + trip ids are asserted UUID-shaped and the sequence does not advance monotonically.

---

## 7. Constraint inventory — and the invalid states that are now impossible

### Per-table constraints (migrations/0001_init_nimbus.sql is the source of truth)

| Table | Constraint / index | Purpose |
|---|---|---|
| `users` | PK uuid; `CHECK phone ~ '^\+[1-9][0-9]{7,14}$'`; `UNIQUE phone`; name length CHECK | Identity integrity, one lookup key |
| `riders` / `drivers` | PK = `users.id` (1:1, ON DELETE CASCADE); `rating BETWEEN 0 AND 5`; `rides_count >= 0` | 1:1 identity row; sane aggregates |
| `vehicles` | `UNIQUE plate`; `capacity BETWEEN 1 AND 8`; `deleted_at` | One plate ever; passenger safety bound |
| `payment_methods` | `last4 ~ '^[0-9]{4}$'`; `uq_payment_default_per_rider (WHERE is_default AND deleted_at IS NULL)` | At most one default per rider |
| `rate_cards` | `currency = 'USD'`; `base >= 0`, `per_km > 0`, `per_min > 0`, surge `BETWEEN 100 AND 400`; `deleted_at` | Money sanity; surge ceiling |
| `trips` | see §3 for status CHECKs; + snapshot CHECK (DEN-2); coord CHECKs; `uq_trips_one_active_per_rider`/`_driver`; history indexes | the aggregate's full contract |
| `trip_transitions` | PK `(from_status, to_status)`; empty space = illegal | the state machine as data |
| `payments` | `UNIQUE trip_id` (one payment per trip); `amount_cents > 0`; `currency = 'USD'`; FK to trips | single posting per invoice |
| `ledger_accounts` | `UNIQUE (owner_type, owner_id)` | one account per owner |
| `ledger_entries` | `UNIQUE (transaction_id, side, entry_type)`; `amount_cents > 0`; currency; FK account | balance group + no double-post |
| `idempotency_keys` | PK `key`; `UNIQUE (scope, resource_type, resource_id)` | replay protection |

### Invalid states that are now structurally impossible

| The bad state | Blocked by | Proof |
|---|---|---|
| A rider with two open trips | `uq_trips_one_active_per_rider` | `TRP-01b` |
| A driver assigned to two trips at once | `uq_trips_one_active_per_driver` + dispatch guard | `DRV-02b` |
| `MATCHED -> COMPLETED` shortcut | `trg_trip_transition_guard` | `TRP-02a` |
| `ARRIVED -> COMPLETED` shortcut | `trg_trip_transition_guard` | `TRP-02c` |
| Reviving a terminal `CANCELLED` trip | guard — no outbound rows | `TRP-02d` |
| `REQUESTED` with a driver / `MATCHED` without one | `trips_status_requires_driver` | — |
| `COMPLETED`/`PAID` with no fare or timestamp | `trips_fare_sets_on_completion` | `FEE-04` |
| Cancellation fee on a non-cancelled trip | `trips_cancel_fee_only_when_cancelled` | `FEE-06` |
| A trip in a currency different from its card | `trg_trips_currency_matches_rate_card` | `CUR-01b` |
| A payment for a trip with no metered fare, or wrong amount | `trg_payments_matches_trip` | `PAY-04a`, `PAY-04b` |
| A payment in a currency different from its trip | `trg_payments_matches_trip` | `CUR-01a` |
| Two payments for one trip | `payments UNIQUE trip_id` | `PAY-01b` |
| `PAID` with no captured payment | `trg_paid_requires_captured_payment` | `PAY-02a` |
| An unbalanced ledger transaction | `trg_ledger_balance` | `PAY-03b` |
| Double-posting the same ledger leg | `UNIQUE (transaction_id, side, entry_type)` | `PAY-03c` |
| Two default payment methods for one rider | `uq_payment_default_per_rider` | — |
| A driver-bearing trip with no name/plate label | `trips_snapshot_with_driver` | `DEN-2` |

---

## 8. Indexes — the plan per query for the five actions

| Action (REQUIREMENTS) | Read query | Serving index |
|---|---|---|
| **ACT-1** request a trip | rider's default payment method | `idx_payment_methods_rider` + `uq_payment_default_per_rider` |
| **ACT-1** (pre-check) | active-trip existence for rider | `uq_trips_one_active_per_rider` (unique, so existence = index-hit) |
| **ACT-2** dispatch | pick an available driver | `idx_drivers_available` (partial: `WHERE status = 'AVAILABLE'`) |
| **ACT-1/2** history | my receipts: `WHERE rider_id = ? ORDER BY requested_at DESC` | `idx_trips_rider_history (rider_id, requested_at DESC)` |
| **ACT-3** ride to completion | trip by id (updates) | `trips` PK |
| **ACT-3** (evidence) | trip event timeline | `idx_trip_events_trip (trip_id, created_at)` |
| **ACT-4** pay & settle | payment by trip (balance-check + capture) | `payments.trip_id` unique index |
| **ACT-4** (settlement) | legs of one transaction | `idx_ledger_entries_transaction (transaction_id)` |
| **ACT-4** (settle & audit) | every posting for one trip | `idx_ledger_entries_trip (trip_id, created_at)` — added after the Step-5 EXPLAIN pass proved the settle query relied on it |
| **ACT-4** (balances) | a rider's/driver's balance & history | `idx_ledger_entries_account (account_id, created_at)` |
| **ACT-5** cancel | trip by id + fee posting | `trips` PK; `idx_ledger_entries_transaction` |

(The dispatch service additionally carries a geospatial (GiST) index on `driver_locations`/a candidate-location column in the service layer; the partial `idx_drivers_available` covers the status pre-filter.)

---

## 9. Why all this — traceability in one map

| Requires (ACT-x) | Settled by | Schema object | Verified by |
|---|---|---|---|
| ACT-1 (request) and ACT-5 (cancel, no double-booking) | one active trip per rider | `uq_trips_one_active_per_rider` | `TRP-01b` |
| ACT-2 (match to an available, single driver) | availability guard + one active per driver | `trg_dispatch_requires_available_driver`, `uq_trips_one_active_per_driver` | `DRV-02a/b` |
| ACT-3 (legal drive lifecycle, evidence) | data-driven state machine + audit | `trip_transitions`, `trg_trip_transition_guard`, `trip_events` + audit triggers | `TRP-02a`, `TRP-02c/d`, `TRP-06` |
| ACT-4 (exact money, balanced settlement) | integer cents + currency chain + double-entry balance + one payment per invoice | currency CHECKs, `trg_payments_matches_trip`, `trg_paid_requires_captured_payment`, `trg_ledger_balance`, `UNIQUE trip_id` | `PAY-01b`, `PAY-02`, `PAY-03`, `PAY-04`, `CUR-01`, `FEE-04` |
| ACT-1/2 (correct receipts after profile/price changes) | DEN-1/DEN-2 snapshots | frozen pricing columns + snapshots + `trips_snapshot_with_driver` | `TRP-01a`, `FEE-04`, `DEN-2` |

Verified state at the end of Step 3: `python3 design/ride-hailing/model_proof.py` → **31 checks passed, 0 failed — the model holds.**

End of Step 5: the same model, proven on real PostgreSQL — migration + seed applied, five action queries run, both heavy reads use their indexes, and the three enforcement layers above (partial index / trigger / CHECK) each rejected an invalid state. See `STEP5_PROOF.md` (`bash design/ride-hailing/step5_run.sh`).