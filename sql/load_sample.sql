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
-- Expect 7 rows: customers, accounts, devices, ip_addresses,
-- sessions, transactions, ground_truth.


-- ---------------------------------------------------------------------
-- 1. Stage into RAW
--    Each JSONL line becomes one VARIANT row. No parsing, no typing yet.
--    METADATA$FILENAME records which file a row came from, which is the
--    lineage story in the governance section.
-- ---------------------------------------------------------------------

USE SCHEMA RAW;

TRUNCATE TABLE CUSTOMER_RAW;
COPY INTO CUSTOMER_RAW (payload, src_file)
    FROM (SELECT $1, METADATA$FILENAME FROM @AML_STAGE/customers.jsonl)
    FILE_FORMAT = (FORMAT_NAME = JSONL_FORMAT);

TRUNCATE TABLE ACCOUNT_RAW;
COPY INTO ACCOUNT_RAW (payload, src_file)
    FROM (SELECT $1, METADATA$FILENAME FROM @AML_STAGE/accounts.jsonl)
    FILE_FORMAT = (FORMAT_NAME = JSONL_FORMAT);

TRUNCATE TABLE DEVICE_RAW;
COPY INTO DEVICE_RAW (payload, src_file)
    FROM (SELECT $1, METADATA$FILENAME FROM @AML_STAGE/devices.jsonl)
    FILE_FORMAT = (FORMAT_NAME = JSONL_FORMAT);

TRUNCATE TABLE IP_ADDRESS_RAW;
COPY INTO IP_ADDRESS_RAW (payload, src_file)
    FROM (SELECT $1, METADATA$FILENAME FROM @AML_STAGE/ip_addresses.jsonl)
    FILE_FORMAT = (FORMAT_NAME = JSONL_FORMAT);

TRUNCATE TABLE SESSION_RAW;
COPY INTO SESSION_RAW (payload, src_file)
    FROM (SELECT $1, METADATA$FILENAME FROM @AML_STAGE/sessions.jsonl)
    FILE_FORMAT = (FORMAT_NAME = JSONL_FORMAT);

TRUNCATE TABLE TRANSACTION_RAW;
COPY INTO TRANSACTION_RAW (payload, src_file)
    FROM (SELECT $1, METADATA$FILENAME FROM @AML_STAGE/transactions.jsonl)
    FILE_FORMAT = (FORMAT_NAME = JSONL_FORMAT);

-- Check what landed.
SELECT 'CUSTOMER_RAW' t, COUNT(*) n FROM CUSTOMER_RAW
UNION ALL SELECT 'ACCOUNT_RAW',     COUNT(*) FROM ACCOUNT_RAW
UNION ALL SELECT 'DEVICE_RAW',      COUNT(*) FROM DEVICE_RAW
UNION ALL SELECT 'IP_ADDRESS_RAW',  COUNT(*) FROM IP_ADDRESS_RAW
UNION ALL SELECT 'SESSION_RAW',     COUNT(*) FROM SESSION_RAW
UNION ALL SELECT 'TRANSACTION_RAW', COUNT(*) FROM TRANSACTION_RAW;

-- Look at one raw row to see what a VARIANT holds.
SELECT payload FROM CUSTOMER_RAW LIMIT 1;


-- ---------------------------------------------------------------------
-- 2. RAW to CURATED
--    payload:field_name reads a VARIANT field. ::TYPE casts it.
--    Load order follows the foreign keys.
--
--    kyc_payload stays VARIANT. It is NOT flattened into columns, because
--    carrying it as a document is the point.
-- ---------------------------------------------------------------------

USE SCHEMA CURATED;

-- 2.1 CUSTOMER
TRUNCATE TABLE CUSTOMER;
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
    payload:kyc_payload,                                -- stays VARIANT
    payload:risk_rating            ::VARCHAR(20),
    payload:onboard_dt             ::DATE,
    payload:status                 ::VARCHAR(20),
    payload:created_at             ::TIMESTAMP_NTZ
FROM RAW.CUSTOMER_RAW;

-- 2.2 ACCOUNT
TRUNCATE TABLE ACCOUNT;
INSERT INTO ACCOUNT
SELECT
    payload:account_id      ::VARCHAR(20),
    payload:customer_id     ::VARCHAR(20),
    payload:account_number  ::VARCHAR(20),
    payload:account_type    ::VARCHAR(20),
    payload:currency        ::VARCHAR(3),
    payload:balance         ::DECIMAL(18,2),
    payload:status          ::VARCHAR(20),
    payload:open_date       ::DATE,
    payload:branch_code     ::VARCHAR(10)
FROM RAW.ACCOUNT_RAW;

-- 2.3 DEVICE
TRUNCATE TABLE DEVICE;
INSERT INTO DEVICE
SELECT
    payload:device_id          ::VARCHAR(20),
    payload:device_fingerprint ::VARCHAR(64),
    payload:device_type        ::VARCHAR(20),
    payload:os                 ::VARCHAR(30),
    payload:first_seen         ::TIMESTAMP_NTZ,
    payload:last_seen          ::TIMESTAMP_NTZ
FROM RAW.DEVICE_RAW;

-- 2.4 IP_ADDRESS
TRUNCATE TABLE IP_ADDRESS;
INSERT INTO IP_ADDRESS
SELECT
    payload:ip_id      ::VARCHAR(20),
    payload:ip_address ::VARCHAR(45),
    payload:country    ::VARCHAR(50),
    payload:city       ::VARCHAR(50),
    payload:is_vpn     ::BOOLEAN,
    payload:risk_score ::DECIMAL(5,2)
FROM RAW.IP_ADDRESS_RAW;

-- 2.5 SESSION
TRUNCATE TABLE SESSION;
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

-- 2.6 TRANSACTION
TRUNCATE TABLE TRANSACTION;
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
-- 3. Ground truth
--    Loaded straight into EVALUATION, never via a CURATED table, so a
--    label cannot reach a detection query by accident.
-- ---------------------------------------------------------------------

USE SCHEMA EVALUATION;

CREATE OR REPLACE TEMPORARY TABLE GT_RAW (payload VARIANT);
COPY INTO GT_RAW
    FROM @RAW.AML_STAGE/ground_truth.jsonl
    FILE_FORMAT = (FORMAT_NAME = RAW.JSONL_FORMAT);

TRUNCATE TABLE GROUND_TRUTH;
INSERT INTO GROUND_TRUTH
SELECT
    payload:transaction_id ::VARCHAR(20),
    payload:pattern_label  ::VARCHAR(30),
    payload:chain_id       ::VARCHAR(20),
    payload:hop_index      ::INT
FROM GT_RAW;


-- ---------------------------------------------------------------------
-- 4. Verify the load
-- ---------------------------------------------------------------------

USE SCHEMA CURATED;

SELECT 'CUSTOMER' t, COUNT(*) n FROM CUSTOMER
UNION ALL SELECT 'ACCOUNT',     COUNT(*) FROM ACCOUNT
UNION ALL SELECT 'DEVICE',      COUNT(*) FROM DEVICE
UNION ALL SELECT 'IP_ADDRESS',  COUNT(*) FROM IP_ADDRESS
UNION ALL SELECT 'SESSION',     COUNT(*) FROM SESSION
UNION ALL SELECT 'TRANSACTION', COUNT(*) FROM TRANSACTION
ORDER BY 1;

-- Orphan check. Snowflake does not enforce foreign keys, so check manually.
SELECT COUNT(*) AS orphan_accounts
FROM ACCOUNT a LEFT JOIN CUSTOMER c ON a.customer_id = c.customer_id
WHERE c.customer_id IS NULL;

SELECT COUNT(*) AS orphan_txn_src
FROM TRANSACTION t LEFT JOIN ACCOUNT a ON t.account_id = a.account_id
WHERE t.account_id IS NOT NULL AND a.account_id IS NULL;

-- Both should return 0.


-- ---------------------------------------------------------------------
-- 5. Proof that each data structure works
--    Run these four. If all four return rows, the prototype's foundation
--    is sound and every workstream can build on it.
-- ---------------------------------------------------------------------

-- 5.1 RELATIONAL: plain aggregation
SELECT txn_type, COUNT(*) AS txns, ROUND(SUM(amount), 2) AS total_aud
FROM TRANSACTION
GROUP BY txn_type
ORDER BY txns DESC;

-- 5.2 SEMI-STRUCTURED: read inside the VARIANT, and show that the two
--     customer types genuinely carry different shapes
SELECT
    customer_type,
    COUNT(*)                                        AS customers,
    COUNT(kyc_payload:abn)                          AS have_abn,
    COUNT(kyc_payload:identity_documents)           AS have_id_docs,
    COUNT(kyc_payload:directors)                    AS have_directors
FROM CUSTOMER
GROUP BY customer_type;

-- Flatten a nested array out of the document
SELECT
    c.customer_id,
    doc.value:type::VARCHAR    AS document_type,
    doc.value:country::VARCHAR AS country
FROM CUSTOMER c,
     LATERAL FLATTEN(input => c.kyc_payload:identity_documents) doc
WHERE c.customer_type = 'retail'
LIMIT 10;

-- 5.3 GRAPH-SHAPED: recursive traversal of the money-flow graph.
--     This is the core of scenarios 1 and 2. It walks TRANSACTION as a
--     directed edge set, up to 8 hops, excluding transfers between a
--     single customer's own accounts.
WITH RECURSIVE flow AS (
    -- seed: every transfer out of an account
    SELECT
        t.account_id                AS origin,
        t.counterparty_account_id   AS current_account,
        t.amount,
        t.txn_time,
        1                           AS hop,
        ARRAY_CONSTRUCT(t.account_id, t.counterparty_account_id) AS path
    FROM TRANSACTION t
    WHERE t.txn_type = 'transfer'
      AND t.account_id IS NOT NULL
      AND t.counterparty_account_id IS NOT NULL

    UNION ALL

    -- step: follow the money one more hop
    SELECT
        f.origin,
        t.counterparty_account_id,
        t.amount,
        t.txn_time,
        f.hop + 1,
        ARRAY_APPEND(f.path, t.counterparty_account_id)
    FROM flow f
    JOIN TRANSACTION t
          ON t.account_id = f.current_account
         AND t.txn_time   > f.txn_time                 -- time must move forward
         AND t.txn_type   = 'transfer'
    JOIN ACCOUNT a1 ON f.current_account = a1.account_id
    JOIN ACCOUNT a2 ON t.counterparty_account_id = a2.account_id
    WHERE f.hop < 8
      AND a1.customer_id <> a2.customer_id             -- exclude own-account moves
      AND NOT ARRAY_CONTAINS(t.counterparty_account_id::VARIANT, f.path)  -- no revisits
)
SELECT origin, current_account AS final_beneficiary, hop, path
FROM flow
WHERE hop >= 4
ORDER BY hop DESC
LIMIT 20;

-- 5.4 DERIVED VIEW: the mule ring
SELECT * FROM V_SHARED_DEVICE_LINK ORDER BY session_count DESC LIMIT 10;


-- ---------------------------------------------------------------------
-- 6. Governance demo
--    The same query, two roles, different results. This single comparison
--    is the evidence base for the governed-access capability.
-- ---------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;
INSERT INTO CURATED.BRANCH_ACCESS_MAP VALUES ('AML_BRANCH_STAFF', 'BRN-0001');

GRANT ROLE AML_ANALYST  TO USER IDENTIFIER(CURRENT_USER());
GRANT ROLE AML_BRANCH_STAFF TO USER IDENTIFIER(CURRENT_USER());

-- Run as the analyst: full PII, all branches
USE ROLE AML_ANALYST;
USE WAREHOUSE AML_WH;
SELECT customer_id, full_name, email, phone, date_of_birth
FROM AML_PROTOTYPE.CURATED.CUSTOMER LIMIT 5;

SELECT COUNT(*) AS visible_transactions FROM AML_PROTOTYPE.CURATED.TRANSACTION;

-- Run as branch staff: PII masked, one branch only
USE ROLE AML_BRANCH_STAFF;
USE WAREHOUSE AML_WH;
SELECT customer_id, full_name, email, phone, date_of_birth
FROM AML_PROTOTYPE.CURATED.CUSTOMER LIMIT 5;

SELECT COUNT(*) AS visible_transactions FROM AML_PROTOTYPE.CURATED.TRANSACTION;

-- The two counts differ and the PII is masked in the second. Screenshot both
-- side by side: that is the governance result for the report.

USE ROLE ACCOUNTADMIN;


-- ---------------------------------------------------------------------
-- 7. Shut the warehouse down when finished
-- ---------------------------------------------------------------------

ALTER WAREHOUSE AML_WH SUSPEND;
