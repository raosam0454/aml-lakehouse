# Neo4j graph layer

The same detections as `sql/detection.sql`, run on a native graph engine, used to
**measure** the cost of keeping graph traversal in the lakehouse (recursive SQL)
and to visualise the rings.

## Flow
`CURATED` (Snowflake) → `00_export_from_snowflake_bao.sql` → CSV → `01_load_snowflake_export.cypher` → Cypher queries

## Graph model
```
(Customer)-[:OWNS]->(Account)-[:SENT_TO {amount, ts, txn_id, channel, device_id, ip_id}]->(Account)
(Account)-[:USED_DEVICE {sessions, first_seen, last_seen}]->(Device)
(Account)-[:USED_IP {sessions, first_seen, last_seen}]->(IP {is_vpn})
(Customer)-[:HAS_CONTACT]->(Contact {key: "kind|value", kind: phone|email|address})
```
One `SENT_TO` per transaction (never aggregated), so every hop keeps its own time and amount.
Shared attributes are nodes (`Contact`, `Device`, `IP`), so "shares a phone" is a 2-hop pattern.

## Files
| File | Purpose |
|---|---|
| 00_export_from_snowflake_bao.sql | Snowflake export of nodes and edges to CSV (author: Duy Bao Cao) |
| 01_load_snowflake_export.cypher | Constraints + `LOAD CSV`; clears the graph first (re-runnable) |
| 02_p1_naive_video_style.cypher | Cycle query that filters only after expanding whole paths. **Did not finish in 90 s** |
| 03_p1_cycles_pruned.cypher | Cycles closing on the origin, pruned during expansion (anchored on the first hop) |
| 04_p1p2_rings_tiers.cypher | P1 + P2: rings closing on the origin or on an identity-linked account, tiered, de-duplicated |
| 05_visualise_high_rings.cypher | Neo4j Browser picture of high rings (shared device / shared phone) |
| 06_layering.cypher | Open chains of 4+ hops, maximal, excluding rings |
| 07_mule.cypher | Devices shared by 3+ recently onboarded customers |
| 08_visual_examples.cypher | Pictures: one phone-linked ring, one mule ring, one plain cycle |

## Results (generator seed 42, small: 50,012 transactions)
| | Snowflake SQL | Cypher (naive) | Cypher (pruned) |
|---|---|---|---|
| Rings (high / medium) | 13 / 6 | did not finish | 13 / 6 |
| Layering chains | 18 | — | 18 |
| Mule rings | 9 | — | 9 |
| Time to find rings | ~1.8 s (X-Small warehouse) | > 90 s | ~2–3 s (laptop) |

Timings are not directly comparable (cloud warehouse vs local Docker). The point is that
both need pruning during traversal; without it the graph engine does not finish either.
The graph has no cash transactions, so the mule query uses recent onboarding as the
behavioural signal; the pass-through (cash-out) check lives in the Snowflake detector.

## Run locally
```bash
docker run -d --name aml-neo4j -p 7474:7474 -p 7687:7687 -e NEO4J_AUTH=neo4j/<password> -v aml_neo4j_data:/data neo4j:5
docker cp <csv folder>/. aml-neo4j:/var/lib/neo4j/import/
docker exec aml-neo4j cypher-shell -u neo4j -p <password> -f /var/lib/neo4j/import/01_load_snowflake_export.cypher
```
Then open http://localhost:7474 and run the query files.
