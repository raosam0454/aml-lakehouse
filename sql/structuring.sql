-- =====================================================================
--  structuring.sql : cash deposits held under the AUD 10,000 TTR
--  threshold and spread across branches and days, so no single deposit
--  is reportable. Window aggregation, not a graph traversal.
--
--  Builds SERVING.DET_STRUCTURING, one row per flagged account.
--  Run before alerts.sql. Never reads EVALUATION.GROUND_TRUTH.
--
--  Thresholds (assumptions):
--    amount under 10,000      the TTR threshold itself
--    10-day rolling window    wide enough to hold a whole run
--    >= 5 deposits            below this, ordinary banking
--    >= 2 distinct branches   the discriminator: a trader banking daily
--                             takings uses one branch, someone avoiding
--                             a reporting threshold spreads the visits
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE AML_WH;
USE DATABASE AML_PROTOTYPE;
USE SCHEMA SERVING;


CREATE OR REPLACE TABLE DET_STRUCTURING AS
WITH deposits AS (
    -- cash in, under the threshold. A cash deposit has no originating
    -- account, so the subject is the receiving account.
    SELECT t.transaction_id,
           t.counterparty_account_id AS account_id,
           t.txn_time,
           t.amount,
           t.branch_code
    FROM   CURATED.TRANSACTION t
    WHERE  t.txn_type = 'cash_deposit'
      AND  t.status   = 'completed'
      AND  t.amount   < 10000
      AND  t.counterparty_account_id IS NOT NULL
      AND  t.branch_code IS NOT NULL
),
-- every 10-day window ending on a deposit, with the deposits inside it.
-- Self-join rather than a RANGE window, so behaviour does not depend on
-- interval-window support.
windowed AS (
    SELECT a.transaction_id                  AS anchor_id,
           a.account_id,
           COUNT(*)                          AS n_deposits,
           COUNT(DISTINCT b.branch_code)     AS n_branches,
           SUM(b.amount)                     AS total_amount,
           MAX(b.amount)                     AS max_single,
           MIN(b.txn_time)::DATE             AS first_day,
           MAX(b.txn_time)::DATE             AS last_day,
           ARRAY_AGG(DISTINCT b.branch_code) AS branches,
           ARRAY_AGG(b.transaction_id) WITHIN GROUP (ORDER BY b.txn_time) AS txn_ids
    FROM   deposits a
    JOIN   deposits b
           ON  b.account_id = a.account_id
           AND b.txn_time  <= a.txn_time
           AND b.txn_time   > DATEADD(day, -10, a.txn_time)
    GROUP  BY a.transaction_id, a.account_id
    HAVING COUNT(*) >= 5
       AND COUNT(DISTINCT b.branch_code) >= 2
)
-- one alert per account: keep the densest window, so overlapping windows
-- over the same run of deposits do not each raise an alert
SELECT account_id,
       n_deposits,
       n_branches,
       total_amount,
       max_single,
       first_day,
       last_day,
       DATEDIFF(day, first_day, last_day) + 1 AS n_days,
       branches,
       txn_ids,
       -- a run spanning three or more branches is harder to explain as
       -- ordinary banking than one spanning two
       IFF(n_branches >= 3, 'high', 'medium') AS tier
FROM   windowed
QUALIFY ROW_NUMBER() OVER (PARTITION BY account_id
                           ORDER BY n_deposits DESC, total_amount DESC) = 1;


-- ---------------------------------------------------------------------
-- Check. Generator seed 42 / small (50,012 transactions) injects 9
-- structuring chains, 6 to 15 deposits each, across 2 to 4 branches.
-- ---------------------------------------------------------------------
SELECT tier,
       COUNT(*)                 AS accounts,
       SUM(n_deposits)          AS deposits,
       ROUND(AVG(n_days), 1)    AS avg_days,
       ROUND(AVG(total_amount)) AS avg_total
FROM   DET_STRUCTURING
GROUP  BY tier
ORDER  BY tier;
