-- =====================================================================
--  alerts.sql  -  AML prototype, SERVING zone (Gold)
--
--  Implements:  "Alert generation" + "Serving views" boxes of the solution
--               architecture. Reads the detector tables built by
--               detection.sql and writes one alert per finding into
--               CURATED.FRAUD_ALERT. trigger_detail (VARIANT) carries the
--               evidence: path, transactions, tier, why it was flagged.
--
--  Re-runnable: FRAUD_ALERT is truncated first.
--  Run AFTER detection.sql. Never reads EVALUATION.GROUND_TRUTH.
--
--  fraud_score by tier: high = 90, medium = 60
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE AML_WH;
USE DATABASE AML_PROTOTYPE;

TRUNCATE TABLE CURATED.FRAUD_ALERT;

INSERT INTO CURATED.FRAUD_ALERT
       (alert_id, account_id, transaction_id, alert_type, fraud_score,
        trigger_detail, status, raised_at)
SELECT 'ALT-' || LPAD(ROW_NUMBER() OVER (ORDER BY alert_type, account_id, transaction_id)::VARCHAR, 6, '0'),
       account_id,
       transaction_id,
       alert_type,
       fraud_score,
       trigger_detail,
       'open',
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM (
    -- round-trips: origin account, first transaction of the ring
    SELECT origin                               AS account_id,
           txn_ids[0]::VARCHAR                  AS transaction_id,
           'round_trip'                         AS alert_type,
           IFF(tier = 'high', 90, 60)           AS fraud_score,
           OBJECT_CONSTRUCT(
               'tier',         tier,
               'closed_by',    closed_by,
               'closed_on',    closed_on,
               'hops',         hops,
               'path',         path,
               'txn_ids',      txn_ids,
               'first_amount', first_amount,
               'last_amount',  last_amount,
               'decay_pct',    decay_pct,
               'shared_via',   shared_via)      AS trigger_detail
    FROM   SERVING.DET_ROUND_TRIP

    UNION ALL

    -- layering chains: first account of the chain
    SELECT origin,
           txn_ids[0]::VARCHAR,
           'layering_chain',
           60,
           OBJECT_CONSTRUCT(
               'tier',         tier,
               'hops',         hops,
               'path',         path,
               'txn_ids',      txn_ids,
               'first_amount', first_amount,
               'last_amount',  last_amount,
               'decay_pct',    decay_pct)
    FROM   SERVING.DET_LAYERING

    UNION ALL

    -- mule rings: one alert per ring (network-level, no single transaction)
    SELECT accounts[0]::VARCHAR,
           NULL,
           'mule_network',
           60,
           OBJECT_CONSTRUCT(
               'tier',         tier,
               'device_id',    device_id,
               'n_customers',  n_customers,
               'accounts',     accounts)
    FROM   SERVING.DET_MULE
);


-- ---------------------------------------------------------------------
-- Serving views for the dashboards
-- ---------------------------------------------------------------------

-- Dashboard 1: money rings (one row per ring)
CREATE OR REPLACE VIEW SERVING.V_DASH_RINGS AS
SELECT alert_id,
       trigger_detail:tier::VARCHAR          AS tier,
       trigger_detail:closed_by::VARCHAR     AS closed_by,
       trigger_detail:hops::INT              AS hops,
       ARRAY_TO_STRING(trigger_detail:path, ' -> ') AS path,
       trigger_detail:first_amount::NUMBER(18,2)    AS first_amount,
       trigger_detail:last_amount::NUMBER(18,2)     AS last_amount,
       trigger_detail:decay_pct::NUMBER(5,1)        AS decay_pct
FROM   CURATED.FRAUD_ALERT
WHERE  alert_type IN ('round_trip', 'layering_chain');

-- Dashboard 2: identity clusters (mule rings)
CREATE OR REPLACE VIEW SERVING.V_DASH_MULE AS
SELECT alert_id,
       trigger_detail:device_id::VARCHAR     AS device_id,
       trigger_detail:n_customers::INT       AS n_customers,
       ARRAY_TO_STRING(trigger_detail:accounts, ', ') AS accounts
FROM   CURATED.FRAUD_ALERT
WHERE  alert_type = 'mule_network';

-- Dashboard 3: alert queue by type and tier
CREATE OR REPLACE VIEW SERVING.V_DASH_ALERT_SUMMARY AS
SELECT alert_type,
       trigger_detail:tier::VARCHAR AS tier,
       COUNT(*)                     AS alerts
FROM   CURATED.FRAUD_ALERT
GROUP BY 1, 2;

SELECT * FROM SERVING.V_DASH_ALERT_SUMMARY ORDER BY alert_type, tier;
