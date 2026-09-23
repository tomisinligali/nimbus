# Nimbus — Requirements (Step 1)

## 1. Product Summary

**Nimbus** is an on-demand ride-hailing marketplace connecting **riders** with
nearby professional **drivers** for immediate point-to-point rides. One
platform serves both sides from a single ride lifecycle: a rider requests a
ride with a pre-computed, transparent quote; a driver accepts the match; both
parties advance the trip through pickup, ride, and dropoff; the rider's
instrument is charged exactly the metered fare at completion; and the money
splits into driver earnings and platform commission on a double-entry ledger.
A well-defined cancellation policy covers the window before pickup.

**The product is not** a delivery/logistics service, a carpool/peer-to-peer
platform, a scheduled-bookings platform, or a ride-booking broker — **marketplace
only, on-demand only, v1.**

> **What the product does, in one sentence:** it guarantees that every rider
> who asks for a ride gets safely matched to (at most) one driver, is charged
> exactly what they were shown earlier, and pays exactly once — and every
> driver, rider, and the platform can reconcile every cent afterwards.

## 2. Who Uses It

**Primary persona — Rider ("Renata")**: commuter in a metro area who needs a
car now. Has a payment instrument on file, expects a predictable price, and
will cancel if the driver is slow. Needs zero onboarding friction for a repeat
ride.

**Primary persona — Driver ("Dara")**: professional/registered driver who
goes online when working, accepts nearby trips, and needs to see exactly what
she earned per trip and can prove it.

No other personas in v1. There is no dispatcher or CSR actor; the system acts
as dispatcher.

## 3. The Five Most Important User Actions

| ID | Action | Who | Behaviour expected | Key traceability target |
|---|---|---|---|---|
| **ACT-1** | Request a ride | Rider | Pickup/dropoff → instant priced quote, ride enters `REQUESTED`; a rider with an unsettled prior ride may not request. | TRP-01, RDR-01/02, FEE-01/02/03 |
| **ACT-2** | Accept / match a ride | Driver | Driver accepts a `REQUESTED` ride → `MATCHED`. Exactly one driver ever owns a trip; only available drivers can accept. | DRV-01/02/03/04, TRP-02/03 |
| **ACT-3** | Drive the ride to completion | Driver | Trip advances `EN_ROUTE → ARRIVED → ON_TRIP → COMPLETED`; the metered fare is produced from actual distance/time at dropoff. | TRP-02/03/04, TRP-06, FEE-04 |
| **ACT-4** | Pay & settle | System | Exactly one payment per trip, amount = metered fare; ledger posts balances for rider / driver / platform; trip reaches `PAID` and the rider is free to ride again. | PAY-01/02/03/04, FEE-07/08, TRP-01, IDP-01 |
| **ACT-5** | Cancel a trip | Rider or driver | Allowed only before the ride starts; no charge before the driver arrives, flat $5.00 fee once arrived; settled to the driver on the ledger; terminal and irreversible. | TRP-02/05, FEE-05/06/07 |

## 4. Traceability Contract

1. **Every design decision in this project must trace back to a row above.**
   A rule (e.g. `TRP-02`) that cannot be mapped to `ACT-1…ACT-5` is out of
   scope for v1.
2. **Every action above must be fully enforceable by the data model and API**
   (§15 of `API_DESIGN.md` proves this for Step 1's decisions).
3. Terms in all-caps above (`REQUESTED`, `MATCHED`, `EN_ROUTE`, `ARRIVED`,
   `ON_TRIP`, `COMPLETED`, `PAID`) are the exact trip states in the design;
   later documents may not add or rename a state without changing this page.

## 5. What Success Looks Like (v1 signal)

- A rider completes request → accept → complete → pay in one uninterrupted,
  retryable flow; every attempt is idempotent.
- No double-booking: at any instant, each rider and each driver has at most
  one active trip.
- Reconciliation: `Σ rider debits = Σ driver+platform credits` at all times.
- P95 lifecycle latency (request → paid) < 2 minutes when driver ETA ≤ 5 min.