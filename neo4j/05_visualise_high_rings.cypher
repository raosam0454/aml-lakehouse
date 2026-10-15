// Neo4j Browser picture of the HIGH rings only (13): money cycle (P1) plus the shared identity (P2)
// that confirms it - the phone/email link that closes the loop, or members sharing a device/contact.
MATCH (a:Account)-[r0:SENT_TO]->(b:Account)
MATCH p = (b) ((x:Account)-[r:SENT_TO]->(y:Account)
              WHERE r.ts > r0.ts AND r.ts <= r0.ts + duration('P14D')
                AND r.amount <= r0.amount AND r.amount >= 0.2 * r0.amount){2,7} (e:Account)
WHERE e = a
   OR EXISTS { (a)<-[:OWNS]-(:Customer)-[:HAS_CONTACT]->(k:Contact)<-[:HAS_CONTACT]-(:Customer)-[:OWNS]->(e) WHERE k.kind IN ['phone','email'] }
   OR EXISTS { (a)-[:USED_DEVICE]->(:Device)<-[:USED_DEVICE]-(e),
                  (a)<-[:OWNS]-(c1:Customer), (e)<-[:OWNS]-(c2:Customer) WHERE c1 <> c2 }
WITH a, r0, p, e, [r0] + relationships(p) AS rs
WHERE all(i IN range(0, size(rs)-2) WHERE
      rs[i+1].ts > rs[i].ts AND rs[i+1].ts <= rs[i].ts + duration('PT48H') AND
      rs[i+1].amount <= rs[i].amount AND rs[i+1].amount >= 0.8 * rs[i].amount)
// keep only maximal rings
WITH collect({a: a, r0: r0, p: p, e: e, txns: [x IN rs | x.txn_id]}) AS all_rings
UNWIND all_rings AS ring
WITH ring, all_rings
WHERE none(o IN all_rings WHERE size(o.txns) > size(ring.txns) AND all(t IN ring.txns WHERE t IN o.txns))
WITH ring.a AS a, ring.r0 AS r0, ring.p AS p, ring.e AS e, nodes(ring.p) + [ring.a] AS ns
// identity evidence: the link that closes the loop, and members of different customers sharing an identity
OPTIONAL MATCH link = (a)<-[:OWNS]-(:Customer)-[:HAS_CONTACT]->(k:Contact)<-[:HAS_CONTACT]-(:Customer)-[:OWNS]->(e)
  WHERE e <> a AND k.kind IN ['phone','email']
OPTIONAL MATCH dev = (c1:Customer)-[:OWNS]->(m1:Account)-[:USED_DEVICE]->(:Device)<-[:USED_DEVICE]-(m2:Account)<-[:OWNS]-(c2:Customer)
  WHERE m1 IN ns AND m2 IN ns AND c1 <> c2 AND elementId(m1) < elementId(m2)
OPTIONAL MATCH con = (m3:Account)<-[:OWNS]-(c3:Customer)-[:HAS_CONTACT]->(k2:Contact)<-[:HAS_CONTACT]-(c4:Customer)-[:OWNS]->(m4:Account)
  WHERE k2.kind IN ['phone','email'] AND m3 IN ns AND m4 IN ns AND c3 <> c4 AND elementId(m3) < elementId(m4)
WITH a, r0, p, e, collect(DISTINCT link) + collect(DISTINCT dev) + collect(DISTINCT con) AS evidence
WHERE size(evidence) > 0
RETURN a, r0, p, evidence;
