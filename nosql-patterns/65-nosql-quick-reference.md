<!-- nosql-patterns: NoSQL Quick Reference — Interview Q&A + Cheat Sheets -->

# NoSQL Quick Reference — Interview Q&A + Cheat Sheets

## Common Interview Questions

### Q1: What is CAP theorem and why does partition tolerance matter?

**Answer:** CAP states a distributed store can guarantee at most two of: Consistency (every read returns latest write), Availability (every request gets a response), and Partition Tolerance (operates despite network failures). Since network partitions are unavoidable in production, P is mandatory — the real tradeoff is C vs A during a partition. CP systems (HBase, Zookeeper) refuse requests on the minority side to stay consistent. AP systems (Cassandra, DynamoDB) accept writes on both sides and reconcile later. PACELC extends CAP: even without partitions, strong consistency costs latency (quorum round-trips), so you're always trading L vs C.

---

### Q2: When would you choose NoSQL over SQL for a data pipeline?

**Answer:** Choose NoSQL when: (1) Write throughput exceeds what a single SQL node handles (Cassandra for IoT, >10k writes/s), (2) Schema varies significantly per record and is unknown upfront (MongoDB for product catalogs), (3) Access patterns are known and simple — always by exact key (DynamoDB for user sessions), (4) Sub-millisecond latency is required (Redis for caching). Choose SQL when: ad-hoc complex queries with joins are needed, multi-table ACID transactions are required, or the data is analytical (use columnar SQL: Snowflake, BigQuery).

---

### Q3: How would you ingest data from DynamoDB into a data warehouse in real-time?

**Answer:** Enable DynamoDB Streams with `NEW_AND_OLD_IMAGES` view type. For real-time with >24h retention, use `EnableKinesisStreamingDestination` to route stream to Kinesis Data Streams. Attach a Kinesis Firehose to write to S3 (parquet), then load to Redshift/Snowflake via COPY or auto-ingest. Alternatively, Lambda event source mapping for simpler setups. The DynamoDB JSON typed format (`{"S": "value"}`) must be deserialized to flat schema using `boto3.dynamodb.types.TypeDeserializer` before loading. For initial backfill, use `ExportTableToPointInTime` to S3 — it doesn't consume read capacity.

---

### Q4: What is Cassandra's partition key and why is it critical?

**Answer:** The partition key determines which node(s) store a row via consistent hashing. All rows with the same partition key are co-located on disk and in the same node(s). Every CQL query MUST include the full partition key in the WHERE clause — otherwise Cassandra scans all partitions (requires `ALLOW FILTERING`, never in production). A bad partition key with low cardinality creates hot partitions. A good partition key distributes writes evenly AND matches your most common query access pattern. Clustering columns come after the partition key and physically sort rows within a partition — they enable cheap range scans.

---

### Q5: What are DynamoDB hot partitions and how do you fix them?

**Answer:** Hot partitions occur when the partition key has low cardinality or sequential values, routing disproportionate traffic to one shard. Each partition handles max 3,000 RCU/s and 1,000 WCU/s. Fixes: (1) Write sharding — append a random/hash suffix to the PK, spreading writes across N partitions, then scatter-gather reads across all N; (2) Calendar bucketing — `PK = "DEVICE#<id>#YYYY-MM"` bounds growth; (3) For status-based GSIs, avoid `status` as GSI partition key if most items share the same status.

---

### Q6: How does MongoDB Change Streams work for CDC?

**Answer:** Change Streams watch collection/database/deployment for insert/update/delete events. They build on the oplog but expose a clean, resumable cursor. Each event has a resume token — save it before processing each event to restart without re-processing or missing events. The oplog must be sized at 2–3× peak hourly change rate to survive consumer downtime without forcing a full re-snapshot. For production pipelines, route via Debezium MongoDB Connector to Kafka — each collection becomes a topic with `before`/`after` document images. Atlas Triggers eliminate Debezium entirely for Atlas-managed clusters.

---

### Q7: What are tombstones in Cassandra and why are they dangerous?

**Answer:** Cassandra deletes write a tombstone marker rather than removing data immediately. Tombstones accumulate until compaction removes them. A partition with millions of tombstones causes `TombstoneOverwhelmingException` — Cassandra aborts the read to protect the coordinator. Common cause: delete-then-reinsert patterns (e.g., updating a list by deleting and recreating). Fix: avoid deletes if possible; use TTLs instead; choose TWCS compaction for time-series (old windows become immutable, tombstones compact quickly).

---

### Q8: Redis Pub/Sub vs Redis Streams — when to use which?

**Answer:** Pub/Sub is fire-and-forget broadcast with no persistence — messages are lost if no subscriber is listening. Use for real-time notifications where loss is acceptable (live dashboards, presence). Redis Streams are a persistent, consumer-group-based message log (like Kafka). Messages persist until ACKed or trimmed. Consumers can resume from last position after restart. Use Streams when at-least-once delivery, consumer groups, or message replay is needed. For DE pipelines — always prefer Streams over Pub/Sub when reliability matters.

---

### Q9: What is single-table design in DynamoDB?

**Answer:** Single-table design (STD) stores multiple entity types (users, orders, line items) in one DynamoDB table using overloaded PK/SK combinations. Purpose: reduce cost and latency by fetching related data in one `Query` call (single partition) instead of multiple `GetItem` calls. GSI keys are also overloaded — `GSI1PK/GSI1SK` hold different values per entity type to support secondary access patterns. STD requires designing all access patterns upfront — it trades schema readability for query efficiency.

---

### Q10: What is the difference between schema-on-read and schema-on-write in NoSQL context?

**Answer:** Schema-on-write validates data structure at ingest time — bad data is rejected before it lands (MongoDB `$jsonSchema` validator, DynamoDB application-layer validation). Reads are fast because schema is predictable. Schema-on-read stores data as-is and applies schema at query time (default MongoDB, S3+Athena, Hive). Fast ingest, flexible evolution, but silent data quality failures possible. Modern SQL DBs blur the line: Snowflake `VARIANT`, Postgres `jsonb`, and BigQuery `JSON` columns are schema-on-read within a schema-on-write system — store semi-structured JSON in a relational column, query with path expressions.

---

## Numbers Cheat Sheet

| System | Key Metric | Value |
|--------|-----------|-------|
| DynamoDB | Partition capacity (reads) | 3,000 RCU/s per partition |
| DynamoDB | Partition capacity (writes) | 1,000 WCU/s per partition |
| DynamoDB | Partition storage limit | 10 GB (with LSI) |
| DynamoDB | Streams retention | 24 hours (Kinesis export: 7–365 days) |
| DynamoDB | GSI max per table | 20 (soft limit) |
| DynamoDB | LSI max per table | 5 (hard limit, create-time only) |
| DynamoDB | TransactWriteItems max | 100 items |
| Cassandra | Max recommended partition size | ~100 MB (DataStax guidance) |
| Cassandra | Replication factor (typical prod) | 3 |
| Cassandra | Strong consistency formula | W:QUORUM + R:QUORUM with RF=3 |
| MongoDB | Oplog sizing safety factor | 2–3× peak hourly change rate |
| MongoDB | Aggregation stage memory limit | 100 MB (use `allowDiskUse: true` for more) |
| Redis | Single-node throughput | ~100k ops/sec |
| Redis | HyperLogLog error rate | ~0.81% |
| Redis | HyperLogLog memory | Fixed 12 KB regardless of cardinality |
| Redis | AOF fsync `everysec` data loss | Max 1 second |

---

## PACELC Classification

| System | Partition behavior | Normal behavior | Class |
|--------|-------------------|----------------|-------|
| DynamoDB (default) | Available | Low latency | PA/EL |
| Cassandra | Available | Low latency | PA/EL |
| MongoDB (default) | Available | Low latency | PA/EL |
| MongoDB (w:majority) | Consistent | Higher latency | PC/EC |
| Google Spanner | Consistent | Higher latency | PC/EC |
| HBase / etcd | Consistent | Higher latency | PC/EC |
| CockroachDB | Consistent | Higher latency | PC/EC |

---

## Managed Cloud Services Map

| Use Case | System | AWS | GCP | Azure |
|----------|--------|-----|-----|-------|
| Key-value / OLTP | DynamoDB | DynamoDB | — | Cosmos DB (Table API) |
| Document | MongoDB | DocumentDB (≈Mongo 5.0) | Firestore | Cosmos DB (Mongo API) |
| Wide-column / Time-series | Cassandra / Bigtable | Amazon Keyspaces | Cloud Bigtable | Cosmos DB (Cassandra API) |
| Graph | Neo4j / Neptune | Amazon Neptune | — | Cosmos DB (Gremlin API) |
| Cache / Broker | Redis | ElastiCache for Redis | Memorystore | Azure Cache for Redis |
| Multi-model / Global | Cosmos DB | — | — | **Azure Cosmos DB** |

**Notable gotchas:**
- **Amazon DocumentDB ≠ MongoDB internals** — compatible API but Aurora storage engine; subtle differences in aggregation pipeline, change streams, and index behavior
- **Amazon Keyspaces** = managed Cassandra API; `nodetool` commands unavailable; LWT supported
- **Valkey** — Linux Foundation fork of Redis 7.4+ after Redis license changed to SSPL in 2024; drop-in replacement; growing adoption as Redis alternative

---

## NoSQL Decision Tree (Interview Version)

```
What is the primary access pattern?

├─ Always by exact key, no range scans, sub-ms latency needed
│   → Key-Value (DynamoDB, Redis)

├─ Variable schema per record, rich queries on nested fields
│   → Document (MongoDB, Firestore)

├─ High-throughput time-series writes, range scans on time within entity
│   → Wide-Column (Cassandra, Bigtable)

├─ Multi-hop relationship traversals (friends-of-friends, fraud networks)
│   → Graph (Neo4j, Neptune)

├─ Complex ad-hoc SQL queries, multi-table joins, ACID transactions
│   → Relational SQL (Postgres, MySQL)

└─ Large-scale analytics, aggregations across billions of rows
    → Columnar SQL (Snowflake, BigQuery, Redshift)
```

---

## Common DE Interview Red Flags to Avoid

| If asked about... | Don't say | Do say |
|---|---|---|
| Cassandra queries | "You can filter by any column" | "Must include full partition key; ALLOW FILTERING is a table scan" |
| DynamoDB scaling | "Just add more capacity units" | "Check for hot partitions first; capacity units help only if traffic is distributed" |
| MongoDB schema | "MongoDB is schemaless so no modeling needed" | "Schema flexibility is not schema chaos — use validators and design documents around access patterns" |
| Eventually consistent reads | "It's basically consistent" | "Stale reads are possible for seconds; use strongly consistent reads for critical paths, accepting 2× cost" |
| Redis as database | "Redis can replace Postgres" | "Redis is primarily in-memory; use for caching and ephemeral state; persistence modes have recovery limits" |
| NoSQL vs SQL | "NoSQL is always faster" | "NoSQL is faster for known-key access patterns at scale; SQL wins for ad-hoc analytics and complex joins" |

---

*Prev: [64-nosql-redis-and-ingestion.md](64-nosql-redis-and-ingestion.md)*
*NoSQL section: [62](62-nosql-foundations.md) → [63](63-nosql-key-systems.md) → [64](64-nosql-redis-and-ingestion.md) → [65](65-nosql-quick-reference.md)*
