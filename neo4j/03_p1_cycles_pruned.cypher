MATCH (a:Account)-[r0:SENT_TO]->(b:Account)
MATCH p = (b) ((x:Account)-[r:SENT_TO]->(y:Account)
              WHERE r.ts > r0.ts AND r.ts <= r0.ts + duration('P14D')
                AND r.amount <= r0.amount AND r.amount >= 0.2 * r0.amount){2,7} (a)
WITH a, r0, [r0] + relationships(p) AS rs
WHERE all(i IN range(0, size(rs)-2) WHERE
      rs[i+1].ts > rs[i].ts AND rs[i+1].ts <= rs[i].ts + duration('PT48H') AND
      rs[i+1].amount <= rs[i].amount AND rs[i+1].amount >= 0.8 * rs[i].amount)
RETURN count(*) AS cycles, collect(size(rs))[0..20] AS hop_counts;
