-- =====================================================================
--  detection.sql : CURATED -> SERVING detectors
--  Layering, round-trips (P1 money flow + P2 shared identity), mule rings,
--  structuring. Run before alerts.sql.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE AML_WH;
USE DATABASE AML_PROTOTYPE;
USE SCHEMA SERVING;


-- 1. Money edges: one per completed transfer, excluding own-account transfers
CREATE OR REPLACE TABLE P1_EDGE AS
SELECT t.transaction_id,
       t.account_id              AS src,
       t.counterparty_account_id AS dst,
       t.amount,
       t.txn_time
FROM   CURATED.TRANSACTION t
JOIN   CURATED.ACCOUNT s ON s.account_id = t.account_id
JOIN   CURATED.ACCOUNT d ON d.account_id = t.counterparty_account_id
WHERE  t.txn_type = 'transfer'
  AND  t.status   = 'completed'
  AND  s.customer_id <> d.customer_id;


-- 2. Identity links (P2): accounts of different customers sharing phone, email or device
CREATE OR REPLACE TABLE ACC_LINK AS
SELECT DISTINCT a1.account_id AS a, a2.account_id AS b, 'phone' AS via
FROM   CURATED.ACCOUNT  a1
JOIN   CURATED.CUSTOMER c1 ON c1.customer_id = a1.customer_id
JOIN   CURATED.CUSTOMER c2 ON c2.phone = c1.phone AND c2.customer_id <> c1.customer_id
JOIN   CURATED.ACCOUNT  a2 ON a2.customer_id = c2.customer_id
UNION
SELECT DISTINCT a1.account_id, a2.account_id, 'email'
FROM   CURATED.ACCOUNT  a1
JOIN   CURATED.CUSTOMER c1 ON c1.customer_id = a1.customer_id
JOIN   CURATED.CUSTOMER c2 ON c2.email = c1.email AND c2.customer_id <> c1.customer_id
JOIN   CURATED.ACCOUNT  a2 ON a2.customer_id = c2.customer_id
UNION
SELECT DISTINCT s1.account_id, s2.account_id, 'device'
FROM   CURATED.SESSION s1
JOIN   CURATED.SESSION s2 ON s2.device_id = s1.device_id AND s2.account_id <> s1.account_id
JOIN   CURATED.ACCOUNT x  ON x.account_id = s1.account_id
JOIN   CURATED.ACCOUNT y  ON y.account_id = s2.account_id
WHERE  x.customer_id <> y.customer_id;


-- 3. Money paths (P1): next hop within 48h, 80-100% of previous amount, max 8 hops
CREATE OR REPLACE TABLE P1_WALK AS
WITH RECURSIVE walk (origin, cur, last_time, last_amount, first_amount, hops, path, txn_ids) AS (
    SELECT e.src::VARCHAR,
           e.dst::VARCHAR,
           e.txn_time::TIMESTAMP_NTZ,
           e.amount::NUMBER(18,2),
           e.amount::NUMBER(18,2),
           1::INT,
           ARRAY_CONSTRUCT(e.src, e.dst),
           ARRAY_CONSTRUCT(e.transaction_id)
    FROM   P1_EDGE e

    UNION ALL

    SELECT w.origin,
           e.dst::VARCHAR,
           e.txn_time::TIMESTAMP_NTZ,
           e.amount::NUMBER(18,2),
           w.first_amount,
           (w.hops + 1)::INT,
           ARRAY_APPEND(w.path, e.dst),
           ARRAY_APPEND(w.txn_ids, e.transaction_id)
    FROM   walk w
    JOIN   P1_EDGE e ON e.src = w.cur
    WHERE  w.cur <> w.origin
      AND  e.txn_time >  w.last_time
      AND  e.txn_time <= DATEADD(hour, 48, w.last_time)
      AND  e.amount BETWEEN w.last_amount * 0.80 AND w.last_amount
      AND  (e.dst = w.origin OR NOT ARRAY_CONTAINS(e.dst::VARIANT, w.path))
      AND  w.hops < 8
)
SELECT walk.*,
       ARRAY_TO_STRING(txn_ids, ',') AS path_key
FROM   walk;


-- 4. Round-trips: path returns to the origin or to an account linked to it.
--    high = closed through a link or members share an identity, medium = cycle only
CREATE OR REPLACE TABLE DET_ROUND_TRIP AS
WITH candidate AS (
    SELECT w.*,
           IFF(w.cur = w.origin, 'same_account', 'linked_' || l.via) AS closed_by
    FROM   P1_WALK w
    LEFT JOIN ACC_LINK l ON l.a = w.origin AND l.b = w.cur
    WHERE  w.hops >= 3
      AND  (w.cur = w.origin OR l.a IS NOT NULL)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY w.path_key ORDER BY closed_by) = 1
),
-- keep maximal rings only
maximal AS (
    SELECT c.*
    FROM   candidate c
    LEFT JOIN candidate b
           ON ARRAY_SIZE(b.txn_ids) > ARRAY_SIZE(c.txn_ids)
          AND ARRAY_SIZE(ARRAY_INTERSECTION(b.txn_ids, c.txn_ids)) = ARRAY_SIZE(c.txn_ids)
    WHERE  b.path_key IS NULL
),
-- linked member pairs inside each ring
shared AS (
    SELECT m.path_key,
           COUNT(l.a)                                AS shared_pairs,
           ARRAY_AGG(DISTINCT l.via)                 AS shared_via
    FROM   maximal m
    LEFT JOIN ACC_LINK l
           ON ARRAY_CONTAINS(l.a::VARIANT, m.path)
          AND ARRAY_CONTAINS(l.b::VARIANT, m.path)
    GROUP BY m.path_key
)
SELECT m.path_key,
       m.origin,
       m.cur                                         AS closed_on,
       m.closed_by,
       m.hops,
       m.path,
       m.txn_ids,
       m.first_amount,
       m.last_amount,
       ROUND(100 * (1 - m.last_amount / m.first_amount), 1) AS decay_pct,
       s.shared_pairs,
       s.shared_via,
       IFF(m.closed_by <> 'same_account' OR s.shared_pairs > 0, 'high', 'medium') AS tier
FROM   maximal m
JOIN   shared s ON s.path_key = m.path_key;


-- 5. Layering: open paths of 4+ hops, maximal only, not part of a round-trip
CREATE OR REPLACE TABLE DET_LAYERING AS
WITH long_paths AS (
    SELECT * FROM P1_WALK WHERE hops >= 4
),
maximal AS (
    SELECT w.*
    FROM   long_paths w
    LEFT JOIN long_paths b
           ON b.hops > w.hops
          AND ARRAY_SIZE(ARRAY_INTERSECTION(b.txn_ids, w.txn_ids)) = ARRAY_SIZE(w.txn_ids)
    WHERE  w.cur <> w.origin
      AND  b.path_key IS NULL
)
SELECT m.path_key, m.origin, m.cur AS ends_on, m.hops, m.path, m.txn_ids,
       m.first_amount, m.last_amount,
       ROUND(100 * (1 - m.last_amount / m.first_amount), 1) AS decay_pct,
       'medium' AS tier
FROM   maximal m
LEFT JOIN DET_ROUND_TRIP r
       ON ARRAYS_OVERLAP(r.txn_ids, m.txn_ids)
WHERE  r.path_key IS NULL;


-- 6. Mule rings: 3+ customers on one device, recently opened accounts that pass
--    money through (>= 90% out within 24h)
CREATE OR REPLACE TABLE PASS_THROUGH AS
SELECT DISTINCT i.counterparty_account_id AS account_id
FROM   CURATED.TRANSACTION i
JOIN   CURATED.TRANSACTION o
       ON  o.account_id = i.counterparty_account_id
      AND  o.txn_time >  i.txn_time
      AND  o.txn_time <= DATEADD(hour, 24, i.txn_time)
      AND  o.amount BETWEEN 0.90 * i.amount AND i.amount
WHERE  i.status = 'completed'
  AND  o.status = 'completed'
  AND  i.amount >= 1000;

CREATE OR REPLACE TABLE DET_MULE AS
WITH members AS (
    SELECT DISTINCT s.device_id, a.account_id, a.customer_id
    FROM   CURATED.SESSION s
    JOIN   CURATED.ACCOUNT a   ON a.account_id = s.account_id
    JOIN   PASS_THROUGH    p   ON p.account_id = a.account_id
    WHERE  a.open_date >= DATEADD(day, -150,
               (SELECT MIN(txn_time)::DATE FROM CURATED.TRANSACTION))
)
SELECT device_id,
       COUNT(DISTINCT customer_id)      AS n_customers,
       ARRAY_AGG(DISTINCT account_id)   AS accounts,
       'medium'                         AS tier
FROM   members
GROUP BY device_id
HAVING COUNT(DISTINCT customer_id) >= 3;


-- 7. Structuring: 2+ cash deposits under 10,000 on the same day totalling 10,000+
--    (logic by Duy Bao Cao)
CREATE OR REPLACE TABLE DET_STRUCTURING AS
WITH deposits AS (
    SELECT transaction_id,
           counterparty_account_id AS account_id,
           txn_time::DATE          AS day,
           amount,
           branch_code
    FROM   CURATED.TRANSACTION
    WHERE  txn_type = 'cash_deposit'
      AND  status   = 'completed'
      AND  amount BETWEEN 7000 AND 9999.99
),
flagged_days AS (
    SELECT account_id, day
    FROM   deposits
    GROUP BY account_id, day
    HAVING COUNT(*) >= 2 AND SUM(amount) >= 10000
)
SELECT d.account_id,
       COUNT(DISTINCT d.day)            AS n_days,
       COUNT(*)                         AS n_deposits,
       SUM(d.amount)                    AS total_amount,
       COUNT(DISTINCT d.branch_code)    AS n_branches,
       MIN(d.day)                       AS first_day,
       MAX(d.day)                       AS last_day,
       ARRAY_AGG(d.transaction_id)      AS txn_ids,
       'medium'                         AS tier
FROM   deposits d
JOIN   flagged_days f ON f.account_id = d.account_id AND f.day = d.day
GROUP BY d.account_id;


-- 8. Detections per detector and tier
SELECT 'round_trip' AS detector, tier, COUNT(*) AS n FROM DET_ROUND_TRIP  GROUP BY tier
UNION ALL
SELECT 'layering',    tier, COUNT(*) FROM DET_LAYERING    GROUP BY tier
UNION ALL
SELECT 'mule',        tier, COUNT(*) FROM DET_MULE        GROUP BY tier
UNION ALL
SELECT 'structuring', tier, COUNT(*) FROM DET_STRUCTURING GROUP BY tier
ORDER BY detector, tier;
