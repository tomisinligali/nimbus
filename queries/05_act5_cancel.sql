-- =============================================================================
-- ACT-5  Cancel a trip  —  "is this trip cancellable, and what does it cost?"
--
-- Read the trip's state to decide the cancellation window (FEE-05/06):
-- only REQUESTED/MATCHED/EN_ROUTE/ARRIVED are cancellable; a fee applies only
-- once the driver has arrived (ARRIVED -> $5.00). Terminal states answer
-- "closed" and can never be revived.
-- Served by: trips PK
-- Run: psql -d nimbus_step5 -f queries/05_act5_cancel.sql  (trip T1 = settled)
-- =============================================================================
SELECT id,
       status,
       driver_id,
       cancellation_fee_cents,
       CASE WHEN status IN ('MATCHED', 'EN_ROUTE', 'ARRIVED') THEN 'open'
            WHEN status = 'REQUESTED'                     THEN 'unclaimed'
            ELSE 'closed'                                        END AS cancel_window,
       CASE WHEN status = 'ARRIVED' THEN 500
            ELSE 0                                           END AS fee_if_cancelled_cents
  FROM trips
 WHERE id = :'trip_id';