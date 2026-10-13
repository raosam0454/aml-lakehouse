// P1 + P2: cycles that close on the origin account OR on an account linked to the origin
// by a strong identity (same phone/email contact, or same device); tier = high if any P2 link
MATCH (a:Account)-[r0:SENT_TO]->(b:Account)
MATCH p = (b) ((x:Account)-[r:SENT_TO]->(y:Account)
              WHERE r.ts > r0.ts AND r.ts <= r0.ts + duration('P14D')
                AND r.amount <= r0.amount AND r.amount >= 0.2 * r0.amount){2,7} (e:Account)
WHERE e = a
   OR EXISTS { (a)<-[:OWNS]-(:Customer)-[:HAS_CONTACT]->(k:Contact)<-[:HAS_CONTACT]-(:Customer)-[:OWNS]->(e) WHERE k.kind IN ['phone','email'] }
   OR EXISTS { (a)-[:USED_DEVICE]->(:Device)<-[:USED_DEVICE]-(e) }
WITH a, e, [r0] + relationships(p) AS rs, [a, b] + nodes(p)[1..] AS ns
WHERE all(i IN range(0, size(rs)-2) WHERE
      rs[i+1].ts > rs[i].ts AND rs[i+1].ts <= rs[i].ts + duration('PT48H') AND
      rs[i+1].amount <= rs[i].amount AND rs[i+1].amount >= 0.8 * rs[i].amount)
WITH a, e, rs, ns,
     CASE WHEN e = a THEN 'same_account' ELSE 'linked' END AS closed_by,
     [x IN rs | x.txn_id] AS txn_ids
// P2 inside the ring: any two members sharing a device or a phone/email
WITH a, e, rs, ns, closed_by, txn_ids,
     EXISTS { MATCH (m1:Account)-[:USED_DEVICE]->(:Device)<-[:USED_DEVICE]-(m2:Account)
              WHERE m1 IN ns AND m2 IN ns AND m1 <> m2 } AS shared_device
WITH txn_ids, closed_by, size(rs) AS hops,
     CASE WHEN closed_by = 'linked' OR shared_device THEN 'high' ELSE 'medium' END AS tier,
     [n IN ns | n.id] AS path
// keep only maximal rings (drop rings whose txns are a subset of a bigger ring)
WITH collect({txn_ids: txn_ids, closed_by: closed_by, hops: hops, tier: tier, path: path}) AS all_rings
UNWIND all_rings AS ring
WITH ring, all_rings
WHERE none(o IN all_rings WHERE size(o.txn_ids) > size(ring.txn_ids) AND all(t IN ring.txn_ids WHERE t IN o.txn_ids))
RETURN ring.closed_by AS closed_by, ring.tier AS tier, count(*) AS rings;
