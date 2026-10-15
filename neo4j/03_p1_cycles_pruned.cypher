// P1 cycles closing on the origin, pruned during expansion. Anchored on the first hop r0;
// inner WHERE uses safe bounds relative to r0 (7 hops x 48h = 14 days, 0.8^7 ~ 0.2 of the
// amount), then the exact hop-by-hop rule (later, <= 48h, 80-100%) is checked on the path.
MATCH (a:Account)-[r0:SENT_TO]->(b:Account)
MATCH p = (b) ((x:Account)-[r:SENT_TO]->(y:Account)
              WHERE r.ts > r0.ts AND r.ts <= r0.ts + duration('P14D')
                AND r.amount <= r0.amount AND r.amount >= 0.2 * r0.amount){2,7} (a)
WITH a, r0, [r0] + relationships(p) AS rs
WHERE all(i IN range(0, size(rs)-2) WHERE
      rs[i+1].ts > rs[i].ts AND rs[i+1].ts <= rs[i].ts + duration('PT48H') AND
      rs[i+1].amount <= rs[i].amount AND rs[i+1].amount >= 0.8 * rs[i].amount)
RETURN count(*) AS cycles, collect(size(rs))[0..20] AS hop_counts;
