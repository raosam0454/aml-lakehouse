// Naive cycle query (as in the Neo4j demo video): expands every 3-6 hop path first and
// applies the P1 rules afterwards. Kept for the timing comparison: it does not finish
// within 90 s on 50k transactions. Do not run in Neo4j Browser.
MATCH p = (a:Account)-[:SENT_TO]->{3,6}(a)
WITH p, relationships(p) AS r
WHERE all(i IN range(0, size(r)-2) WHERE
      r[i+1].ts > r[i].ts AND r[i+1].ts <= r[i].ts + duration('PT48H') AND
      r[i+1].amount <= r[i].amount AND r[i+1].amount >= 0.8 * r[i].amount)
RETURN count(*) AS cycles;
