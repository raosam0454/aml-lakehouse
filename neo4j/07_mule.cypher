// Mule ring (P2): one device used by accounts of >= 3 different customers who were
// onboarded recently. (Cash withdrawals are not in the graph, so the pass-through
// behaviour check lives in the Snowflake detector; here recency is the behaviour proxy.)
MATCH (d:Device)<-[:USED_DEVICE]-(a:Account)<-[:OWNS]-(c:Customer)
WHERE c.onboard_dt >= date('2026-01-01') - duration('P150D')
WITH d, collect(DISTINCT c.id) AS customers, collect(DISTINCT a.id) AS accounts
WHERE size(customers) >= 3
RETURN count(*) AS mule_rings, sum(size(accounts)) AS accounts_flagged;
