-- =====================================================================
--  AML Monitoring Prototype
--  Load JSONL files from stage into RAW, then transform RAW into CURATED.
--
--  Run aml_schema.sql first.
--  Upload the .jsonl files to @AML_PROTOTYPE.RAW.AML_STAGE before running
--  section 1 (Catalog > Explorer > AML_PROTOTYPE > RAW > Stages > AML_STAGE,
--  then the + Files button).
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE AML_WH;
USE DATABASE AML_PROTOTYPE;
 
-- ---------------------------------------------------------------------
-- 0. Confirm the files arrived
-- --------------------------------------------------------------------- 
LIST @RAW.AML_STAGE;
-- Expect 7 entries: customers, accounts, devices, ip_addresses,
-- sessions, transactions, ground_truth.
 
-- RELOADING AFTER REGENERATING THE DATA
-- Clear the stage first, then upload the new files. A stale file left
-- beside a new one of a different name is loaded too, and the row counts
-- then silently disagree with the generator.
--   REMOVE @RAW.AML_STAGE;
--
-- Every COPY below sets FORCE = TRUE. Snowflake keeps load metadata per
-- file and skips anything it believes it has already loaded, which after
-- a TRUNCATE would leave the table empty with no error raised. FORCE is
-- safe here because each target is truncated immediately beforehand.
 
-- =====================================================================
--  ITEM 3: stage into RAW
--  Each JSONL line becomes one VARIANT row. No parsing, no typing yet.
--  METADATA$FILENAME records the source file, which is the lineage trail.
-- =====================================================================
 
USE SCHEMA RAW;
 
TRUNCATE TABLE CUSTOMER_RAW;
COPY INTO CUSTOMER_RAW (payload, src_file)
    FROM (SELECT $1, METADATA$FILENAME FROM @AML_STAGE/customers.jsonl)
    FILE_FORMAT = (FORMAT_NAME = JSONL_FORMAT)
    FORCE = TRUE
    ON_ERROR = ABORT_STATEMENT;
 
TRUNCATE TABLE ACCOUNT_RAW;
COPY INTO ACCOUNT_RAW (payload, src_file)
    FROM (SELECT $1, METADATA$FILENAME FROM @AML_STAGE/accounts.jsonl)
    FILE_FORMAT = (FORMAT_NAME = JSONL_FORMAT)
    FORCE = TRUE
    ON_ERROR = ABORT_STATEMENT;
 
TRUNCATE TABLE DEVICE_RAW;
COPY INTO DEVICE_RAW (payload, src_file)
    FROM (SELECT $1, METADATA$FILENAME FROM @AML_STAGE/devices.jsonl)
    FILE_FORMAT = (FORMAT_NAME = JSONL_FORMAT)
    FORCE = TRUE
    ON_ERROR = ABORT_STATEMENT;
 
TRUNCATE TABLE IP_ADDRESS_RAW;
COPY INTO IP_ADDRESS_RAW (payload, src_file)
    FROM (SELECT $1, METADATA$FILENAME FROM @AML_STAGE/ip_addresses.jsonl)
    FILE_FORMAT = (FORMAT_NAME = JSONL_FORMAT)
    FORCE = TRUE
    ON_ERROR = ABORT_STATEMENT;
 
TRUNCATE TABLE SESSION_RAW;
COPY INTO SESSION_RAW (payload, src_file)
    FROM (SELECT $1, METADATA$FILENAME FROM @AML_STAGE/sessions.jsonl)
    FILE_FORMAT = (FORMAT_NAME = JSONL_FORMAT)
    FORCE = TRUE
    ON_ERROR = ABORT_STATEMENT;
 
TRUNCATE TABLE TRANSACTION_RAW;
COPY INTO TRANSACTION_RAW (payload, src_file)
    FROM (SELECT $1, METADATA$FILENAME FROM @AML_STAGE/transactions.jsonl)
    FILE_FORMAT = (FORMAT_NAME = JSONL_FORMAT)
    FORCE = TRUE
    ON_ERROR = ABORT_STATEMENT;
 
-- Row counts must match the generator output.
SELECT 'CUSTOMER_RAW' AS tbl, COUNT(*) AS n FROM CUSTOMER_RAW
UNION ALL SELECT 'ACCOUNT_RAW',     COUNT(*) FROM ACCOUNT_RAW
UNION ALL SELECT 'DEVICE_RAW',      COUNT(*) FROM DEVICE_RAW
UNION ALL SELECT 'IP_ADDRESS_RAW',  COUNT(*) FROM IP_ADDRESS_RAW
UNION ALL SELECT 'SESSION_RAW',     COUNT(*) FROM SESSION_RAW
UNION ALL SELECT 'TRANSACTION_RAW', COUNT(*) FROM TRANSACTION_RAW
ORDER BY 1;
 
-- What a VARIANT row actually holds.
SELECT payload FROM CUSTOMER_RAW LIMIT 1;
 
 
-- =====================================================================
--  ITEM 4: RAW to CURATED
--  payload:field reads a VARIANT field, ::TYPE casts it.
--  Load order follows the foreign keys.
--  kyc_payload stays VARIANT: carrying it as a document is the point.
-- =====================================================================
 
USE SCHEMA CURATED;
 
-- Child tables first so truncation does not fight the key order.
TRUNCATE TABLE FRAUD_ALERT;
TRUNCATE TABLE TRANSACTION;
TRUNCATE TABLE SESSION;
TRUNCATE TABLE ACCOUNT;
TRUNCATE TABLE CUSTOMER;
TRUNCATE TABLE DEVICE;
TRUNCATE TABLE IP_ADDRESS;
 
-- 4.1 CUSTOMER
INSERT INTO CUSTOMER
SELECT
    payload:customer_id            ::VARCHAR(20),
    payload:customer_type          ::VARCHAR(10),
    payload:full_name              ::VARCHAR(100),
    payload:date_of_birth          ::DATE,
    payload:nationality            ::VARCHAR(50),
    payload:email                  ::VARCHAR(100),
    payload:phone                  ::VARCHAR(20),
    payload:address                ::VARCHAR(200),
    payload:occupation_or_industry ::VARCHAR(100),
    payload:declared_income_aud    ::DECIMAL(18,2),
    payload:kyc_status             ::VARCHAR(20),
    payload:kyc_payload,
    payload:risk_rating            ::VARCHAR(20),
    payload:onboard_dt             ::DATE,
    payload:status                 ::VARCHAR(20),
    payload:created_at             ::TIMESTAMP_NTZ
FROM RAW.CUSTOMER_RAW;
 
-- 4.2 ACCOUNT
INSERT INTO ACCOUNT
SELECT
    payload:account_id     ::VARCHAR(20),
    payload:customer_id    ::VARCHAR(20),
    payload:account_number ::VARCHAR(20),
    payload:account_type   ::VARCHAR(20),
    payload:currency       ::VARCHAR(3),
    payload:balance        ::DECIMAL(18,2),
    payload:status         ::VARCHAR(20),
    payload:open_date      ::DATE,
    payload:branch_code    ::VARCHAR(10)
FROM RAW.ACCOUNT_RAW;
 
-- 4.3 DEVICE
INSERT INTO DEVICE
SELECT
    payload:device_id          ::VARCHAR(20),
    payload:device_fingerprint ::VARCHAR(64),
    payload:device_type        ::VARCHAR(20),
    payload:os                 ::VARCHAR(30),
    payload:first_seen         ::TIMESTAMP_NTZ,
    payload:last_seen          ::TIMESTAMP_NTZ
FROM RAW.DEVICE_RAW;
 
-- 4.4 IP_ADDRESS
INSERT INTO IP_ADDRESS
SELECT
    payload:ip_id      ::VARCHAR(20),
    payload:ip_address ::VARCHAR(45),
    payload:country    ::VARCHAR(50),
    payload:city       ::VARCHAR(50),
    payload:is_vpn     ::BOOLEAN,
    payload:risk_score ::DECIMAL(5,2)
FROM RAW.IP_ADDRESS_RAW;
 
-- 4.5 SESSION
INSERT INTO SESSION
SELECT
    payload:session_id   ::VARCHAR(20),
    payload:account_id   ::VARCHAR(20),
    payload:device_id    ::VARCHAR(20),
    payload:ip_id        ::VARCHAR(20),
    payload:session_time ::TIMESTAMP_NTZ,
    payload:channel      ::VARCHAR(20),
    payload:auth_method  ::VARCHAR(20)
FROM RAW.SESSION_RAW;
 
-- 4.6 TRANSACTION
INSERT INTO TRANSACTION
SELECT
    payload:transaction_id          ::VARCHAR(20),
    payload:account_id              ::VARCHAR(20),
    payload:counterparty_account_id ::VARCHAR(20),
    payload:session_id              ::VARCHAR(20),
    payload:txn_time                ::TIMESTAMP_NTZ,
    payload:amount                  ::DECIMAL(18,2),
    payload:currency                ::VARCHAR(3),
    payload:txn_type                ::VARCHAR(20),
    payload:channel                 ::VARCHAR(20),
    payload:branch_code             ::VARCHAR(10),
    payload:description             ::VARCHAR(200),
    payload:status                  ::VARCHAR(20)
FROM RAW.TRANSACTION_RAW;
 
 
-- ---------------------------------------------------------------------
--  Ground truth, loaded straight into EVALUATION.
--  It never passes through a CURATED table, so a label cannot reach a
--  detection query by accident.
-- ---------------------------------------------------------------------
 
USE SCHEMA EVALUATION;
 
CREATE OR REPLACE TEMPORARY TABLE GT_RAW (payload VARIANT);
COPY INTO GT_RAW
    FROM @RAW.AML_STAGE/ground_truth.jsonl
    FILE_FORMAT = (FORMAT_NAME = RAW.JSONL_FORMAT)
    FORCE = TRUE
    ON_ERROR = ABORT_STATEMENT;
 
TRUNCATE TABLE GROUND_TRUTH;
INSERT INTO GROUND_TRUTH
SELECT
    payload:transaction_id ::VARCHAR(20),
    payload:pattern_label  ::VARCHAR(30),
    payload:chain_id       ::VARCHAR(20),
    payload:hop_index      ::INT
FROM GT_RAW;
 
 
-- ---------------------------------------------------------------------
--  Verification. All of these must pass before moving on.
-- ---------------------------------------------------------------------
 
USE SCHEMA CURATED;
 
-- 1. Row counts against the generator output
SELECT 'CUSTOMER' AS tbl, COUNT(*) AS n FROM CUSTOMER
UNION ALL SELECT 'ACCOUNT',     COUNT(*) FROM ACCOUNT
UNION ALL SELECT 'DEVICE',      COUNT(*) FROM DEVICE
UNION ALL SELECT 'IP_ADDRESS',  COUNT(*) FROM IP_ADDRESS
UNION ALL SELECT 'SESSION',     COUNT(*) FROM SESSION
UNION ALL SELECT 'TRANSACTION', COUNT(*) FROM TRANSACTION
UNION ALL SELECT 'GROUND_TRUTH',COUNT(*) FROM EVALUATION.GROUND_TRUTH
ORDER BY 1;
 
-- 2. Orphan check. Snowflake does not enforce foreign keys.
--    Every count must be 0.
SELECT
    (SELECT COUNT(*) FROM ACCOUNT a
       LEFT JOIN CUSTOMER c ON a.customer_id = c.customer_id
      WHERE c.customer_id IS NULL)                         AS orphan_accounts,
    (SELECT COUNT(*) FROM SESSION s
       LEFT JOIN ACCOUNT a ON s.account_id = a.account_id
      WHERE a.account_id IS NULL)                          AS orphan_sessions,
    (SELECT COUNT(*) FROM TRANSACTION t
       LEFT JOIN ACCOUNT a ON t.account_id = a.account_id
      WHERE t.account_id IS NOT NULL AND a.account_id IS NULL)   AS orphan_txn_src,
    (SELECT COUNT(*) FROM TRANSACTION t
       LEFT JOIN ACCOUNT a ON t.counterparty_account_id = a.account_id
      WHERE t.counterparty_account_id IS NOT NULL
        AND a.account_id IS NULL)                          AS orphan_txn_dst;
 
-- 3. Nulls landed as nulls, not as the string "null".
--    Expect cash deposits with a null originator and no 'null' strings.
SELECT txn_type,
       COUNT(*)                                        AS txn_count,
       COUNT(account_id)                               AS has_src,
       COUNT(counterparty_account_id)                  AS has_dst,
       COUNT(branch_code)                              AS has_branch
FROM TRANSACTION
GROUP BY txn_type
ORDER BY 1;
 
-- 4. The VARIANT survived the load and the two shapes differ.
SELECT customer_type,
       COUNT(*)                              AS customers,
       COUNT(kyc_payload:abn)                AS have_abn,
       COUNT(kyc_payload:identity_documents) AS have_id_docs,
       COUNT(kyc_payload:directors)          AS have_directors
FROM CUSTOMER
GROUP BY customer_type;
 
-- 5. Amounts are DECIMAL and the structuring band is intact.
--    Normal cash deposits should not appear between 7,000 and 10,000.
SELECT
    COUNT(*)                                                        AS cash_deposits,
    SUM(CASE WHEN amount BETWEEN 7000 AND 9999.99 THEN 1 ELSE 0 END) AS in_structuring_band,
    MAX(amount)                                                     AS largest
FROM TRANSACTION
WHERE txn_type = 'cash_deposit';
 
-- 6. The link views resolve against the loaded data.
SELECT COUNT(*) AS shared_device_pairs FROM V_SHARED_DEVICE_LINK;
SELECT COUNT(*) AS shared_ip_pairs     FROM V_SHARED_IP_LINK;
 
 
-- ---------------------------------------------------------------------
--  Suspend when finished.
-- ---------------------------------------------------------------------
 
ALTER WAREHOUSE AML_WH SUSPEND;