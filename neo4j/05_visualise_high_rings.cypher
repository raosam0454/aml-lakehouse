// Paste into Neo4j Browser (http://localhost:7474) to SEE the high-risk rings as a graph.
// Shows: money cycle (SENT_TO) + the shared device / shared phone that links its members.
// High = cycle (P1) AND a shared identity (P2): members share a device, or the money
// returns to a different account whose owner shares the origin owner's phone.

// 1. money path from origin a, first hop r0, then 2-7 more hops ending at e (coarse pruning)
MATCH (a:Account)-[r0:SENT_TO]->(b:Account)
MATCH p = (b) ((x:Account)-[r:SENT_TO]->(y:Account)
              WHERE r.ts > r0.ts AND r.ts <= r0.ts + duration('P14D')
                AND r.amount <= r0.amount AND r.amount >= 0.2 * r0.amount){2,7} (e:Account)
// 2. closes on the origin, or on an account whose owner shares the origin owner's phone
WHERE e = a
   OR EXISTS { (a)<-[:OWNS]-(:Customer)-[:HAS_CONTACT]->(k:Contact)<-[:HAS_CONTACT]-(:Customer)-[:OWNS]->(e) WHERE k.kind = 'phone' }
// 3. exact P1 rule on every pair of consecutive hops
WITH a, b, r0, p, e, [r0] + relationships(p) AS rs
WHERE all(i IN range(0, size(rs)-2) WHERE
      rs[i+1].ts > rs[i].ts AND rs[i+1].ts <= rs[i].ts + duration('PT48H') AND
      rs[i+1].amount <= rs[i].amount AND rs[i+1].amount >= 0.8 * rs[i].amount)
// 4. P2 evidence inside the ring: pairs of members sharing a device
OPTIONAL MATCH dev = (m1:Account)-[:USED_DEVICE]->(:Device)<-[:USED_DEVICE]-(m2:Account)
WHERE m1 IN nodes(p) + [a] AND m2 IN nodes(p) + [a] AND elementId(m1) < elementId(m2)
WITH a, b, r0, p, e, collect(dev) AS devs
// 5. keep HIGH rings only: shared device inside, or closed through a shared phone
WHERE size(devs) > 0 OR e <> a
WITH a, b, r0, p, e, devs LIMIT 6
// 6. the phone link (only for rings that closed on a different account)
OPTIONAL MATCH link = (a)<-[:OWNS]-(:Customer)-[:HAS_CONTACT]->(:Contact {kind:'phone'})<-[:HAS_CONTACT]-(:Customer)-[:OWNS]->(e)
WHERE e <> a
RETURN a, r0, b, p, devs, link;
