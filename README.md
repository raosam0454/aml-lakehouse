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

| Scenario | Pattern | Technique | Where |
|---|---|---|---|
| Structuring | Cash deposits held under the AUD 10,000 threshold, spread across branches | Window aggregation | structuring query (Bao), not yet wired into `alerts.sql` |
| Layering chain | Funds moved through 4 to 8 accounts, decaying amounts, short intervals | Recursive CTE | `SERVING.DET_LAYERING` |
| Round-tripping | Funds leaving and returning to the origin through intermediaries | Recursive CTE with cycle termination + identity cross-check | `SERVING.DET_ROUND_TRIP` |
| Mule network | Recently opened accounts sharing a device, rapid in and out | Shared device + pass-through behaviour | `SERVING.DET_MULE` |

`sql/detection.sql` builds one table per detector in `SERVING`. `sql/alerts.sql`
reads them through one union into `CURATED.FRAUD_ALERT`, with the evidence for
each alert (path, transactions, tier, why it was flagged) in `trigger_detail`.

---

## Graph detection

Layering, round-tripping and mule rings are relationship patterns, so they are
detected as a graph over the curated tables. There is no second engine in the
pipeline: the graph lives in the lakehouse and is traversed with recursive SQL.
A Neo4j copy is used only to measure that choice and to draw the rings.

### The graph

| Element | Built from | Table |
|---|---|---|
| Money edge (account → account) | completed transfers, one edge per transaction, owners differ | `SERVING.P1_EDGE` |
| Identity link (account – account) | same phone or email (`CUSTOMER`), same device (`SESSION`) | `SERVING.ACC_LINK` |

One edge per transaction, never aggregated, so every hop keeps its own time and
amount. Transfers between a customer's own accounts are excluded, otherwise a
savings-to-offset transfer reads as a hop. IP and address are left out of the
strong links: carrier NAT, public wifi and shared buildings make them noisy.

### Two patterns that cross-check each other

- **P1, money flow.** Follow the money hop by hop (`SERVING.P1_WALK`). A hop is
  kept only if it happens after the previous one, within 48 hours, and moves
  80–100% of the previous amount (the launderer's fee). At most 8 hops, no
  account revisited. Pruning happens inside the recursion, so the number of
  paths grows linearly with volume instead of exploding.
- **P2, shared identity.** Accounts of different customers linked by phone,
  email or device.

P2 also **closes the loop** for P1. Money rarely returns to the exact origin
account. It returns to the launderer's other account or a relative's. A path
counts as a round-trip if it ends on the origin **or on an account linked to the
origin**.

| Tier | Rule |
|---|---|
| high | cycle (P1) and a shared identity (P2): closed through a link, or two members share a phone/email/device |
| medium | cycle only, or a layering chain |

Rings are de-duplicated by keeping only maximal ones. Inside a ring whose members
share a device, every sub-path also "closes" on a linked member.

### Results (generator seed 42, small: 50,012 transactions)

`sql/benchmark.sql` compares the detectors with `EVALUATION.GROUND_TRUTH`. A
chain counts as found only if **one** detection covers all of it.

| Pattern | Chains | Found | Partial | Missed | Tier |
|---|---|---|---|---|---|
| round_trip | 6 | 6 | 0 | 0 | medium |
| round_trip_shared_device | 8 | 8 | 0 | 0 | high |
| round_trip_phone_link | 5 | 5 | 0 | 0 | high |
| round_trip_sub_threshold | 4 | 0 | 1 | 3 | — |
| layering_chain | 15 | 15 | 0 | 0 | medium |
| mule_network | 9 | 9 | 0 | 0 | — |

False positives: round-trip 0, mule 0, layering 1. 46 alerts in total.

- **phone_link** is the case the cross-check exists for. A strict "returns to the
  origin" check misses all five; closing the loop through the shared phone finds them.
- **sub_threshold** is missed because the generator draws a new amount at every
  hop, so some hops go *up*. That breaks the decaying-amount rule by design of the
  data, not of the query.
- A medium-scale check (500,226 transactions, seed 7, same logic run locally)
  found every injected ring, chain and mule ring, with 0 false positives for rings
  and mule. Layering false positives rose to 22 of 182: with more volume, random
  transfers more often form a 4-hop decaying chain by chance. A layering chain on
  its own is therefore a weaker signal than a closed ring.

### Neo4j comparison

`neo4j/` loads the same curated data, exported with
`sql/extractNodesAndEdges.sql`, and runs the same detections in Cypher. The results
match (19 rings, 18 chains, 9 mule rings).

| | Snowflake recursive SQL | Cypher, filter after expansion | Cypher, pruned |
|---|---|---|---|
| Rings found | 19 | did not finish | 19 |
| Time to find rings | ~1.8 s (X-Small) | > 90 s | ~2–3 s (laptop) |

The two engines are not timed on the same hardware. The point is that both need
pruning during traversal; without it the graph engine does not finish either.
Details in `neo4j/README.md`.

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

### 5. Detect, alert, evaluate

Run in order in a Snowsight worksheet:

```
sql/detection.sql   ->  SERVING.P1_EDGE, ACC_LINK, P1_WALK, DET_ROUND_TRIP, DET_LAYERING, PASS_THROUGH, DET_MULE
sql/alerts.sql      ->  CURATED.FRAUD_ALERT + SERVING.V_DASH_* views
sql/benchmark.sql   ->  EVALUATION.V_BENCHMARK   (the only script that reads GROUND_TRUTH)
```

### 6. Dashboards

Snowsight Dashboards are deprecated and new ones can no longer be created, so the
dashboards are a Streamlit in Snowflake app: Projects → Streamlit → + Streamlit App
(location `AML_PROTOTYPE.SERVING`, warehouse `AML_WH`), paste
`streamlit/streamlit_app.py`. Three tabs (money rings and layering, shared identity
and mule rings, alert queue) plus an evaluation tab. The query behind each chart is
also in `sql/dashboards.sql`.

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
  aml_schemav3.sql          database, schemas, roles, tables, views, governance
  load_sample.sql           stage to raw, raw to curated, verification
  detection.sql             graph detection: layering, round-trips (P1 + P2), mule rings
  alerts.sql                alert generation into FRAUD_ALERT + dashboard views
  benchmark.sql             detections vs ground truth (EVALUATION)
  dashboards.sql            the queries behind each dashboard chart
  extractNodesAndEdges.sql  export of graph nodes and edges for Neo4j
generator/
  generate_data.py          synthetic data generator
streamlit/
  streamlit_app.py          dashboards (Streamlit in Snowflake)
neo4j/
  00-08                     export query, load + Cypher versions of the detections
  README.md                 graph model, SQL vs Cypher comparison
extractionCsv/
  nodes.zip, edges.zip      exported nodes and edges
```

---

## Current limitations

| Limitation | Note |
|---|---|
| Continuous ingestion is designed but not implemented | Loading runs as scheduled batch rather than streaming |
| Graph traversal uses recursive SQL | No native graph engine. Measured against Neo4j: both need pruning, see Graph detection |
| Layering alone is a weak signal at volume | False positives rise from 1 to 22 when volume grows 10x; rings and mule stay at 0 |
| Sub-threshold rings are not detected | The generator re-draws the amount at every hop, so these rings do not decay |
| Neo4j copy has no cash transactions | The mule check there uses recent onboarding only; cash-out pass-through is checked in Snowflake |
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
