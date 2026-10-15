// All maximal rings (same 19 as 04_p1p2_rings_tiers.cypher) returned as paths for Neo4j Browser.
// 05 and 08 draw only a few examples (LIMIT 6 / LIMIT 1); this one draws every ring.
MATCH (a:Account)-[r0:SENT_TO]->(b:Account)
MATCH p = (b) ((x:Account)-[r:SENT_TO]->(y:Account)
              WHERE r.ts > r0.ts AND r.ts <= r0.ts + duration('P14D')
                AND r.amount <= r0.amount AND r.amount >= 0.2 * r0.amount){2,7} (e:Account)
WHERE e = a
   OR EXISTS { (a)<-[:OWNS]-(:Customer)-[:HAS_CONTACT]->(k:Contact)<-[:HAS_CONTACT]-(:Customer)-[:OWNS]->(e) WHERE k.kind IN ['phone','email'] }
   OR EXISTS { (a)-[:USED_DEVICE]->(:Device)<-[:USED_DEVICE]-(e) }
WITH a, r0, p, e, [r0] + relationships(p) AS rs
WHERE all(i IN range(0, size(rs)-2) WHERE
      rs[i+1].ts > rs[i].ts AND rs[i+1].ts <= rs[i].ts + duration('PT48H') AND
      rs[i+1].amount <= rs[i].amount AND rs[i+1].amount >= 0.8 * rs[i].amount)
WITH collect({a: a, r0: r0, p: p, e: e, txns: [x IN rs | x.txn_id]}) AS all_rings
UNWIND all_rings AS ring
WITH ring, all_rings
WHERE none(o IN all_rings WHERE size(o.txns) > size(ring.txns) AND all(t IN ring.txns WHERE t IN o.txns))
WITH ring.a AS a, ring.r0 AS r0, ring.p AS p, ring.e AS e
// identity evidence: the phone/email link that closes the loop, and shared devices inside the ring
OPTIONAL MATCH link = (a)<-[:OWNS]-(:Customer)-[:HAS_CONTACT]->(k:Contact)<-[:HAS_CONTACT]-(:Customer)-[:OWNS]->(e)
  WHERE e <> a AND k.kind IN ['phone','email']
OPTIONAL MATCH dev = (m1:Account)-[:USED_DEVICE]->(:Device)<-[:USED_DEVICE]-(m2:Account)
  WHERE m1 IN nodes(p) + [a] AND m2 IN nodes(p) + [a] AND elementId(m1) < elementId(m2)
RETURN a, r0, p, collect(DISTINCT link) AS links, collect(DISTINCT dev) AS devices;
