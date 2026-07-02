<!-- nosql-patterns: NoSQL Foundations — CAP, PACELC, BASE, Data Models -->

# NoSQL Foundations — CAP, PACELC, BASE, Data Models

## Why NoSQL matters to a Data Engineer

DEs encounter NoSQL as **data sources** (ingesting from DynamoDB, MongoDB, Cassandra), as **targets** (writing to Redis caches), and in design conversations (choosing the right store for a new pipeline). You do not need to be a NoSQL admin, but you must know the theory, the tradeoffs, and the DE-specific gotchas.

---

## CAP Theorem

**Definition:** A distributed data store can provide at most **two of three** properties simultaneously:

| Property | Meaning |
|----------|---------|
| **Consistency (C)** | Every read returns the most recent committed write or an error — *linearizability*, not ACID consistency |
| **Availability (A)** | Every request receives a non-error response (may not be the most recent write) |
| **Partition Tolerance (P)** | System continues operating despite network message loss/delay between nodes |

**The key insight:** Network partitions *will* happen in production. P is therefore mandatory. The real choice is: **during a partition, sacrifice C or A?**

- **CP systems:** Refuse requests on the minority side to guarantee consistency. Examples: ZooKeeper, HBase, etcd, MongoDB (with `w:majority`).
- **AP systems:** Keep accepting writes on both partition sides; reconcile after healing. Examples: Cassandra, DynamoDB (default), CouchDB.

---

## PACELC — The More Complete Model (Abadi, 2012)

CAP only covers the failure case. PACELC adds **normal-operation behavior**:

> "If there is a **P**artition, trade off **A**vailability vs. **C**onsistency. **E**lse (no partition), trade off **L**atency vs. **C**onsistency."

Strong consistency requires quorum reads (multiple round-trips = higher latency) even when the network is healthy.

| System | Partition behavior | Normal behavior | Classification |
|--------|-------------------|----------------|----------------|
| DynamoDB (default) | Available | Low latency | **PA/EL** |
| Cassandra | Available | Low latency | **PA/EL** |
| MongoDB (default) | Available | Low latency | **PA/EL** |
| MongoDB (`w:majority`) | Consistent | Higher latency | **PC/EC** |
| Google Spanner | Consistent | Higher latency | **PC/EC** |
| HBase | Consistent | Higher latency | **PC/EC** |

**Interview tip:** CAP tells you what breaks under failure. PACELC tells you the latency cost you pay in normal operation for strong consistency.

---

## ACID vs BASE

### ACID (relational DBs, some NoSQL with transactions)

| Letter | Property | Concrete meaning |
|--------|----------|-----------------|
| **A** | Atomicity | Multi-step transaction commits fully or rolls back entirely |
| **C** | Consistency | Every committed transaction satisfies all defined integrity constraints |
| **I** | Isolation | Concurrent transactions behave as if serialized (read/write locks or MVCC) |
| **D** | Durability | Committed transactions survive crashes via write-ahead log (WAL) |

**Cost:** Coordination overhead (locking, 2PC for distributed transactions) limits horizontal scale.

### BASE (most NoSQL systems)

| Letter | Property | Concrete meaning |
|--------|----------|-----------------|
| **B** | Basically Available | Every request gets a response, possibly stale or partial |
| **S** | Soft State | State may change over time due to eventual consistency propagation, even without new writes |
| **E** | Eventually Consistent | Given no new writes, all replicas converge to the same value — milliseconds to seconds in healthy systems |

**Concrete example (DynamoDB):** A read immediately after a write may return the old value with default eventually consistent reads. `ConsistentRead=True` forces a read from the leader — correct, but costs 2× RCUs.

**Modern nuance:** The line is blurring. DynamoDB supports ACID multi-item transactions (`TransactWriteItems`, up to 100 items). MongoDB 4.0+ supports multi-document ACID transactions. These features opt back toward PC/EC behavior at a latency cost.

---

## The Four NoSQL Data Models

### 1. Key-Value

**Data layout:** Giant hash map. `key → opaque bytes`. No schema on the value.

**Query:** O(1) get/put by exact key only. No range scans, no querying inside the value.

**Examples:** Redis, DynamoDB (core model), Riak, Memcached.

**When to use:** Sessions, caches, rate-limit counters, feature flags, distributed locks — any pattern where you always know the exact key.

**DE angle:** DynamoDB is fundamentally a key-value store even though it supports sort keys and indexes. Understanding this shapes partition key design.

---

### 2. Document

**Data layout:** Each record is a self-describing document (JSON/BSON). Fields vary per document. Nested objects and arrays are native. No foreign keys — related data is embedded or referenced by ID.

**Query:** Rich query on any field (with appropriate indexes). Aggregation pipelines for complex transformations. No server-side joins — embed or do application-level joins.

**Examples:** MongoDB, Couchbase, Firestore, Amazon DocumentDB.

**When to use:** Product catalogs with variable attributes, user profiles, content management, REST API backends where API response = document.

**DE angle:** MongoDB's aggregation pipeline is a powerful ETL tool. Change streams enable CDC. Schema flexibility is a double-edged sword — without validation, data quality degrades.

---

### 3. Wide-Column (Column-Family)

**Data layout:** Two-level sorted map: `row_key → { column_key → value }`. Each row can have a different set of columns. Data is physically sorted by row key, then column key — enabling efficient range scans within a partition.

**Query:** Fast reads by partition key. Range scans on clustering columns within a partition are cheap. Cross-partition queries require full table scans — expensive and avoided by design.

**Examples:** Apache Cassandra, HBase, Google Bigtable, ScyllaDB.

**When to use:** Time-series (device + timestamp PK), write-heavy workloads (IoT, event logs), high-throughput analytics reads, geographically distributed data. Write throughput scales linearly: 3 nodes ≈ 3,000 writes/s; 6 nodes ≈ 6,000 writes/s.

**DE angle:** Cassandra is the standard for IoT and telemetry pipelines. Partition key + clustering key design is the core skill.

---

### 4. Graph

**Data layout:** Nodes (entities with properties) and edges (relationships with properties and direction). Relationships are first-class citizens stored with data, not computed at query time via joins.

**Query:** Traversals (multi-hop relationship queries) are O(depth), not O(table size). Poor at aggregations across all nodes.

**Examples:** Neo4j, Amazon Neptune, TigerGraph, JanusGraph.

**When to use:** Social graphs, fraud detection (transaction networks), recommendation engines, knowledge graphs, network topology.

**DE angle:** Less common in core DE pipelines but critical for graph-shaped analytical workloads. Neptune integrates with AWS Glue and S3 for bulk loading.

---

## SQL vs NoSQL — Decision Framework

```
START HERE:
  ├─ Need ACID multi-table transactions?                → Relational SQL
  ├─ Flexible schema with rich per-document queries?   → Document (MongoDB)
  ├─ Extreme write throughput + time-series?           → Wide-column (Cassandra, Bigtable)
  ├─ Sub-millisecond key lookup or caching?            → Key-value (Redis, DynamoDB)
  ├─ Multi-hop relationship traversals?                → Graph (Neo4j, Neptune)
  └─ Large-scale OLAP/analytics?                       → Column-oriented SQL (Snowflake, BigQuery, Redshift)
```

| Criterion | SQL wins | NoSQL wins |
|-----------|---------|-----------|
| Schema stability | Frequent joins across normalized tables | Variable schema per record |
| Consistency requirement | Strong consistency needed everywhere | Eventually consistent is acceptable |
| Query patterns known | Complex ad-hoc queries with joins | Predictable access patterns, known keys |
| Scale | Vertical scale is sufficient | Horizontal scale needed (>1 TB, >10k writes/s) |
| Transactions | Multi-table, multi-row ACID needed | Single-record or limited transactions |

---

## Schema-on-Read vs Schema-on-Write

| | Schema-on-Write | Schema-on-Read |
|---|---|---|
| When validated | At ingest time | At query time |
| Examples | Postgres, MySQL, DynamoDB with validation | MongoDB (default), S3 + Athena, Hive |
| Pros | Fast reads, guaranteed quality, catches errors early | Flexible, ingest speed, multiple schemas on same data |
| Cons | Rigid — schema changes need migrations | Slow queries, silent data quality failures |

**Modern SQL blur:** Postgres `jsonb`, Snowflake `VARIANT`, BigQuery `JSON` store semi-structured data inside relational columns — schema-on-read within a schema-on-write system.

**Choosing:**
- Most fields structured, a few variable → SQL + JSON column (`jsonb`, `VARIANT`)
- Entire record semi-structured, schema varies significantly → Document DB (MongoDB)
- Volume too large for transactional stores, flexible exploration needed → Data lake (S3 + Athena/Spark)

---

*Next: [63-nosql-key-systems.md](63-nosql-key-systems.md) — DynamoDB, MongoDB, Cassandra deep dives*
