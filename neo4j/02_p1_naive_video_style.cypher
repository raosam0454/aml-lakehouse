MATCH p = (a:Account)-[:SENT_TO]->{3,6}(a)
WITH p, relationships(p) AS r
WHERE all(i IN range(0, size(r)-2) WHERE
      r[i+1].ts > r[i].ts AND r[i+1].ts <= r[i].ts + duration('PT48H') AND
      r[i+1].amount <= r[i].amount AND r[i+1].amount >= 0.8 * r[i].amount)
RETURN count(*) AS cycles;
