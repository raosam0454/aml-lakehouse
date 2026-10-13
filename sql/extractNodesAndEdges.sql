-- ===== Context =====
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE AML_WH;
USE DATABASE AML_PROTOTYPE;
USE SCHEMA CURATED;

--Nodes
-- customer node
SELECT customer_id                              AS "customer_id",
       customer_type                            AS "customer_type",
       risk_rating                              AS "risk_rating",
       kyc_status                               AS "kyc_status",
       TO_CHAR(onboard_dt, 'YYYY-MM-DD')        AS "onboard_dt",
       status                                   AS "status"
FROM AML_PROTOTYPE.CURATED.CUSTOMER;

-- account node
SELECT account_id                               AS "account_id",
       customer_id                              AS "customer_id",
       account_type                             AS "account_type",
       branch_code                              AS "branch_code",
       status                                   AS "status"
FROM AML_PROTOTYPE.CURATED.ACCOUNT;

--device node
SELECT device_id                                AS "device_id",
       device_type                              AS "device_type",
       os                                       AS "os"
FROM AML_PROTOTYPE.CURATED.DEVICE;

-- ip node.csv
SELECT ip_id                                    AS "ip_id",
       ip_address                               AS "ip_address",
       country                                  AS "country",
       is_vpn                                   AS "is_vpn"
FROM AML_PROTOTYPE.CURATED.IP_ADDRESS;

-- contact node
SELECT DISTINCT 'phone'   AS "kind", TRIM(phone)   AS "value", 'phone|'   || TRIM(phone)   AS "contact_key"
FROM AML_PROTOTYPE.CURATED.CUSTOMER
WHERE phone IS NOT NULL AND TRIM(phone) <> ''
UNION
SELECT DISTINCT 'email',   TRIM(email),   'email|'   || TRIM(email)
FROM AML_PROTOTYPE.CURATED.CUSTOMER
WHERE email IS NOT NULL AND TRIM(email) <> ''
UNION
SELECT DISTINCT 'address', TRIM(address), 'address|' || TRIM(address)
FROM AML_PROTOTYPE.CURATED.CUSTOMER
WHERE address IS NOT NULL AND TRIM(address) <> '';

--Edges
--OWNS (Customer -OWNS-> Account)
SELECT customer_id                              AS "customer_id",
       account_id                               AS "account_id"
FROM AML_PROTOTYPE.CURATED.ACCOUNT;

-- Sent_to   (Account -SENT_TO-> Account)
SELECT t.transaction_id                                         AS "transaction_id",
       t.account_id                                             AS "src_account_id",
       t.counterparty_account_id                                AS "dst_account_id",
       t.amount                                                 AS "amount",
       TO_CHAR(t.txn_time, 'YYYY-MM-DD"T"HH24:MI:SS')           AS "txn_time",
       t.channel                                                AS "channel",
       s.device_id                                              AS "device_id",
       s.ip_id                                                  AS "ip_id"
FROM AML_PROTOTYPE.CURATED.TRANSACTION t
LEFT JOIN AML_PROTOTYPE.CURATED.SESSION s
       ON t.session_id = s.session_id
WHERE t.txn_type = 'transfer'
  AND t.status   = 'completed'
  AND t.account_id IS NOT NULL
  AND t.counterparty_account_id IS NOT NULL
ORDER BY t.txn_time;

-- Use device  (Account -USED_DEVICE-> Device)
SELECT account_id                                               AS "account_id",
       device_id                                                AS "device_id",
       COUNT(*)                                                 AS "session_count",
       TO_CHAR(MIN(session_time), 'YYYY-MM-DD"T"HH24:MI:SS')    AS "first_seen",
       TO_CHAR(MAX(session_time), 'YYYY-MM-DD"T"HH24:MI:SS')    AS "last_seen"
FROM AML_PROTOTYPE.CURATED.SESSION
WHERE device_id IS NOT NULL
GROUP BY account_id, device_id;

-- Use IP  (Account -USED_IP-> IP)
SELECT account_id                                               AS "account_id",
       ip_id                                                    AS "ip_id",
       COUNT(*)                                                 AS "session_count",
       TO_CHAR(MIN(session_time), 'YYYY-MM-DD"T"HH24:MI:SS')    AS "first_seen",
       TO_CHAR(MAX(session_time), 'YYYY-MM-DD"T"HH24:MI:SS')    AS "last_seen"
FROM AML_PROTOTYPE.CURATED.SESSION
WHERE ip_id IS NOT NULL
GROUP BY account_id, ip_id;

-- Has Contact   (Customer -HAS_CONTACT-> Contact)
SELECT customer_id AS "customer_id", 'phone|'   || TRIM(phone)   AS "contact_key"
FROM AML_PROTOTYPE.CURATED.CUSTOMER
WHERE phone IS NOT NULL AND TRIM(phone) <> ''
UNION ALL
SELECT customer_id,                  'email|'   || TRIM(email)
FROM AML_PROTOTYPE.CURATED.CUSTOMER
WHERE email IS NOT NULL AND TRIM(email) <> ''
UNION ALL
SELECT customer_id,                  'address|' || TRIM(address)
FROM AML_PROTOTYPE.CURATED.CUSTOMER
WHERE address IS NOT NULL AND TRIM(address) <> '';




