-- =====================================================================
--  AML Monitoring Prototype
--  Snowflake DDL: database, schemas, roles, tables, views, policies
--
--  Run order is top to bottom. Safe to re-run: every object is
--  CREATE OR REPLACE except schemas and roles.
--
--  Zones:
--    RAW         landing, VARIANT, exactly as received
--    CURATED     the seven modelled tables and three derived views
--    SERVING     query-ready views and aggregates
--    EVALUATION  ground truth, isolated, separate grant
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Database, schemas, warehouse
-- ---------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS AML_PROTOTYPE;
USE DATABASE AML_PROTOTYPE;

CREATE SCHEMA IF NOT EXISTS RAW;
CREATE SCHEMA IF NOT EXISTS CURATED;
CREATE SCHEMA IF NOT EXISTS SERVING;
CREATE SCHEMA IF NOT EXISTS EVALUATION;

-- XS only. AUTO_SUSPEND is the single most important cost control:
-- an idle warehouse left running overnight burns several days of trial credit.
CREATE WAREHOUSE IF NOT EXISTS AML_WH
  WAREHOUSE_SIZE   = 'XSMALL'
  AUTO_SUSPEND     = 60
  AUTO_RESUME      = TRUE
  INITIALLY_SUSPENDED = TRUE;


-- ---------------------------------------------------------------------
-- 2. Roles
--    Three business roles exist to demonstrate governed access.
--    AML_DEV is the build role. AML_EVAL is the only role that can
--    read ground truth.
-- ---------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS AML_DEV;
CREATE ROLE IF NOT EXISTS AML_ANALYST;      -- full alert queue, unmasked PII
CREATE ROLE IF NOT EXISTS AML_BRANCH_STAFF;     -- own branch only, PII masked
CREATE ROLE IF NOT EXISTS AML_DATA_ENGINEER;    -- structure visible, PII masked
CREATE ROLE IF NOT EXISTS AML_EVAL;         -- ground truth only

GRANT USAGE ON WAREHOUSE AML_WH TO ROLE AML_DEV;
GRANT USAGE ON WAREHOUSE AML_WH TO ROLE AML_ANALYST;
GRANT USAGE ON WAREHOUSE AML_WH TO ROLE AML_BRANCH_STAFF;
GRANT USAGE ON WAREHOUSE AML_WH TO ROLE AML_DATA_ENGINEER;
GRANT USAGE ON WAREHOUSE AML_WH TO ROLE AML_EVAL;

GRANT USAGE ON DATABASE AML_PROTOTYPE TO ROLE AML_DEV;
GRANT USAGE ON DATABASE AML_PROTOTYPE TO ROLE AML_ANALYST;
GRANT USAGE ON DATABASE AML_PROTOTYPE TO ROLE AML_BRANCH_STAFF;
GRANT USAGE ON DATABASE AML_PROTOTYPE TO ROLE AML_DATA_ENGINEER;
GRANT USAGE ON DATABASE AML_PROTOTYPE TO ROLE AML_EVAL;

GRANT ALL ON SCHEMA RAW        TO ROLE AML_DEV;
GRANT ALL ON SCHEMA CURATED    TO ROLE AML_DEV;
GRANT ALL ON SCHEMA SERVING    TO ROLE AML_DEV;
GRANT ALL ON SCHEMA EVALUATION TO ROLE AML_DEV;

GRANT USAGE ON SCHEMA CURATED TO ROLE AML_ANALYST;
GRANT USAGE ON SCHEMA SERVING TO ROLE AML_ANALYST;
GRANT USAGE ON SCHEMA CURATED TO ROLE AML_BRANCH_STAFF;
GRANT USAGE ON SCHEMA SERVING TO ROLE AML_BRANCH_STAFF;
GRANT USAGE ON SCHEMA CURATED TO ROLE AML_DATA_ENGINEER;

-- EVALUATION is deliberately NOT granted to any detection role.
GRANT USAGE ON SCHEMA EVALUATION TO ROLE AML_EVAL;


-- ---------------------------------------------------------------------
-- 3. RAW zone
--    One shape for every landing table: land first, type later.
--    src_file and loaded_ts give lineage for free.
-- ---------------------------------------------------------------------

USE SCHEMA RAW;

CREATE OR REPLACE TABLE CUSTOMER_RAW (
    payload     VARIANT,
    src_file    VARCHAR(500),
    loaded_ts   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE ACCOUNT_RAW (
    payload     VARIANT,
    src_file    VARCHAR(500),
    loaded_ts   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE TRANSACTION_RAW (
    payload     VARIANT,
    src_file    VARCHAR(500),
    loaded_ts   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE SESSION_RAW (
    payload     VARIANT,
    src_file    VARCHAR(500),
    loaded_ts   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE DEVICE_RAW (
    payload     VARIANT,
    src_file    VARCHAR(500),
    loaded_ts   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE IP_ADDRESS_RAW (
    payload     VARIANT,
    src_file    VARCHAR(500),
    loaded_ts   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Internal stage the generator writes JSONL files to.
CREATE OR REPLACE FILE FORMAT JSONL_FORMAT
    TYPE = JSON
    STRIP_OUTER_ARRAY = FALSE
    COMPRESSION = AUTO;

CREATE STAGE IF NOT EXISTS AML_STAGE
    FILE_FORMAT = JSONL_FORMAT;


-- ---------------------------------------------------------------------
-- 4. CURATED zone: the seven tables
--    Snowflake does not enforce PK and FK constraints, but they are
--    declared because the optimizer uses them and they document intent.
-- ---------------------------------------------------------------------

USE SCHEMA CURATED;

-- 4.1 CUSTOMER -------------------------------------------------------
CREATE OR REPLACE TABLE CUSTOMER (
    customer_id             VARCHAR(20)     NOT NULL,
    customer_type           VARCHAR(10)     NOT NULL,   -- retail | business
    full_name               VARCHAR(100),
    date_of_birth           DATE,                       -- null for business
    nationality             VARCHAR(50),
    email                   VARCHAR(100),
    phone                   VARCHAR(20),
    address                 VARCHAR(200),
    occupation_or_industry  VARCHAR(100),
    declared_income_aud     DECIMAL(18,2),
    kyc_status              VARCHAR(20),                -- verified | pending | failed
    kyc_payload             VARIANT,                    -- shape varies by customer_type
    risk_rating             VARCHAR(20),                -- low | medium | high
    onboard_dt              DATE,
    status                  VARCHAR(20),                -- active | dormant | closed
    created_at              TIMESTAMP_NTZ,

    CONSTRAINT pk_customer PRIMARY KEY (customer_id)
);

-- 4.2 ACCOUNT --------------------------------------------------------
CREATE OR REPLACE TABLE ACCOUNT (
    account_id      VARCHAR(20)     NOT NULL,
    customer_id     VARCHAR(20)     NOT NULL,
    account_number  VARCHAR(20),
    account_type    VARCHAR(20),                -- transaction | savings | business | offset
    currency        VARCHAR(3)      DEFAULT 'AUD',
    balance         DECIMAL(18,2),
    status          VARCHAR(20),                -- active | frozen | closed
    open_date       DATE,
    branch_code     VARCHAR(10),                -- home branch

    CONSTRAINT pk_account PRIMARY KEY (account_id),
    CONSTRAINT fk_account_customer FOREIGN KEY (customer_id)
        REFERENCES CUSTOMER (customer_id)
);

-- 4.3 DEVICE ---------------------------------------------------------
CREATE OR REPLACE TABLE DEVICE (
    device_id           VARCHAR(20)     NOT NULL,
    device_fingerprint  VARCHAR(64),
    device_type         VARCHAR(20),            -- mobile | desktop | tablet
    os                  VARCHAR(30),
    first_seen          TIMESTAMP_NTZ,
    last_seen           TIMESTAMP_NTZ,

    CONSTRAINT pk_device PRIMARY KEY (device_id)
);

-- 4.4 IP_ADDRESS -----------------------------------------------------
CREATE OR REPLACE TABLE IP_ADDRESS (
    ip_id       VARCHAR(20)     NOT NULL,
    ip_address  VARCHAR(45),                    -- IPv6 safe
    country     VARCHAR(50),
    city        VARCHAR(50),
    is_vpn      BOOLEAN,                        -- separates rings from carrier/wifi decoys
    risk_score  DECIMAL(5,2),

    CONSTRAINT pk_ip_address PRIMARY KEY (ip_id)
);

-- 4.5 SESSION --------------------------------------------------------
CREATE OR REPLACE TABLE SESSION (
    session_id      VARCHAR(20)     NOT NULL,
    account_id      VARCHAR(20)     NOT NULL,
    device_id       VARCHAR(20),
    ip_id           VARCHAR(20),
    session_time    TIMESTAMP_NTZ,
    channel         VARCHAR(20),                -- app | netbank
    auth_method     VARCHAR(20),                -- password | biometric | mfa

    CONSTRAINT pk_session PRIMARY KEY (session_id),
    CONSTRAINT fk_session_account FOREIGN KEY (account_id)
        REFERENCES ACCOUNT (account_id),
    CONSTRAINT fk_session_device FOREIGN KEY (device_id)
        REFERENCES DEVICE (device_id),
    CONSTRAINT fk_session_ip FOREIGN KEY (ip_id)
        REFERENCES IP_ADDRESS (ip_id)
);

-- 4.6 TRANSACTION ----------------------------------------------------
--     Two foreign keys to ACCOUNT. This self-reference is what makes
--     the table a directed edge set and is the basis of scenarios 1 and 2.
--     amount is DECIMAL, never FLOAT: floating point drift around the
--     AUD 10,000 threshold corrupts structuring counts.
CREATE OR REPLACE TABLE TRANSACTION (
    transaction_id          VARCHAR(20)     NOT NULL,
    account_id              VARCHAR(20),            -- originating, null for cash deposit
    counterparty_account_id VARCHAR(20),            -- receiving, null for cash withdrawal
    session_id              VARCHAR(20),            -- null for branch and ATM
    txn_time                TIMESTAMP_NTZ   NOT NULL,
    amount                  DECIMAL(18,2)   NOT NULL,
    currency                VARCHAR(3)      DEFAULT 'AUD',
    txn_type                VARCHAR(20),            -- cash_deposit | cash_withdrawal
                                                    -- | transfer | direct_debit
    channel                 VARCHAR(20),            -- branch | atm | netbank | mobile
                                                    -- | payid | osko
    branch_code             VARCHAR(10),            -- where cash was handled, null for digital
    description             VARCHAR(200),
    status                  VARCHAR(20),            -- completed | reversed | blocked

    CONSTRAINT pk_transaction PRIMARY KEY (transaction_id),
    CONSTRAINT fk_txn_src FOREIGN KEY (account_id)
        REFERENCES ACCOUNT (account_id),
    CONSTRAINT fk_txn_dst FOREIGN KEY (counterparty_account_id)
        REFERENCES ACCOUNT (account_id),
    CONSTRAINT fk_txn_session FOREIGN KEY (session_id)
        REFERENCES SESSION (session_id)
)
CLUSTER BY (txn_time, account_id);

-- 4.7 FRAUD_ALERT ----------------------------------------------------
CREATE OR REPLACE TABLE FRAUD_ALERT (
    alert_id        VARCHAR(20)     NOT NULL,
    account_id      VARCHAR(20),
    transaction_id  VARCHAR(20),                -- null for network-level alerts
    alert_type      VARCHAR(30),                -- structuring | layering_chain
                                                -- | round_trip | mule_network
    fraud_score     DECIMAL(5,2),
    trigger_detail  VARIANT,                    -- shape varies by alert_type
    status          VARCHAR(20),                -- open | in_review | escalated | closed
    disposition     VARCHAR(20),                -- confirmed | false_positive | inconclusive
    raised_at       TIMESTAMP_NTZ,
    resolved_at     TIMESTAMP_NTZ,
    investigator    VARCHAR(50),

    CONSTRAINT pk_fraud_alert PRIMARY KEY (alert_id),
    CONSTRAINT fk_alert_account FOREIGN KEY (account_id)
        REFERENCES ACCOUNT (account_id),
    CONSTRAINT fk_alert_transaction FOREIGN KEY (transaction_id)
        REFERENCES TRANSACTION (transaction_id)
);


-- ---------------------------------------------------------------------
-- 5. CURATED zone: the three derived views
--    These replace a stored edge table. Nothing to populate or keep
--    in sync, and the exclusion of self-links is a predicate rather
--    than a row.
-- ---------------------------------------------------------------------

-- 5.1 Customers sharing a device --------------------------------------
CREATE OR REPLACE VIEW V_SHARED_DEVICE_LINK AS
SELECT
    a1.customer_id              AS customer_a,
    a2.customer_id              AS customer_b,
    s1.device_id                AS device_id,
    COUNT(*)                    AS session_count,
    MIN(LEAST(s1.session_time, s2.session_time))    AS first_seen,
    MAX(GREATEST(s1.session_time, s2.session_time)) AS last_seen
FROM SESSION s1
JOIN SESSION s2
      ON s1.device_id = s2.device_id
     AND s1.session_id <> s2.session_id
JOIN ACCOUNT a1 ON s1.account_id = a1.account_id
JOIN ACCOUNT a2 ON s2.account_id = a2.account_id
WHERE a1.customer_id < a2.customer_id        -- unordered pair, and excludes self-links
GROUP BY a1.customer_id, a2.customer_id, s1.device_id;

-- 5.2 Customers sharing a non-VPN IP -----------------------------------
--     is_vpn is excluded deliberately. Carrier-grade NAT and public wifi
--     produce shared IPs across unrelated customers, and without this filter
--     the view drowns in false positives.
CREATE OR REPLACE VIEW V_SHARED_IP_LINK AS
SELECT
    a1.customer_id              AS customer_a,
    a2.customer_id              AS customer_b,
    s1.ip_id                    AS ip_id,
    COUNT(*)                    AS session_count,
    MIN(LEAST(s1.session_time, s2.session_time))    AS first_seen,
    MAX(GREATEST(s1.session_time, s2.session_time)) AS last_seen
FROM SESSION s1
JOIN SESSION s2
      ON s1.ip_id = s2.ip_id
     AND s1.session_id <> s2.session_id
JOIN ACCOUNT a1    ON s1.account_id = a1.account_id
JOIN ACCOUNT a2    ON s2.account_id = a2.account_id
JOIN IP_ADDRESS ip ON s1.ip_id = ip.ip_id
WHERE a1.customer_id < a2.customer_id
  AND COALESCE(ip.is_vpn, FALSE) = FALSE
GROUP BY a1.customer_id, a2.customer_id, s1.ip_id;

-- 5.3 Customers sharing a contact attribute ----------------------------
CREATE OR REPLACE VIEW V_SHARED_CONTACT_LINK AS
SELECT c1.customer_id AS customer_a, c2.customer_id AS customer_b,
       'email' AS match_type, c1.email AS match_value
FROM CUSTOMER c1 JOIN CUSTOMER c2
  ON c1.email = c2.email AND c1.customer_id < c2.customer_id
WHERE c1.email IS NOT NULL
UNION ALL
SELECT c1.customer_id, c2.customer_id, 'phone', c1.phone
FROM CUSTOMER c1 JOIN CUSTOMER c2
  ON c1.phone = c2.phone AND c1.customer_id < c2.customer_id
WHERE c1.phone IS NOT NULL
UNION ALL
SELECT c1.customer_id, c2.customer_id, 'address', c1.address
FROM CUSTOMER c1 JOIN CUSTOMER c2
  ON c1.address = c2.address AND c1.customer_id < c2.customer_id
WHERE c1.address IS NOT NULL;


-- ---------------------------------------------------------------------
-- 6. EVALUATION zone
--    Experiment instrumentation, not part of the AML solution.
--    No detection query may join to this table.
-- ---------------------------------------------------------------------

USE SCHEMA EVALUATION;

CREATE OR REPLACE TABLE GROUND_TRUTH (
    transaction_id  VARCHAR(20)     NOT NULL,
    pattern_label   VARCHAR(30),        -- normal | structuring | layering_chain
                                        -- | round_trip | mule_network
    chain_id        VARCHAR(20),        -- groups transactions of one injected pattern
    hop_index       INT,                -- position within the chain

    CONSTRAINT pk_ground_truth PRIMARY KEY (transaction_id)
);


-- ---------------------------------------------------------------------
-- 7. Governance
--    Snowflake Standard Edition does not support masking policies, row
--    access policies or object tagging. Those are Enterprise features.
--    The same controls are implemented here as SECURE VIEWS driven by
--    CURRENT_ROLE(), which works on Standard.
--
--    Enforcement comes from the grants in section 8: roles other than
--    AML_ANALYST are granted the views only, never the base tables.
-- ---------------------------------------------------------------------

USE SCHEMA CURATED;

-- 7.1 Branch access map -----------------------------------------------
--     One row per role that is restricted to specific branches.
CREATE OR REPLACE TABLE BRANCH_ACCESS_MAP (
    role_name    VARCHAR(50),
    branch_code  VARCHAR(10)
);

-- 7.2 Column masking via secure view -----------------------------------
--     AML_ANALYST sees PII. Every other role sees it masked.
CREATE OR REPLACE SECURE VIEW V_CUSTOMER_SECURE AS
SELECT
    customer_id,
    customer_type,
    CASE WHEN CURRENT_ROLE() IN ('AML_ANALYST', 'ACCOUNTADMIN')
         THEN full_name ELSE '****MASKED****' END            AS full_name,
    CASE WHEN CURRENT_ROLE() IN ('AML_ANALYST', 'ACCOUNTADMIN')
         THEN date_of_birth ELSE NULL END                    AS date_of_birth,
    nationality,
    CASE WHEN CURRENT_ROLE() IN ('AML_ANALYST', 'ACCOUNTADMIN')
         THEN email ELSE '****MASKED****' END                AS email,
    CASE WHEN CURRENT_ROLE() IN ('AML_ANALYST', 'ACCOUNTADMIN')
         THEN phone ELSE '****MASKED****' END                AS phone,
    CASE WHEN CURRENT_ROLE() IN ('AML_ANALYST', 'ACCOUNTADMIN')
         THEN address ELSE '****MASKED****' END              AS address,
    occupation_or_industry,
    declared_income_aud,
    kyc_status,
    kyc_payload,
    risk_rating,
    onboard_dt,
    status,
    created_at
FROM CUSTOMER;

-- 7.3 Row filtering via secure view ------------------------------------
--     AML_ANALYST and AML_DATA_ENGINEER see every branch.
--     AML_BRANCH_STAFF sees only the branches mapped to its role.
CREATE OR REPLACE SECURE VIEW V_TRANSACTION_SECURE AS
SELECT t.*
FROM TRANSACTION t
WHERE CURRENT_ROLE() IN ('AML_ANALYST', 'AML_DATA_ENGINEER', 'ACCOUNTADMIN')
   OR EXISTS (
        SELECT 1
        FROM BRANCH_ACCESS_MAP m
        WHERE m.role_name   = CURRENT_ROLE()
          AND m.branch_code = t.branch_code
   );

-- 7.4 PII catalogue ----------------------------------------------------
--     Stands in for object tagging: records where personal data lives so
--     it can be located without reading every table.
CREATE OR REPLACE TABLE PII_CATALOG (
    table_name      VARCHAR(50),
    column_name     VARCHAR(50),
    classification  VARCHAR(30)
);

INSERT INTO PII_CATALOG VALUES
    ('CUSTOMER', 'full_name',     'identity'),
    ('CUSTOMER', 'date_of_birth', 'identity'),
    ('CUSTOMER', 'email',         'contact'),
    ('CUSTOMER', 'phone',         'contact'),
    ('CUSTOMER', 'address',       'contact'),
    ('CUSTOMER', 'kyc_payload',   'identity_document'),
    ('ACCOUNT',  'account_number','financial');


-- ---------------------------------------------------------------------
-- 8. Grants
--    AML_ANALYST gets the base tables. Every other role gets only the
--    secure views, which is what makes the masking and row filtering
--    impossible to bypass.
-- ---------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;

-- Remove any broad grants from an earlier run.
REVOKE SELECT ON ALL TABLES IN SCHEMA CURATED FROM ROLE AML_BRANCH_STAFF;
REVOKE SELECT ON ALL TABLES IN SCHEMA CURATED FROM ROLE AML_DATA_ENGINEER;

-- Analyst: full access to curated tables and views.
GRANT SELECT ON ALL TABLES IN SCHEMA CURATED TO ROLE AML_ANALYST;
GRANT SELECT ON ALL VIEWS  IN SCHEMA CURATED TO ROLE AML_ANALYST;

-- Branch staff: secure views only.
GRANT SELECT ON VIEW V_CUSTOMER_SECURE    TO ROLE AML_BRANCH_STAFF;
GRANT SELECT ON VIEW V_TRANSACTION_SECURE TO ROLE AML_BRANCH_STAFF;

-- Data engineer: secure views only, plus the structural link views.
GRANT SELECT ON VIEW V_CUSTOMER_SECURE     TO ROLE AML_DATA_ENGINEER;
GRANT SELECT ON VIEW V_TRANSACTION_SECURE  TO ROLE AML_DATA_ENGINEER;
GRANT SELECT ON VIEW V_SHARED_DEVICE_LINK  TO ROLE AML_DATA_ENGINEER;
GRANT SELECT ON VIEW V_SHARED_IP_LINK      TO ROLE AML_DATA_ENGINEER;

-- Evaluation role: ground truth only.
GRANT SELECT ON ALL TABLES IN SCHEMA EVALUATION TO ROLE AML_EVAL;

-- Detection roles are never granted EVALUATION. This is the enforcement
-- behind the claim that ground truth is isolated.
