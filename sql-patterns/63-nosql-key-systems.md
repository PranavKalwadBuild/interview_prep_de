# NoSQL Key Systems — DynamoDB, MongoDB, Cassandra (DE Perspective)

## DynamoDB

### Core Concepts

DynamoDB is fundamentally a **key-value store** with a sort key extension. Every access pattern must be designed around the primary key — no ad-hoc joins, no full-table scans in production.

**Primary key anatomy:**
```
Simple PK:     PK (partition key only)
Composite PK:  PK (partition key) + SK (sort key)
```

Every item is identified by `(PK, SK)`. All items with the same `PK` are stored together on the same physical partition, sorted by `SK`.

### Partition Key Design and Hot Partitions

Each DynamoDB partition handles: **3,000 RCU/s, 1,000 WCU/s, 10 GB** (with LSIs). A bad partition key routes all traffic to one partition, hitting these ceilings.

**Classic hot partition anti-patterns:**
- `PK = current_date` → all today's writes hit one partition
- `PK = sequential integer` → ascending keys hash to same partition under load
- Low-cardinality GSI partition key (`status = "ACTIVE"` → one hot shard)

**Write sharding strategies:**

```
N = ceil(peak_writes_per_second / 1000)   # number of shards needed

Strategy 1 — random suffix:
  PK = "EVENT#2024-01-15#" + random(0..N)
  Pro: perfect write distribution
  Con: N parallel reads needed to reconstruct all events for a date

Strategy 2 — calculated hash:
  PK = "DEVICE#" + device_id + "#" + (hash(event_id) % N)
  Pro: O(1) GetItem (compute shard from ID)
  Con: must know N at design time

Strategy 3 — calendar buckets (time-series):
  PK = "DEVICE#" + device_id + "#" + "YYYY-MM"
  Pro: natural bounded growth per partition
  Con: current month is still a hot partition
```

### Single-Table Design (STD)

STD stores multiple entity types in one table using overloaded keys. Example for an e-commerce app:

```
PK               SK                   Data
USER#123         METADATA             { name, email, created_at }
USER#123         ORDER#2024-001       { amount, status }
USER#123         ORDER#2024-002       { amount, status }
ORDER#2024-001   LINEITEM#1           { sku, qty, price }
ORDER#2024-001   LINEITEM#2           { sku, qty, price }
```

**Why STD:** DynamoDB charges per request. Fetching a user + their last 5 orders with one `Query` (single partition) is cheaper and faster than 6 separate `GetItem` calls.

**Access pattern design process:**
1. List all access patterns upfront
2. Assign PK/SK combinations to serve each pattern
3. Use GSIs with overloaded keys for secondary patterns

### GSI vs LSI

| | GSI (Global Secondary Index) | LSI (Local Secondary Index) |
|---|---|---|
| Partition key | Any attribute | Must match base table PK |
| Read consistency | Eventually consistent only | Strongly consistent available |
| Add after creation | Yes | No — create-time only |
| Item collection limit | None | 10 GB per partition key |
| Max per table | 20 (soft limit) | 5 (hard limit) |

**Rule:** Default to GSI. Use LSI only when you need strongly consistent reads on an alternate sort order AND per-PK items stay under 10 GB.

### DynamoDB Streams and CDC

Streams capture a 24-hour change log of item-level mutations (INSERT, MODIFY, REMOVE).

**Stream view types:**
- `KEYS_ONLY` — only PK/SK of changed item
- `NEW_IMAGE` — entire item after change
- `OLD_IMAGE` — entire item before change
- `NEW_AND_OLD_IMAGES` — both (use for CDC)

**CDC architectures:**

```
Option A — Lambda Event Source Mapping:
  DynamoDB Stream (24h) → Lambda → S3 / Redshift / Elasticsearch
  Pros: zero infrastructure, native integration
  Cons: 15-min timeout, 6MB payload limit, at-least-once delivery

Option B — Kinesis Data Streams:
  DynamoDB → EnableKinesisStreamingDestination → Kinesis (7–365d retention)
           → Firehose → S3/Redshift
           → KCL / Lambda consumer
  Pros: longer retention, multiple consumers, cross-region fan-out
  Cons: extra configuration

Option C — DynamoDB Export to S3:
  Full or incremental export → S3 (DynamoDB JSON or Ion format)
  Not real-time; use for initial backfills and full snapshots
```

### Scan vs Query Cost

- **`Query`:** Reads only items matching the partition key → targeted, cheap, O(items in partition)
- **`Scan`:** Reads every item in the table → expensive, O(table size) in RCUs

**Rule:** Never scan in production. Offload full-table reads to S3 via Export or Glue ETL.

### Provisioned vs On-Demand

| | Provisioned + Auto Scaling | On-Demand |
|---|---|---|
| Cost at sustained load | Cheaper (~6× lower per RCU/WCU) | Expensive |
| Cost for spiky load | Risk of throttling if under-provisioned | Scales automatically |
| Predictability | Requires capacity planning | Pay per request |

**Rule:** On-demand for unpredictable/bursty workloads. Provisioned + Auto Scaling for predictable throughput patterns.

---

## MongoDB

### Document Model and BSON

MongoDB stores **BSON** (Binary JSON) documents. BSON adds types not in JSON: `Date`, `ObjectId`, `Decimal128`, `Binary`, `Regex`.

**ObjectId** (default `_id`): 12 bytes — 4-byte timestamp + 5-byte random + 3-byte counter. Monotonically increasing within a second but not globally sortable across seconds.

**Embedding vs. referencing:**

```
Embed when:                          Reference (_id) when:
  - Data accessed together             - Sub-doc is large
  - Sub-docs have bounded size         - Frequently updated independently
  - 1:1 or 1:few relationship          - Accessed from multiple parents
  - No independent write on sub-doc    - 1:many (unbounded)
```

**Schema validation** (enforce schema-on-write in MongoDB):

```javascript
db.createCollection("orders", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["user_id", "amount", "status"],
      properties: {
        amount: { bsonType: "decimal", minimum: 0 },
        status: { enum: ["PENDING", "SHIPPED", "DELIVERED"] }
      }
    }
  },
  validationLevel: "strict"   // or "moderate" (only new docs)
})
```

### Aggregation Pipeline

MongoDB's primary ETL engine. Stages execute sequentially, each passing documents to the next.

```javascript
db.orders.aggregate([
  { $match: { status: "DELIVERED", created_at: { $gte: ISODate("2024-01-01") } } },
  { $unwind: "$line_items" },                        // explode array → separate docs
  { $group: {
      _id: "$line_items.sku",
      total_qty:  { $sum: "$line_items.qty" },
      total_rev:  { $sum: { $multiply: ["$line_items.qty", "$line_items.price"] } }
  }},
  { $sort: { total_rev: -1 } },
  { $limit: 10 },
  { $out: "top_skus_materialized" }                  // write to collection
])
```

**Key stages for DEs:**

| Stage | Purpose | DE Use |
|-------|---------|--------|
| `$match` | Filter — must come first for index use | Partition pruning equivalent |
| `$unwind` | Explode array elements into separate docs | Flatten nested arrays before aggregating |
| `$group` | GROUP BY with accumulators | `$sum`, `$avg`, `$push`, `$addToSet` |
| `$lookup` | Left outer join to another collection | Expensive — runs in memory |
| `$bucket` / `$bucketAuto` | Histogram binning | Percentile approximations |
| `$merge` | Write output to collection (upsert) | Incremental materialized views |
| `$out` | Overwrite a collection entirely | Full refresh of summary tables |

**Performance:** Pipelines use indexes only on `$match` and `$sort` at the start. Put `$match` first to reduce document count before expensive stages. `$group` and `$lookup` are memory-bound (100 MB limit per stage; use `allowDiskUse: true` for larger workloads).

### Change Streams (CDC)

Change streams watch collections, databases, or entire deployments for insert/update/delete/replace events. Built on the oplog but expose a clean resumable cursor.

```javascript
const changeStream = db.collection("orders").watch(
  [{ $match: { "operationType": { $in: ["insert", "update", "delete"] } } }],
  { resumeAfter: lastSavedResumeToken, fullDocument: "updateLookup" }
);

for await (const change of changeStream) {
  await saveResumeToken(change._id);  // persist token before processing
  await processChange(change);
}
```

**Resume token:** Each event has a resume token. Save it before processing each event. Valid as long as the oplog hasn't rotated past that point. If the oplog rotates before you resume → full re-snapshot required.

**Common CDC architecture with Debezium:**
```
MongoDB Replica Set
  → Debezium MongoDB Connector (reads oplog)
  → Kafka topic per collection (<logical-name>.<db>.<collection>)
  → Sink connector → Snowflake / Redshift / S3
```

**Debezium pitfalls:**
- Requires replica set — standalone deployments unsupported
- Oplog overflow → "Invalid resume token" error → size oplog at 2–3× peak hourly change rate
- `tasks.max=1` default → no parallelism across collections
- No ordering guarantee across multiple topics (only within a topic)

**Managed alternative:** Atlas Triggers + Atlas Stream Processing handle oplog tailing natively without Debezium.

### Atlas Data Federation

Queries data across Atlas clusters, S3 buckets, and HTTP endpoints using the MongoDB aggregation pipeline — no ETL. `$out` can materialize results back to S3 or Atlas. Read partitions from S3 concurrently (no ordering guarantee without `$sort`).

---

## Apache Cassandra

### Wide-Column Model and Primary Key

Cassandra distributes data via consistent hashing on the partition key. All rows with the same partition key land on the same set of nodes (replication factor copies).

```cql
CREATE TABLE device_telemetry (
    device_id  UUID,
    region     TEXT,
    event_time TIMESTAMP,
    event_id   UUID,
    payload    MAP<TEXT, TEXT>,
    PRIMARY KEY ((device_id, region), event_time, event_id)
);
--              ^^^^^^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^^^^^^^^^^^^^
--          composite partition key    clustering columns (sorted)
```

- **Partition key** (double parens = composite): determines which node(s) hold this data
- **Clustering columns:** physically sort data within a partition; range scans on them are cheap

### CQL Query Rules (vs SQL)

Cassandra looks like SQL but is fundamentally different:

```cql
-- MUST include full partition key in every WHERE
SELECT * FROM device_telemetry
WHERE device_id = ? AND region = ?;           -- OK

SELECT * FROM device_telemetry
WHERE region = ?;                             -- ERROR: missing partition key
                                              -- would need ALLOW FILTERING (never in prod)

-- Clustering columns must be used in declared order
WHERE device_id = ? AND region = ? AND event_time > ?;          -- OK
WHERE device_id = ? AND region = ? AND event_id = ?;            -- ERROR: skipped event_time

-- No server-side joins — joins done in application
-- No aggregations without full partition scan (use materialized views instead)

-- ALLOW FILTERING = code smell, forces full table scan
SELECT * FROM device_telemetry WHERE payload['sensor'] = 'temp' ALLOW FILTERING;  -- NEVER in prod
```

### Tunable Consistency

Cassandra lets you specify consistency level per-query:

| Level | Nodes that must respond | Tradeoff |
|-------|------------------------|---------|
| `ONE` | 1 replica | Fastest, stale reads possible |
| `QUORUM` | majority (`RF/2 + 1`) | Balanced — use for reads + writes to guarantee strong consistency |
| `ALL` | All replicas | Slowest, most consistent |
| `LOCAL_QUORUM` | Majority in local datacenter | Good for multi-DC setups |

**Strong consistency guarantee:** `W:QUORUM + R:QUORUM` with RF=3 → at least 1 node overlap ensures latest write is always returned.

### Compaction Strategies

Cassandra uses an LSM tree write path: writes → commit log + memtable → flush to immutable SSTables. Compaction merges SSTables.

| Strategy | Best for | Tradeoff |
|----------|---------|---------|
| **STCS** (Size-Tiered) | Write-heavy workloads | High temporary disk use during compaction (50% overhead); multiple SSTables to check per read |
| **LCS** (Leveled) | Read-heavy workloads | Better read perf (fewer SSTables to check); higher write amplification |
| **TWCS** (Time-Window) | Time-series (append-only) | Old windows are immutable — minimal compaction overhead; ideal for IoT/telemetry |

**Tombstones:** Deletes write a tombstone marker — not immediately removed. Tombstones accumulate until compaction. A partition with millions of tombstones causes `TombstoneOverwhelmingException`. Avoid rapid delete-then-reinsert cycles.

### Common DE Pitfalls

1. **Large partitions:** Keep under 100 MB. Monitor with `nodetool tablehistograms`. Large partitions cause GC pressure and slow reads.

2. **Unbounded partition growth:**
   ```cql
   -- BAD: user_id PK with unlimited rows
   PRIMARY KEY (user_id, event_time)
   -- Eventually grows to GB per user
   
   -- GOOD: bucket by month
   PRIMARY KEY ((user_id, event_month), event_time)
   ```

3. **Wrong compaction for time-series:** STCS on append-only data accumulates stale SSTables. Switch to TWCS.

4. **Secondary indexes (SASI/SAI):** Distributed across all nodes — a query hits every node. Use sparingly; prefer denormalization (maintain a separate table with a different partition key).

5. **Clock skew:** Cassandra uses wall-clock timestamps for last-write-wins conflict resolution. NTP drift between nodes causes unexpected overwrites. Monitor NTP sync in ops.

6. **`ALLOW FILTERING` in production:** Scans all partitions across all nodes. Safe only on tiny development tables.

### Cassandra vs SQL mental model

```
SQL concept     →  Cassandra equivalent
Table           →  Table (but designed around one access pattern)
Row             →  Row (within a partition)
WHERE clause    →  Must match partition key exactly, then clustering key prefix
INDEX           →  Secondary index (expensive) or separate denormalized table
JOIN            →  Application-level join (query both tables, merge in code)
```

---

*Prev: [62-nosql-foundations.md](62-nosql-foundations.md) | Next: [64-nosql-redis-and-ingestion.md](64-nosql-redis-and-ingestion.md)*
