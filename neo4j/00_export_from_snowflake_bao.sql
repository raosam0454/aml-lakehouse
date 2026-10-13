-- =====================================================================
--  00_export_from_snowflake_bao.sql  (author: Duy Bao Cao)
--  Implements: CURATED -> CSV export of graph nodes and edges for Neo4j.
--  Run each SELECT in Snowsight and download the result as the CSV named
--  in the comment (nodes_*.csv / edges_*.csv), then load with
--  01_load_snowflake_export.cypher.
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE AML_WH;
USE DATABASE AML_PROTOTYPE;
USE SCHEMA CURATED;

-- nodes_customer.csv
SELECT customer_id AS "customer_id", customer_type AS "customer_type", risk_rating AS "risk_rating",
       kyc_status AS "kyc_status", TO_CHAR(onboard_dt, 'YYYY-MM-DD') AS "onboard_dt", status AS "status"
FROM AML_PROTOTYPE.CURATED.CUSTOMER;

-- nodes_account.csv
SELECT account_id AS "account_id", customer_id AS "customer_id", account_type AS "account_type",
       branch_code AS "branch_code", status AS "status"
FROM AML_PROTOTYPE.CURATED.ACCOUNT;

-- nodes_device.csv
SELECT device_id AS "device_id", device_type AS "device_type", os AS "os"
FROM AML_PROTOTYPE.CURATED.DEVICE;

-- nodes_ip.csv
SELECT ip_id AS "ip_id", ip_address AS "ip_address", country AS "country", is_vpn AS "is_vpn"
FROM AML_PROTOTYPE.CURATED.IP_ADDRESS;

-- nodes_contact.csv  (one node per distinct phone / email / address; key = kind|value)
SELECT DISTINCT 'phone' AS "kind", TRIM(phone) AS "value", 'phone|' || TRIM(phone) AS "contact_key"
FROM AML_PROTOTYPE.CURATED.CUSTOMER WHERE phone IS NOT NULL AND TRIM(phone) <> ''
UNION
SELECT DISTINCT 'email', TRIM(email), 'email|' || TRIM(email)
FROM AML_PROTOTYPE.CURATED.CUSTOMER WHERE email IS NOT NULL AND TRIM(email) <> ''
UNION
SELECT DISTINCT 'address', TRIM(address), 'address|' || TRIM(address)
FROM AML_PROTOTYPE.CURATED.CUSTOMER WHERE address IS NOT NULL AND TRIM(address) <> '';

-- edges_owns.csv  (Customer -OWNS-> Account)
SELECT customer_id AS "customer_id", account_id AS "account_id"
FROM AML_PROTOTYPE.CURATED.ACCOUNT;

-- edges_sent_to.csv  (Account -SENT_TO-> Account, one edge per completed transfer)
SELECT t.transaction_id AS "transaction_id", t.account_id AS "src_account_id",
       t.counterparty_account_id AS "dst_account_id", t.amount AS "amount",
       TO_CHAR(t.txn_time, 'YYYY-MM-DD"T"HH24:MI:SS') AS "txn_time", t.channel AS "channel",
       s.device_id AS "device_id", s.ip_id AS "ip_id"
FROM AML_PROTOTYPE.CURATED.TRANSACTION t
LEFT JOIN AML_PROTOTYPE.CURATED.SESSION s ON t.session_id = s.session_id
WHERE t.txn_type = 'transfer' AND t.status = 'completed'
  AND t.account_id IS NOT NULL AND t.counterparty_account_id IS NOT NULL
ORDER BY t.txn_time;

-- edges_used_device.csv  (Account -USED_DEVICE-> Device)
SELECT account_id AS "account_id", device_id AS "device_id", COUNT(*) AS "session_count",
       TO_CHAR(MIN(session_time), 'YYYY-MM-DD"T"HH24:MI:SS') AS "first_seen",
       TO_CHAR(MAX(session_time), 'YYYY-MM-DD"T"HH24:MI:SS') AS "last_seen"
FROM AML_PROTOTYPE.CURATED.SESSION WHERE device_id IS NOT NULL
GROUP BY account_id, device_id;

-- edges_used_ip.csv  (Account -USED_IP-> IP)
SELECT account_id AS "account_id", ip_id AS "ip_id", COUNT(*) AS "session_count",
       TO_CHAR(MIN(session_time), 'YYYY-MM-DD"T"HH24:MI:SS') AS "first_seen",
       TO_CHAR(MAX(session_time), 'YYYY-MM-DD"T"HH24:MI:SS') AS "last_seen"
FROM AML_PROTOTYPE.CURATED.SESSION WHERE ip_id IS NOT NULL
GROUP BY account_id, ip_id;

-- edges_has_contact.csv  (Customer -HAS_CONTACT-> Contact)
SELECT customer_id AS "customer_id", 'phone|' || TRIM(phone) AS "contact_key"
FROM AML_PROTOTYPE.CURATED.CUSTOMER WHERE phone IS NOT NULL AND TRIM(phone) <> ''
UNION ALL
SELECT customer_id, 'email|' || TRIM(email)
FROM AML_PROTOTYPE.CURATED.CUSTOMER WHERE email IS NOT NULL AND TRIM(email) <> ''
UNION ALL
SELECT customer_id, 'address|' || TRIM(address)
FROM AML_PROTOTYPE.CURATED.CUSTOMER WHERE address IS NOT NULL AND TRIM(address) <> '';
