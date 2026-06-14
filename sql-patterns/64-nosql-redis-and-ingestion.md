# NoSQL — Redis Deep Dive + Ingestion Patterns from NoSQL Sources

## Redis

Redis is an in-memory data structure store. It is not just a cache — it has native data structures that make it a cache, message broker, rate limiter, session store, and leaderboard engine in one.

### Data Structures

| Structure | Commands | DE Use Case |
|-----------|----------|-------------|
| **String** | `GET/SET/INCR/EXPIRE` | Cache values, counters, feature flags |
| **Hash** | `HGET/HSET/HGETALL` | Session objects, entity cache (one key = one entity) |
| **List** | `LPUSH/RPOP/LRANGE` | Task queues, activity feeds (FIFO with LPUSH+RPOP) |
| **Set** | `SADD/SISMEMBER/SUNION` | Unique visitor counts, tag systems, deduplication within window |
| **Sorted Set** | `ZADD/ZRANGE/ZRANGEBYSCORE` | Leaderboards, rate limiting, priority queues (score = priority/timestamp) |
| **Stream** | `XADD/XREAD/XREADGROUP` | Event log, lightweight message broker with consumer groups |
| **HyperLogLog** | `PFADD/PFCOUNT` | Approximate unique count (~0.81% error, fixed 12 KB memory) |
| **Bitmap** | `SETBIT/BITCOUNT` | Daily active users (one bit per user_id per day) |

### Persistence Modes

**RDB (Redis Database Backup) — point-in-time snapshots:**

```conf
# snapshot if 1+ write in 900s, or 10+ writes in 300s, or 10000+ writes in 60s
save 900 1
save 300 10
save 60 10000
```

- Compact binary file, fast restart from snapshot
- **Risk:** Data loss between last snapshot and crash
- **Use when:** Cache (data loss acceptable on restart)

**AOF (Append-Only File) — log every write command:**

```conf
appendonly yes
appendfsync everysec   # options: always (durable, slowest) | everysec (1s risk, balanced) | no (OS-managed, fastest)
```

- `always`: sync every write → durable, low throughput
- `everysec`: sync every second → max 1-second data loss, recommended for most workloads
- `no`: OS decides → fastest, but data loss window is unpredictable

AOF rewrite (`BGREWRITEAOF`) compacts the log by replaying and dropping superseded commands.

**Hybrid (RDB + AOF) — best of both:**

```conf
aof-use-rdb-preamble yes
```

Redis loads the RDB snapshot for fast startup, then replays the AOF tail for commands since the snapshot. Default in Redis 7+.

**Persistence mode selection:**

```
Pure cache (data loss OK)  → RDB only or no persistence (maxmemory + eviction policy)
Durable cache / sessions   → AOF everysec
Critical data source       → Hybrid (RDB + AOF)
```

### Pub/Sub vs Streams

**Pub/Sub (`PUBLISH/SUBSCRIBE`):**
- Fire-and-forget broadcast
- No persistence — if no subscriber is listening, message is lost
- No consumer groups, no backpressure, no acknowledgment
- Use for: real-time notifications where losing a message is acceptable (live dashboards, presence signals)

**Redis Streams (`XADD/XREADGROUP/XACK`):**

```redis
# Producer
XADD orders * order_id 42 customer_id 9 amount 99.99

# Consumer group creation
XGROUP CREATE orders processing-group $ MKSTREAM

# Consumer reads
XREADGROUP GROUP processing-group worker-1 COUNT 10 BLOCK 0 STREAMS orders >

# Acknowledge processed message
XACK orders processing-group <message-id>

# Check unacknowledged (failed) messages
XPENDING orders processing-group - + 10
```

- Messages persist until explicitly ACKed or trimmed (`MAXLEN`)
- Consumer groups — multiple workers split the stream (like Kafka consumer groups)
- `XPENDING` detects unacknowledged messages for retry
- Resume from last position on restart
- **DE use case:** Lightweight message broker for intra-service event sourcing where Kafka is overkill; rate-limited job queues; audit log

### DE-Specific Use Cases

**Cache-aside (most common):**
```python
def get_user(user_id):
    cached = redis.get(f"user:{user_id}")
    if cached:
        return json.loads(cached)
    user = db.query("SELECT * FROM users WHERE id = %s", user_id)
    redis.set(f"user:{user_id}", json.dumps(user), ex=3600)  # TTL 1 hour
    return user
```

**Rate limiting (sorted set sliding window):**
```python
def is_rate_limited(user_id, limit=100, window_secs=60):
    now = time.time()
    key = f"ratelimit:{user_id}"
    pipe = redis.pipeline()
    pipe.zremrangebyscore(key, 0, now - window_secs)  # remove old entries
    pipe.zadd(key, {str(now): now})                    # add current request
    pipe.zcard(key)                                     # count in window
    pipe.expire(key, window_secs)
    results = pipe.execute()
    return results[2] > limit  # True = rate limited
```

**Distributed lock (SET NX PX):**
```python
lock_key = f"lock:{resource}"
lock_value = str(uuid4())
acquired = redis.set(lock_key, lock_value, nx=True, px=30000)  # NX=set if not exists, PX=TTL ms
if acquired:
    try:
        do_work()
    finally:
        # only release if we still own it (Lua for atomicity)
        redis.eval("""
            if redis.call("get", KEYS[1]) == ARGV[1] then
                return redis.call("del", KEYS[1])
            end
            return 0
        """, 1, lock_key, lock_value)
```

**Deduplication within window:**
```python
# Redis SET: exact dedup (memory grows with cardinality)
redis.sadd(f"seen:{today}", event_id)
is_dup = not redis.sismember(f"seen:{today}", event_id)

# HyperLogLog: approximate dedup at scale (fixed 12 KB regardless of cardinality)
redis.pfadd(f"unique_users:{today}", user_id)
approx_count = redis.pfcount(f"unique_users:{today}")
```

### Performance Characteristics

- Single-node throughput: ~100k ops/sec
- Latency: sub-millisecond for in-memory operations
- Redis Cluster: horizontal scaling by hash slots (16,384 slots distributed across nodes)
- Eviction policies: `allkeys-lru`, `allkeys-lfu`, `volatile-lru`, `noeviction` — set based on whether you can afford to lose data

---

## Ingestion Patterns: DEs Reading FROM NoSQL

### DynamoDB → Data Warehouse

**Pattern 1 — Streams + Lambda (real-time):**
```
DynamoDB Table
  → DynamoDB Streams (24h retention, NEW_AND_OLD_IMAGES)
  → Lambda function (EventSourceMapping)
  → Target: S3 (parquet), Redshift (COPY), Elasticsearch
```
- Lambda parallelism: `ParallelizationFactor` 1–10 per shard
- At-least-once delivery → idempotent writes required at target
- 15-min Lambda timeout, 6 MB payload limit

**Pattern 2 — Kinesis bridge (real-time, durable):**
```
DynamoDB Table
  → EnableKinesisStreamingDestination
  → Kinesis Data Streams (7–365 day retention)
  → Firehose → S3
         OR → KCL application
         OR → Lambda
```
- Multiple consumers on same stream
- Longer retention covers consumer downtime

**Pattern 3 — S3 Export (batch, non-real-time):**
```
DynamoDB Table → ExportTableToPointInTime → S3 (DynamoDB JSON or Ion format)
→ Glue Crawler → Glue ETL / Athena query
```
- Full export or incremental (new items since last export)
- No impact on table read capacity
- Use for initial backfills and full historical snapshots

**Schema consideration:** DynamoDB JSON uses typed format `{"S": "value"}`, `{"N": "123"}`. Transform to flat schema in Glue/Spark before loading to Snowflake/Redshift.

---

### MongoDB → Data Warehouse

**Debezium CDC pipeline (real-time):**
```
MongoDB Replica Set (oplog)
  → Debezium MongoDB Connector (Kafka Connect)
  → Kafka topic: <logical-name>.<database>.<collection>
  → Sink Connector: Snowflake / Redshift / S3 / BigQuery
```

**Critical configurations:**
```properties
connector.class=io.debezium.connector.mongodb.MongoDbConnector
mongodb.connection.string=mongodb://host:27017/?replicaSet=rs0
snapshot.mode=initial          # full snapshot on first start, then tails oplog
tasks.max=1                    # single-threaded; increase for multi-collection
capture.mode=change_streams    # preferred over legacy oplog mode
```

**Oplog sizing formula:**
```
oplog_size_GB = peak_change_rate_GB_per_hour × max_connector_downtime_hours × 2.5
```

If oplog rotates past the resume token → Debezium must re-snapshot → latency spikes and full table reload.

**Message structure (Debezium):**
```json
{
  "op": "u",                       // c=insert, u=update, d=delete, r=read(snapshot)
  "before": { "_id": "123", "status": "PENDING" },
  "after":  { "_id": "123", "status": "SHIPPED" },
  "source": { "collection": "orders", "ts_ms": 1704067200000 }
}
```

**MongoDB Atlas Connector (managed alternative):**
Atlas Triggers + Atlas Stream Processing handle CDC natively without Debezium. Writes to Kafka or S3 directly. Eliminates oplog management.

---

### Cassandra → Data Warehouse

**Option 1 — Spark Cassandra Connector (batch):**
```python
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .config("spark.cassandra.connection.host", "cassandra-host") \
    .getOrCreate()

df = spark.read \
    .format("org.apache.spark.sql.cassandra") \
    .options(table="device_telemetry", keyspace="iot") \
    .load()

# Filter on partition key to avoid full table scan
df_filtered = df.filter("device_id = 'device-001' AND event_month = '2024-01'")
df_filtered.write.parquet("s3://bucket/telemetry/")
```

Full table reads via Spark respect Cassandra's token ranges — each Spark task reads one token range in parallel.

**Option 2 — Cassandra CDC + Kafka (real-time):**
```
Cassandra node (CDC log directory)
  → Debezium Cassandra Connector (incubating — not prod-hardened)
  OR DataStax Change Agent (commercial, more reliable)
  OR Lenses.io Kafka Connector for Cassandra
  → Kafka topic
  → Sink → Data warehouse
```

**Cassandra CDC limitations:**
- Built-in CDC does NOT capture: TTL changes, range deletes, static columns, materialized view updates, LWT outcomes
- Debezium Cassandra connector is incubating — use DataStax Change Agent for production
- Alternative: **dual-write** in application layer (write to Cassandra + Kafka simultaneously) — simpler but requires app changes

**Option 3 — DSBulk export (batch):**
```bash
# Unload all rows from a table to CSV
dsbulk unload \
  -h cassandra-host \
  -k iot \
  -t device_telemetry \
  -url s3://bucket/cassandra-export/ \
  --connector.csv.maxConcurrentFiles 8
```

---

### Redis → Data Pipeline

Redis is typically a cache or message broker — not a system of record. DE patterns:

**Pattern 1 — Redis Streams as event source:**
```python
# Consumer reading from Redis Stream
last_id = "0-0"  # or load from checkpoint
while True:
    messages = redis.xread({"events_stream": last_id}, count=100, block=1000)
    for stream_name, entries in messages:
        for msg_id, fields in entries:
            process(fields)
            last_id = msg_id  # checkpoint
```

**Pattern 2 — Periodic snapshot of Redis data to S3:**
```python
# Dump all hash values to parquet for analytics
keys = redis.scan_iter("user:*")
records = [{"user_id": k.split(":")[1], **redis.hgetall(k)} for k in keys]
pd.DataFrame(records).to_parquet("s3://bucket/redis_snapshot/users.parquet")
```

**Pattern 3 — Redis as rate-limit state for streaming pipelines:**
```
Kafka Consumer → Redis (check + increment rate limit counter) → Target sink
```
Prevents downstream systems from being overwhelmed by high-volume Kafka topics.

---

## Semi-Structured Data Handling Patterns

### Flattening Nested JSON in Spark (from MongoDB/DynamoDB)

```python
from pyspark.sql.functions import col, explode, get_json_object

# MongoDB document with nested array
# { "order_id": "1", "items": [{"sku": "A", "qty": 2}, {"sku": "B", "qty": 1}] }

df = spark.read.json("s3://bucket/mongodb-export/orders/")

# Explode array
df_exploded = df.select(
    col("order_id"),
    explode(col("items")).alias("item")
)

# Flatten struct
df_flat = df_exploded.select(
    col("order_id"),
    col("item.sku"),
    col("item.qty")
)
```

### DynamoDB JSON to Flat Schema (Glue)

```python
import boto3
from boto3.dynamodb.types import TypeDeserializer

deserializer = TypeDeserializer()

def dynamo_json_to_dict(dynamo_item):
    return {k: deserializer.deserialize(v) for k, v in dynamo_item.items()}

# DynamoDB export format: {"order_id": {"S": "123"}, "amount": {"N": "99.99"}}
# After deserialize: {"order_id": "123", "amount": Decimal("99.99")}
```

### Snowflake VARIANT for semi-structured

```sql
-- Load JSON into VARIANT column
COPY INTO raw_events
FROM @s3_stage/events/
FILE_FORMAT = (TYPE = JSON);

-- Query nested fields
SELECT
    v:order_id::STRING         AS order_id,
    v:customer.email::STRING   AS customer_email,
    v:items[0].sku::STRING     AS first_sku,
    ARRAY_SIZE(v:items)        AS item_count
FROM raw_events;

-- Flatten array with FLATTEN
SELECT
    v:order_id::STRING AS order_id,
    f.value:sku::STRING AS sku,
    f.value:qty::INT    AS qty
FROM raw_events,
LATERAL FLATTEN(input => v:items) f;
```

---

*Prev: [63-nosql-key-systems.md](63-nosql-key-systems.md) | Next: [65-nosql-quick-reference.md](65-nosql-quick-reference.md)*
