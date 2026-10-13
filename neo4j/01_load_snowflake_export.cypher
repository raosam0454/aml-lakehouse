// Load the graph from Bao's Snowflake export (CURATED -> CSV -> Neo4j).
// Files: nodes_*.csv / edges_*.csv, copied into the container's import folder.
// Re-runnable: clears the graph first (the CSVs are the source of truth).

MATCH (n) CALL (n) { DETACH DELETE n } IN TRANSACTIONS OF 5000 ROWS;

CREATE CONSTRAINT customer_id IF NOT EXISTS FOR (c:Customer) REQUIRE c.id IS UNIQUE;
CREATE CONSTRAINT account_id  IF NOT EXISTS FOR (a:Account)  REQUIRE a.id IS UNIQUE;
CREATE CONSTRAINT device_id   IF NOT EXISTS FOR (d:Device)   REQUIRE d.id IS UNIQUE;
CREATE CONSTRAINT ip_id       IF NOT EXISTS FOR (i:IP)       REQUIRE i.id IS UNIQUE;
CREATE CONSTRAINT contact_key IF NOT EXISTS FOR (k:Contact)  REQUIRE k.key IS UNIQUE;

// ---------- nodes ----------
LOAD CSV WITH HEADERS FROM 'file:///nodes_customer.csv' AS r
CREATE (:Customer {id: r.customer_id, type: r.customer_type, risk_rating: r.risk_rating,
                   kyc_status: r.kyc_status, onboard_dt: date(r.onboard_dt), status: r.status});

LOAD CSV WITH HEADERS FROM 'file:///nodes_account.csv' AS r
CREATE (:Account {id: r.account_id, customer_id: r.customer_id, type: r.account_type,
                  branch: r.branch_code, status: r.status});

LOAD CSV WITH HEADERS FROM 'file:///nodes_device.csv' AS r
CREATE (:Device {id: r.device_id, type: r.device_type, os: r.os});

LOAD CSV WITH HEADERS FROM 'file:///nodes_ip.csv' AS r
CREATE (:IP {id: r.ip_id, address: r.ip_address, country: r.country, is_vpn: toLower(r.is_vpn) = 'true'});

LOAD CSV WITH HEADERS FROM 'file:///nodes_contact.csv' AS r
CREATE (:Contact {key: r.contact_key, kind: r.kind, value: r.value});

// ---------- relationships ----------
LOAD CSV WITH HEADERS FROM 'file:///edges_owns.csv' AS r
MATCH (c:Customer {id: r.customer_id}), (a:Account {id: r.account_id})
CREATE (c)-[:OWNS]->(a);

// one SENT_TO per transaction (never aggregated)
LOAD CSV WITH HEADERS FROM 'file:///edges_sent_to.csv' AS r
CALL (r) {
  MATCH (s:Account {id: r.src_account_id}), (d:Account {id: r.dst_account_id})
  CREATE (s)-[:SENT_TO {txn_id: r.transaction_id, amount: toFloat(r.amount),
                        ts: localdatetime(r.txn_time), channel: r.channel,
                        device_id: r.device_id, ip_id: r.ip_id}]->(d)
} IN TRANSACTIONS OF 5000 ROWS;

LOAD CSV WITH HEADERS FROM 'file:///edges_used_device.csv' AS r
MATCH (a:Account {id: r.account_id}), (d:Device {id: r.device_id})
CREATE (a)-[:USED_DEVICE {sessions: toInteger(r.session_count),
                          first_seen: localdatetime(r.first_seen), last_seen: localdatetime(r.last_seen)}]->(d);

LOAD CSV WITH HEADERS FROM 'file:///edges_used_ip.csv' AS r
MATCH (a:Account {id: r.account_id}), (i:IP {id: r.ip_id})
CREATE (a)-[:USED_IP {sessions: toInteger(r.session_count),
                      first_seen: localdatetime(r.first_seen), last_seen: localdatetime(r.last_seen)}]->(i);

LOAD CSV WITH HEADERS FROM 'file:///edges_has_contact.csv' AS r
MATCH (c:Customer {id: r.customer_id}), (k:Contact {key: r.contact_key})
CREATE (c)-[:HAS_CONTACT]->(k);
