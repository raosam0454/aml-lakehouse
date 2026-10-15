// Three pictures for the report / slides. Run ONE block at a time in Neo4j Browser.

// ---- (A) phone_link ring: money does NOT return to the origin account, but to an
//          account whose owner shares the origin owner's phone -> P2 closes the loop
MATCH (a:Account)-[r0:SENT_TO]->(b:Account)
MATCH p = (b) ((x:Account)-[r:SENT_TO]->(y:Account)
              WHERE r.ts > r0.ts AND r.ts <= r0.ts + duration('P14D')
                AND r.amount <= r0.amount AND r.amount >= 0.2 * r0.amount){2,7} (e:Account)
WHERE e <> a
MATCH link = (a)<-[:OWNS]-(:Customer)-[:HAS_CONTACT]->(:Contact {kind:'phone'})<-[:HAS_CONTACT]-(:Customer)-[:OWNS]->(e)
WITH a, b, r0, p, link, [r0] + relationships(p) AS rs
WHERE all(i IN range(0, size(rs)-2) WHERE
      rs[i+1].ts > rs[i].ts AND rs[i+1].ts <= rs[i].ts + duration('PT48H') AND
      rs[i+1].amount <= rs[i].amount AND rs[i+1].amount >= 0.8 * rs[i].amount)
RETURN a, r0, b, p, link
LIMIT 1;

// ---- (B) mule ring: one device, >= 3 recently onboarded customers
MATCH (d:Device)<-[:USED_DEVICE]-(a:Account)<-[:OWNS]-(c:Customer)
WHERE c.onboard_dt >= date('2026-01-01') - duration('P150D')
WITH d, collect(DISTINCT c) AS cs
WHERE size(cs) >= 3
WITH d, cs LIMIT 1
MATCH ring = (d)<-[:USED_DEVICE]-(:Account)<-[:OWNS]-(c:Customer)
WHERE c IN cs
RETURN ring;

// ---- (C) the same money cycle seen two ways: just one plain (medium) cycle
MATCH (a:Account)-[r0:SENT_TO]->(b:Account)
MATCH p = (b) ((x:Account)-[r:SENT_TO]->(y:Account)
              WHERE r.ts > r0.ts AND r.ts <= r0.ts + duration('P14D')
                AND r.amount <= r0.amount AND r.amount >= 0.2 * r0.amount){2,7} (a)
WITH a, b, r0, p, [r0] + relationships(p) AS rs
WHERE all(i IN range(0, size(rs)-2) WHERE
      rs[i+1].ts > rs[i].ts AND rs[i+1].ts <= rs[i].ts + duration('PT48H') AND
      rs[i+1].amount <= rs[i].amount AND rs[i+1].amount >= 0.8 * rs[i].amount)
RETURN a, r0, b, p
LIMIT 1;
