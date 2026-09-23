# Nimbus — On-Demand Ride-Hailing (Design & Spec)

A complete, database-proven design for an on-demand ride-hailing marketplace:
request → match → drive → pay → cancel, with a money-exact ledger.

## Status

v1 design, pre-implementation. Proven against a **real PostgreSQL 14 server**
(Step 5) and against a SQLite invariant mirror (31/31 checks green).

## Contents

| Path | What it is |
|---|---|
| `REQUIREMENTS.md` | Product summary, personas, the five actions `ACT-1…ACT-5`, traceability contract |
| `DATA_MODEL.md` | Full entity list, fields, types, identifiers, cardinalities + diagrams |
| `HARD_QUESTIONS.md` | The hard questions answered in writing (money, state, time, deletion, identifiers, constraints, indexes) |
| `API_DESIGN.md` | Complete endpoint contracts, errors, idempotency, over-fetching & real-time analyses |
| `migrations/0001_init_nimbus.sql` | Implemented schema: constraints + indexes |
| `migrations/0002_seed_nimbus.sql` | Small, balanced seed dataset |
| `queries/` | The five action queries + EXPLAIN + invalid-state attempts |
| `STEP5_PROOF.md` | The proof: query plans showing index use, three rejected invalid states |
| `model_proof.py` | SQLite mirror; attempts to violate every rule (31/31 green) |
| `step5_run.sh` | One-command reproduction of the full PostgreSQL proof |

## Evidence (assessment)

1. **The diagram** — `DATA_MODEL.md` §3.1 (mermaid ER diagram), `API_DESIGN.md` §4.
2. **State machine drawing** — `API_DESIGN.md` §6 (`stateDiagram-v2` for trips).
3. **Query plan output showing index use** — `STEP5_PROOF.md` §4 (`idx_drivers_available`, `idx_ledger_entries_trip`).
4. **Three constraint violations rejected** — `STEP5_PROOF.md` §5 + live transcript `step5_run.out`.

## Reproduce

```bash
python3 model_proof.py          # 31/31 checks (SQLite mirror)
bash step5_run.sh               # full proof on PostgreSQL 14 (asserts index plans + rejections)
```