# Nimbus — Step 5: Proof the model holds (against real PostgreSQL 14)

> Step 5 answers the question _"the model is beautiful in a diagram, but does it
> **work**?"_ — by making a database, loading the schema, seeding it, answering
> the five actions with five queries, proving the two heavy reads use their
> indexes, and watching the database throw out three invalid states.

**Environment this was proven against: PostgreSQL 14.23 (Homebrew), running
locally on socket `/tmp:5432`. Nothing else was touched — no services, no app
code. Reproduce everything with one command:**

```sh
bash design/ride-hailing/step5_run.sh
```

The script is **asserting**: it exits non-zero if any migration, query, index
use, or rejection is missing. Its full captured output lives next to this doc in
`step5_run.out`.

---

## 1. What the step proves

| # | Claim | Mechanism |
|---|-------|-----------|
| 1 | The schema applies cleanly to a fresh database | `migrations/0001_init_nimbus.sql` |
| 2 | A realistic, **balanced** dataset can be loaded | `migrations/0002_seed_nimbus.sql` |
| 3 | All five actions (`ACT-1…ACT-5`) are answerable by SQL | `queries/01…05_*.sql` |
| 4 | The two heaviest reads use the planned indexes | `EXPLAIN` with `enable_seqscan = off` |
| 5 | Three different enforcement layers reject invalid states | partial unique index, trigger, CHECK |

This file's layout (migrations + queries + runner) is the shape of the deploy
story: `0001` is the schema, `0002` is seed data, the query files are the five
reads, and `step5_run.sh` is the (re)producer.

---

## 2. The two changes the step forced on the schema

The proof was not decorative — it changed the schema in two places:

1. **`schema.sql` → `migrations/0001_init_nimbus.sql`** — the DDL is now a
   migration (transaction-wrapped `BEGIN;…COMMIT;`, `CREATE EXTENSION IF NOT
   EXISTS pgcrypto;`).
2. **`idx_ledger_entries_trip (trip_id, created_at)` added** — writing the
   ACT-4 settle query (all postings for *one* trip) showed no index covered a
   `ledger_entries` lookup filtered only by `trip_id`; with material trip
   volume that is a seq scan per settlement. The index map in
   `HARD_QUESTIONS.md:191` now lists it, with its origin noted.

---

## 3. The five action queries (real output, truncated to what matters)

### ACT-1 request — is Renata free, and on what?  —`queries/01_act1_request.sql`

```
      default_payment_method_id       | default_kind | last4 | open_trips
--------------------------------------+--------------+-------+------------
 c1000000-0000-4000-8000-000000000001 | CARD         | 4242  |          0
```

`open_trips = 0` via `uq_trips_one_active_per_rider` (uniqueness = existence).
Her default `CARD •••• 4242` is the instrument `RDR-01` requires.

### ACT-2 dispatch — nearest AVAILABLE drivers —`queries/02_act2_dispatch.sql`

```
 30000000-...01 | Marco Driver | 9XYZ456 | Tesla Model 3 | 37.7803 | -122.412
 20000000-...01 | Dara Driver  | 7ABC123 | Toyota Prius  | 37.7749 | -122.4194
```

Only `AVAILABLE` drivers (partial index pre-filter); ranked by distance to the
pickup `(37.772, -122.408)`, Marco is nearest.

### ACT-3 completion — state + audit trail —`queries/03_act3_complete.sql`

```
                        id                         | status | ... fare_cents | completed_at
 f0000000-0000-4000-8000-000000000001              | PAID   | ...       1300 | 2026-09-22 ...

 from_status | to_status | actor  | payload
             | PAID      | SYSTEM | {}
```

The trip row plus its one SYSTEM audit event — the append-only evidence trail
(`idx_trip_events_trip`) a dispute can cite.

### ACT-4 settle — the whole money trail —`queries/04_act4_settle.sql`

```
            transaction_id            | owner_type | side  | entry_type | amount_cents | currency
 90000000-...01 | RIDER    | DEBIT  | FARE       |         1300 | USD
 90000000-...01 | PLATFORM | CREDIT | FARE       |         1300 | USD
 90000000-...02 | PLATFORM | DEBIT  | FARE       |         1040 | USD
 90000000-...02 | DRIVER   | CREDIT | FARE       |         1040 | USD
 90000000-...03 | PLATFORM | DEBIT  | COMMISSION |          260 | USD
 90000000-...03 | PLATFORM | CREDIT | COMMISSION |          260 | USD

 payments | captured
----------
        1 |        1
```

Three double-entry pairs (settle / payout / commission), **each nets to zero**,
+ the `PAY-01/04` guarantees: **one** payment, **captured**, amount = fare
(1300 = 1040 + 260). This is `ADR-2`'s platform-clearing-account ledger,
visibly balanced.

### ACT-5 cancel — window + fee —`queries/05_act5_cancel.sql`

```
 id                 | status | cancellation_fee_cents | cancel_window | fee_if_cancelled_cents
 f0000000-...01 | PAID   |                      0 | closed        |                      0
```

A settled trip is terminal: `cancel_window = closed`, no fee. The same query on
an `ARRIVED` trip returns `open` / 500 — the `FEE-05/06` window.

---

## 4. The two heaviest reads — index plans

The seed is deliberately tiny, so PostgreSQL's planner is *right* to seq-scan
the few rows. To prove the indexes **can** serve each query, the plan is taken
inside `SET LOCAL enable_seqscan = off` (see `queries/explain_heaviest.sql` for
the caveat made explicit). The planner then shows what it would do at depth:

**ACT-2 dispatch** → drives on the partial index:

```
->  Bitmap Heap Scan on drivers d          Recheck Cond: (status = 'AVAILABLE'...)
      ->  Bitmap Index Scan on idx_drivers_available
->  Index Scan using users_pkey on users u          Index Cond: (id = d.id)
->  Bitmap Index Scan on idx_vehicles_driver        Index Cond: (driver_id = d.id)
->  Index Scan using driver_locations_pkey on dl    Index Cond: (driver_id = d.id)
```

**ACT-4 settle** → drives on the new trip index:

```
->  Bitmap Heap Scan on ledger_entries e            Recheck Cond: (trip_id = ...::uuid)
      ->  Bitmap Index Scan on idx_ledger_entries_trip   Index Cond: (trip_id = ...::uuid)
->  Index Scan using ledger_accounts_pkey on a      Index Cond: (id = e.account_id)
```

Both needed index names appear in the plans; the runner asserts them.
(`idx_drivers_available` = `DRV-02`'s enforcement, `idx_ledger_entries_trip` =
the Step-5 addition.)

---

## 5. Three invalid states — the database says no

Each rejection names **exactly one** mechanism (the demos are ordered so no
other constraint could fire):

**IND-1 · partial unique index** — a second active trip for Renata
(`queries/invalid_states.sql:47`):

```
ERROR:  duplicate key value violates unique constraint "uq_trips_one_active_per_rider"
DETAIL:  Key (rider_id)=(10000000-0000-4000-8000-000000000001) already exists.
```

**IND-2 · transition-guard trigger** — `REQUESTED → ON_TRIP` skips matching
(`queries/invalid_states.sql:56`):

```
ERROR:  TRP-02 illegal trip transition: REQUESTED -> ON_TRIP
CONTEXT:  PL/pgSQL function trip_transition_guard() line 8 at RAISE
```

**IND-3 · CHECK constraint** — a $5 fee on a trip that is not CANCELLED
(`queries/invalid_states.sql:72`):

```
ERROR:  new row for relation "trips" violates check constraint "trips_cancel_fee_only_when_cancelled"
```

These are the same three layers `model_proof.py` exercises on the SQLite
mirror — now demonstrated on real PostgreSQL: **index, trigger, CHECK**.

---

## 6. Relationship to the rest of the proof

- `model_proof.py` (SQLite mirror, **31/31 green**) proves the *semantic*
  invariants; this document proves the *same model runs on the real engine*.
- All rule IDs above (`TRP-01/02`, `PAY-01/04`, `FEE-05/06`, `DRV-02`, `RDR-01`,
  `ADR-2`) are defined, traced to `ACT-1..5`, in `API_DESIGN.md`; constraints
  exist verbatim in `migrations/0001_init_nimbus.sql`.
- **Reproduce:** `bash design/ride-hailing/step5_run.sh` → asserts, then
  `RESULT: Step-5 proof complete — all assertions green.`

*Step 5 done. DDL: `migrations/0001_init_nimbus.sql` · Seed: `migrations/0002_seed_nimbus.sql` · Queries: `queries/` · Runner + live transcript: `step5_run.sh` / `step5_run.out`.*