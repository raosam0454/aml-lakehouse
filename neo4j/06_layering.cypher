// Layering (P1 open chains): >= 4 hops, time-ordered, decaying, NOT closing.
// Paths that close (on the origin, or on an account sharing a phone/email/device with
// the origin) are round-trips (see 04); every open path overlapping one is dropped,
// and only maximal chains are kept.
MATCH (a:Account)-[r0:SENT_TO]->(b:Account)
MATCH p = (b) ((x:Account)-[r:SENT_TO]->(y:Account)
              WHERE r.ts > r0.ts AND r.ts <= r0.ts + duration('P16D')
                AND r.amount <= r0.amount AND r.amount >= 0.17 * r0.amount){2,7} (e:Account)
WITH a, e, [r0] + relationships(p) AS rs
WHERE all(i IN range(0, size(rs)-2) WHERE
      rs[i+1].ts > rs[i].ts AND rs[i+1].ts <= rs[i].ts + duration('PT48H') AND
      rs[i+1].amount <= rs[i].amount AND rs[i+1].amount >= 0.8 * rs[i].amount)
WITH [x IN rs | x.txn_id] AS txns,
     e = a
     OR EXISTS { (a)<-[:OWNS]-(:Customer)-[:HAS_CONTACT]->(k:Contact)<-[:HAS_CONTACT]-(:Customer)-[:OWNS]->(e) WHERE k.kind IN ['phone','email'] }
     OR EXISTS { (a)-[:USED_DEVICE]->(:Device)<-[:USED_DEVICE]-(e) } AS closes
WITH collect({txns: txns, closes: closes}) AS paths
WITH paths, [q IN paths WHERE q.closes | q.txns] AS rings
UNWIND paths AS q
WITH q, paths, rings
WHERE NOT q.closes AND size(q.txns) >= 4
  AND none(o IN paths WHERE size(o.txns) > size(q.txns) AND all(t IN q.txns WHERE t IN o.txns))
  AND none(ring IN rings WHERE any(t IN q.txns WHERE t IN ring))
RETURN count(*) AS layering_chains, collect(size(q.txns)) AS hop_counts;
