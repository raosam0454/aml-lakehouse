-- =====================================================================
--  dashboards.sql  -  the queries behind the 3 dashboards (Snowsight Dashboards
--  are deprecated; the dashboards are built in streamlit/streamlit_app.py)
--  Implements: "Consumption / dashboards" box. Each block = one tile.
--  Reads only SERVING views (and EVALUATION for the benchmark tile).
--  Run alerts.sql first (it creates the V_DASH_* views).
-- =====================================================================

-- ============ DASHBOARD 1: Money rings & layering (P1) ===============

-- 1a  KPI bar: rings and chains by tier          (Chart: bar, x = ALERT_TYPE, y = ALERTS, series = TIER)
SELECT alert_type, tier, alerts
FROM   AML_PROTOTYPE.SERVING.V_DASH_ALERT_SUMMARY
WHERE  alert_type IN ('round_trip', 'layering_chain')
ORDER BY alert_type, tier;

-- 1b  Table: every ring with its path                (Chart: table)
SELECT alert_id, tier, closed_by, hops, path, first_amount, last_amount, decay_pct
FROM   AML_PROTOTYPE.SERVING.V_DASH_RINGS
ORDER BY tier, hops DESC;

-- 1c  Bar: how long are the rings/chains?           (Chart: bar, x = HOPS, y = N)
SELECT hops, COUNT(*) AS n
FROM   AML_PROTOTYPE.SERVING.V_DASH_RINGS
GROUP BY hops ORDER BY hops;


-- ============ DASHBOARD 2: Shared identity & mule rings (P2) =========

-- 2a  Bar: identity links by type (phone / email / device)   (x = VIA, y = PAIRS)
SELECT via, COUNT(*) / 2 AS pairs            -- ACC_LINK stores both directions
FROM   AML_PROTOTYPE.SERVING.ACC_LINK
GROUP BY via ORDER BY pairs DESC;

-- 2b  Table: mule rings                                       (Chart: table)
SELECT alert_id, device_id, n_customers, accounts
FROM   AML_PROTOTYPE.SERVING.V_DASH_MULE
ORDER BY n_customers DESC;

-- 2c  Bar: ring size distribution                             (x = N_CUSTOMERS, y = RINGS)
SELECT n_customers, COUNT(*) AS rings
FROM   AML_PROTOTYPE.SERVING.V_DASH_MULE
GROUP BY n_customers ORDER BY n_customers;


-- ============ DASHBOARD 3: Alert queue & detection quality ===========

-- 3a  Scorecard: total open alerts                            (Chart: scorecard)
SELECT COUNT(*) AS open_alerts
FROM   AML_PROTOTYPE.CURATED.FRAUD_ALERT
WHERE  status = 'open';

-- 3b  Bar: alerts by type and tier                            (x = ALERT_TYPE, y = ALERTS, series = TIER)
SELECT alert_type, tier, alerts
FROM   AML_PROTOTYPE.SERVING.V_DASH_ALERT_SUMMARY
ORDER BY alert_type, tier;

-- 3c  Table: alert queue, highest score first                 (Chart: table)
SELECT alert_id, alert_type, fraud_score, account_id,
       trigger_detail:tier::VARCHAR      AS tier,
       trigger_detail:closed_by::VARCHAR AS closed_by,
       raised_at
FROM   AML_PROTOTYPE.CURATED.FRAUD_ALERT
ORDER BY fraud_score DESC, alert_id;

-- 3d  Table: benchmark vs ground truth (EVALUATION; needs a role that can read it)
SELECT pattern_label, chains, found_full, found_partial, missed, tiers, false_positives
FROM   AML_PROTOTYPE.EVALUATION.V_BENCHMARK
ORDER BY pattern_label;
