-- =====================================================================
--  benchmark.sql : detections vs EVALUATION.GROUND_TRUTH (the only script
--  that reads it). A chain counts as found only if one detection covers it.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE AML_WH;
USE DATABASE AML_PROTOTYPE;

CREATE OR REPLACE VIEW EVALUATION.V_BENCHMARK AS
WITH
-- transactions inside each detection
rt_txn AS (
    SELECT r.path_key, r.tier, f.value::VARCHAR AS transaction_id
    FROM   SERVING.DET_ROUND_TRIP r, LATERAL FLATTEN(input => r.txn_ids) f),
ly_txn AS (
    SELECT l.path_key, l.tier, f.value::VARCHAR AS transaction_id
    FROM   SERVING.DET_LAYERING l, LATERAL FLATTEN(input => l.txn_ids) f),
-- injected mule members
mule_gt AS (
    SELECT DISTINCT g.chain_id, t.counterparty_account_id AS account_id
    FROM   EVALUATION.GROUND_TRUTH g
    JOIN   CURATED.TRANSACTION t ON t.transaction_id = g.transaction_id
    WHERE  g.pattern_label = 'mule_network' AND g.hop_index = 0),
mule_found AS (
    SELECT m.device_id, f.value::VARCHAR AS account_id
    FROM   SERVING.DET_MULE m, LATERAL FLATTEN(input => m.accounts) f),
-- injected structuring accounts
structuring_gt AS (
    SELECT DISTINCT g.chain_id, t.counterparty_account_id AS account_id
    FROM   EVALUATION.GROUND_TRUTH g
    JOIN   CURATED.TRANSACTION t ON t.transaction_id = g.transaction_id
    WHERE  g.pattern_label = 'structuring'),
-- all ring / layering detections with their transactions
det_txn AS (
    SELECT 'R:' || path_key AS det_id, tier, transaction_id FROM rt_txn
    UNION ALL
    SELECT 'L:' || path_key, tier, transaction_id FROM ly_txn),
gt_chain AS (
    SELECT pattern_label, chain_id, transaction_id
    FROM   EVALUATION.GROUND_TRUTH
    WHERE  pattern_label LIKE 'round_trip%' OR pattern_label = 'layering_chain'),
-- best coverage of each injected chain by a single detection
chain_det AS (
    SELECT g.chain_id, d.det_id, d.tier, COUNT(*) AS hit_txn
    FROM   gt_chain g JOIN det_txn d ON d.transaction_id = g.transaction_id
    GROUP BY 1, 2, 3),
best AS (
    SELECT chain_id, hit_txn, tier
    FROM   chain_det
    QUALIFY ROW_NUMBER() OVER (PARTITION BY chain_id ORDER BY hit_txn DESC, tier) = 1),
-- recall per injected chain
chains AS (
    SELECT g.pattern_label, g.chain_id,
           COUNT(*)                                  AS n_txn,
           COALESCE(MAX(b.hit_txn), 0)               AS hit_txn,
           MAX(b.tier)                               AS tier
    FROM   gt_chain g
    LEFT JOIN best b ON b.chain_id = g.chain_id
    GROUP BY 1, 2
    UNION ALL
    SELECT 'mule_network', mg.chain_id, COUNT(*), COUNT(mf.account_id), NULL
    FROM   mule_gt mg
    LEFT JOIN mule_found mf ON mf.account_id = mg.account_id
    GROUP BY 2
    UNION ALL
    -- structuring: found if the target account is flagged
    SELECT 'structuring', sg.chain_id, 1, IFF(MAX(ds.account_id) IS NOT NULL, 1, 0), NULL
    FROM   structuring_gt sg
    LEFT JOIN SERVING.DET_STRUCTURING ds ON ds.account_id = sg.account_id
    GROUP BY 2
),
recall AS (
    SELECT pattern_label,
           COUNT(*)                                  AS chains,
           SUM(IFF(hit_txn = n_txn, 1, 0))           AS found_full,
           SUM(IFF(hit_txn > 0 AND hit_txn < n_txn, 1, 0)) AS found_partial,
           SUM(IFF(hit_txn = 0, 1, 0))               AS missed,
           LISTAGG(DISTINCT tier, ',')               AS tiers
    FROM   chains
    GROUP BY 1
),
-- false positives per detector
injected AS (
    SELECT transaction_id FROM EVALUATION.GROUND_TRUTH WHERE pattern_label <> 'normal'),
fp AS (
    SELECT 'round_trip (detector)' AS pattern_label, COUNT(*) AS false_positives
    FROM  (SELECT rt.path_key, COUNT(i.transaction_id) AS inj
           FROM rt_txn rt LEFT JOIN injected i ON i.transaction_id = rt.transaction_id
           GROUP BY rt.path_key) WHERE inj = 0
    UNION ALL
    SELECT 'layering (detector)', COUNT(*)
    FROM  (SELECT ly.path_key, COUNT(i.transaction_id) AS inj
           FROM ly_txn ly LEFT JOIN injected i ON i.transaction_id = ly.transaction_id
           GROUP BY ly.path_key) WHERE inj = 0
    UNION ALL
    SELECT 'mule (detector)', COUNT(*)
    FROM  (SELECT mf.device_id, COUNT(mg.account_id) AS inj
           FROM mule_found mf LEFT JOIN mule_gt mg ON mg.account_id = mf.account_id
           GROUP BY mf.device_id) WHERE inj = 0
    UNION ALL
    SELECT 'structuring (detector)', COUNT(*)
    FROM   SERVING.DET_STRUCTURING ds
    LEFT JOIN structuring_gt sg ON sg.account_id = ds.account_id
    WHERE  sg.account_id IS NULL
)
SELECT pattern_label, chains, found_full, found_partial, missed, tiers, NULL AS false_positives FROM recall
UNION ALL
SELECT pattern_label, NULL, NULL, NULL, NULL, NULL, false_positives FROM fp;

SELECT * FROM EVALUATION.V_BENCHMARK ORDER BY pattern_label;
