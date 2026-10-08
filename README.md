# aml-lakehouse

An anti-money-laundering monitoring prototype built on a single data lakehouse.

Transaction, customer and digital-channel data land in one governed Snowflake
database and are queried for four money-laundering typologies. The same platform
holds relational, graph-shaped and semi-structured data, so detection that
depends on relationships between records runs alongside ordinary transactional
queries without a second system.

---

## Why one platform

Relationship-based laundering is invisible to rule engines that look at one
transaction at a time. A layering chain of six hops is six unremarkable
transfers; the pattern exists only in how they connect. The usual answer is to
add a graph database alongside the warehouse, which doubles the operational
surface and splits governance in two.

This prototype keeps everything in one lakehouse and treats the transaction
table as a directed edge set, traversed with recursive SQL. Semi-structured KYC
and alert evidence live in `VARIANT` columns rather than sparse tables or
subtype joins. The cost of that consolidation, particularly traversal
performance as hop depth increases, is measured rather than assumed.

---

## Architecture

```
 SOURCES              INGESTION              LAKEHOUSE              CONSUMPTION
 ───────              ─────────              ─────────              ───────────

 core banking  ──┐                       ┌──────────────┐
 customer/KYC  ──┼──► stage upload ──►   │ RAW          │        investigator
 digital channel─┘    scheduled task     │ (VARIANT)    │          dashboard
                                         ├──────────────┤
                                         │ CURATED      │ ──►    regulatory
                                         │ 7 tables     │         reporting
                                         │ 3 link views │
                                         ├──────────────┤
                                         │ SERVING      │
                                         │ alert queue  │
                                         └──────────────┘
                              ╔═══════════════════════════════╗
                              ║ GOVERNANCE                    ║
                              ║ roles, secure views, masking  ║
                              ╚═══════════════════════════════╝
```

Full diagrams in `docs/`.

### Schemas

| Schema | Holds |
|---|---|
| `RAW` | Landing tables, one `VARIANT` column each, data exactly as received |
| `CURATED` | The seven modelled tables, three derived link views, two secure views |
| `SERVING` | Query-ready views for the alert queue and dashboards |
| `EVALUATION` | Labelled ground truth, isolated behind its own role |

### Data model

Seven tables. `TRANSACTION` carries two foreign keys to `ACCOUNT`, which is what
makes it a directed edge set and the basis of chain and cycle detection.

| Table | Role |
|---|---|
| `CUSTOMER` | One row per customer, retail or business. `kyc_payload` is `VARIANT` |
| `ACCOUNT` | Accounts owned by a customer |
| `TRANSACTION` | Transfers, cash deposits and withdrawals. The fact table and the edge set |
| `SESSION` | One row per digital-channel login. Bridges accounts to devices and IPs |
| `DEVICE` | Distinct devices, looked up rather than repeated |
| `IP_ADDRESS` | Distinct IPs with geo and VPN flag |
| `FRAUD_ALERT` | Detection results with investigation state. `trigger_detail` is `VARIANT` |

Three views derive relationship edges without storing them:

| View | Derives |
|---|---|
| `V_SHARED_DEVICE_LINK` | Customer pairs whose sessions share a device |
| `V_SHARED_IP_LINK` | Customer pairs sharing a non-VPN IP |
| `V_SHARED_CONTACT_LINK` | Customer pairs sharing email, phone or address |

The VPN exclusion matters. Carrier-grade NAT and public wifi produce shared IPs
across unrelated people, and without filtering them the view returns noise.

---

## Detection scenarios

| Scenario | Pattern | Technique |
|---|---|---|
| Structuring | Cash deposits held under the AUD 10,000 threshold, spread across branches | Window aggregation |
| Layering chain | Funds moved through 4 to 8 accounts, decaying amounts, short intervals | Recursive CTE |
| Round-tripping | Funds leaving and returning to the origin through intermediaries | Recursive CTE with cycle termination |
| Mule network | Recently opened accounts sharing a device, rapid in and out | Shared-attribute views |

Each detection query is exposed as a view in `SERVING` with a fixed signature,
so alert generation reads all four through one union and is unaffected by
changes inside any individual detector.

---

## Getting started

### Prerequisites

- A Snowflake account. Standard Edition is sufficient
- Python 3.9 or later, standard library only

### 1. Create the database

Run `sql/aml_schemav3.sql` in a Snowflake worksheet as `ACCOUNTADMIN`. It creates
the database, four schemas, an X-Small warehouse, five roles, the tables and
views, and the governance objects.

Verify:

```sql
SHOW TABLES IN SCHEMA AML_PROTOTYPE.CURATED;
SHOW VIEWS  IN SCHEMA AML_PROTOTYPE.CURATED;
```

### 2. Generate data

```bash
python3 generator/generate_data.py --scale small --gzip --out ./data
```

| Scale | Transactions | Runtime | Gzipped |
|---|---|---|---|
| `tiny` | 500 | instant | 0.1 MB |
| `small` | 50,000 | 1 s | 2.2 MB |
| `medium` | 500,000 | 11 s | 20 MB |
| `full` | 2,000,000 | 45 s | 85 MB |

Seven `.jsonl.gz` files are written, one per entity. The generator validates its
own output and exits non-zero on referential or contract violations.

### 3. Load

Upload the seven files to the `AML_PROTOTYPE.RAW.AML_STAGE` stage, then run
`sql/load_sample.sql`. It copies the files into the raw tables as `VARIANT`,
transforms them into the curated model, and runs six verification queries.

All six must pass before anything downstream is trustworthy. The null-handling
check is handled: if JSON nulls arrive as the string `"null"`, cash
deposits lose their null originator and structuring detection silently returns
nothing.

### 4. Automate

`sql/pipeline.sql` wraps the load in two stored procedures driven by a task
DAG:

```
T_LOAD_RAW ──► T_LOAD_CURATED
```

Run it on demand with `EXECUTE TASK RAW.T_LOAD_RAW;` to rebuild all tables from
the staged files in one statement.

---

## The data generator

Produces labelled synthetic data. There is no public AML dataset with ground
truth, because real suspicious-matter outcomes are confidential, partial and
delayed. Synthetic data with injected patterns is the only way to measure
precision and recall exactly.

Four patterns are injected at roughly 0.8 percent of transaction volume, each
carrying a `chain_id` and `hop_index` so detection can be scored on whether it
recovered a whole chain rather than merely touched one.

Two design choices worth knowing:

**Chain hops use distinct customers.** Traversal queries exclude transfers
between a single customer's own accounts, because otherwise anyone with a
savings and an offset account looks like a two-hop chain. Injected chains
therefore cross customer boundaries at every hop, or the detectors would filter
out the very patterns they are meant to find.

**Devices and IPs are owned, not random.** Each account has a primary device and
a primary IP, with 3 percent of sessions crossing over to another device and 12
percent using a VPN or carrier IP. Random assignment would make ordinary devices
appear shared by a dozen customers and bury the mule signal. The resulting
distribution has a clean baseline at one customer per device, a legitimate tail
at two to three, and rings standing out at six and above, which gives detection
a real decision boundary and a measurable false positive rate.

---

## Ground truth isolation

`EVALUATION.GROUND_TRUTH` holds the generator's labels. It lives in its own
schema, is granted only to the `AML_EVAL` role, and is excluded from the
scheduled pipeline.

**No detection query may join to it.** If a detector can see the labels, every
precision figure derived from it is meaningless. Evaluation runs as a separate
query under a separate role.

---

## Governance

Snowflake Standard Edition does not support dynamic data masking, row access
policies or object tagging, which are Enterprise features. Equivalent controls
are implemented as secure views with role-based predicates:

| Control | Implementation |
|---|---|
| Column masking | `V_CUSTOMER_SECURE` masks PII for all roles except `AML_ANALYST` |
| Row filtering | `V_TRANSACTION_SECURE` restricts branch staff to mapped branches |
| PII location | `PII_CATALOG` records which columns carry personal data |

Enforcement comes from the grants: roles other than `AML_ANALYST` are granted
the views and never the base tables, so there is nothing to bypass.

---

## Repository layout

```
sql/
  aml_schema.sql      database, schemas, roles, tables, views, governance
  load_sample.sql        stage to raw, raw to curated, verification
  pipeline.sql    stored procedures and the task DAG
  detection.sql   the four detection views
  alerts.sql      alert generation and serving views
generator/
  generate_data.py   synthetic data generator
docs/
  data-contract.md   file formats, identifier conventions, injected patterns
  erd.svg            entity relationship diagram
  architecture.svg   solution architecture
  erd.svg            entity relation diagram
```

---

## Current limitations

| Limitation | Note |
|---|---|
| Continuous ingestion is designed but not implemented | Loading runs as scheduled batch rather than streaming |
| Graph traversal uses recursive SQL | No native graph engine. Performance at depth is measured rather than assumed |
| Governance uses secure views | Enterprise masking and row access policies were unavailable |
| Source systems are simulated | Three notional sources with distinct schemas, produced by the generator |
| Customer nationality is stored but not used in scoring | Jurisdiction of transaction is the appropriate risk key |

---

## Conventions

| | |
|---|---|
| Timestamps | UTC, ISO 8601, suffix `_ts` or named `*_time` |
| Dates | Suffix `_dt` or `_date` |
| Money | `DECIMAL(18,2)`, never `FLOAT` |
| Booleans | Prefix `is_` |
| Identifiers | Prefixed and zero padded: `CUS-000001`, `ACC-000001`, `TRX-00000001` |

`DECIMAL` for money is not pedantry. Floating point drift around the AUD 10,000
reporting threshold corrupts structuring counts.
