-- =====================================================================
--  dashboards.sql : queries behind the dashboard charts
--  (built in streamlit/streamlit_app.py). Run alerts.sql first.
-- =====================================================================

-- ============ DASHBOARD 1: Money rings & layering (P1) ===============

-- 1a rings and chains by tier
SELECT alert_type, tier, alerts
FROM   AML_PROTOTYPE.SERVING.V_DASH_ALERT_SUMMARY
WHERE  alert_type IN ('round_trip', 'layering_chain')
ORDER BY alert_type, tier;

-- 1b all rings with their path
SELECT alert_id, tier, closed_by, hops, path, first_amount, last_amount, decay_pct
FROM   AML_PROTOTYPE.SERVING.V_DASH_RINGS
ORDER BY tier, hops DESC;

-- 1c ring length
SELECT hops, COUNT(*) AS n
FROM   AML_PROTOTYPE.SERVING.V_DASH_RINGS
GROUP BY hops ORDER BY hops;


-- ============ DASHBOARD 2: Shared identity & mule rings (P2) =========

-- 2a identity links by type
SELECT via, COUNT(*) / 2 AS pairs
FROM   AML_PROTOTYPE.SERVING.ACC_LINK
GROUP BY via ORDER BY pairs DESC;

-- 2b mule rings
SELECT alert_id, device_id, n_customers, accounts
FROM   AML_PROTOTYPE.SERVING.V_DASH_MULE
ORDER BY n_customers DESC;

-- 2c mule ring size
SELECT n_customers, COUNT(*) AS rings
FROM   AML_PROTOTYPE.SERVING.V_DASH_MULE
GROUP BY n_customers ORDER BY n_customers;


-- ============ DASHBOARD 3: Alert queue & detection quality ===========

-- 3a open alerts
SELECT COUNT(*) AS open_alerts
FROM   AML_PROTOTYPE.CURATED.FRAUD_ALERT
WHERE  status = 'open';

-- 3b alerts by type and tier
SELECT alert_type, tier, alerts
FROM   AML_PROTOTYPE.SERVING.V_DASH_ALERT_SUMMARY
ORDER BY alert_type, tier;

-- 3c alert queue
SELECT alert_id, alert_type, fraud_score, account_id,
       trigger_detail:tier::VARCHAR      AS tier,
       trigger_detail:closed_by::VARCHAR AS closed_by,
       raised_at
FROM   AML_PROTOTYPE.CURATED.FRAUD_ALERT
ORDER BY fraud_score DESC, alert_id;

-- 3d benchmark
SELECT pattern_label, chains, found_full, found_partial, missed, tiers, false_positives
FROM   AML_PROTOTYPE.EVALUATION.V_BENCHMARK
ORDER BY pattern_label;
