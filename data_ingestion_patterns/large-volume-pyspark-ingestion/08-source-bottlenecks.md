# 08 — Source-Specific Bottlenecks: JDBC, Kafka, APIs, SFTP

## 1. The Problem

The source system — not Spark — is the throughput bottleneck. Spark's parallelism is worthless if the source cannot serve it.

- A JDBC read with 200 partitions maxes out the source DB connection pool and causes connection refused errors on prod.
- A Kafka consumer is bounded by partition count; adding more executor cores does nothing.
- A REST API returns 429 Too Many Requests after the first few executor calls.
- An SFTP pickup is physically incapable of parallelism: one SSH connection, serial reads.

In each case, Spark looks healthy in the Spark UI while the actual bottleneck is invisible unless you look at the source system.

---

## 2. Interview Trigger Phrases

- "reading from Oracle / MySQL / Postgres"
- "JDBC timeout"
- "database connection limit"
- "source DB is spiking during Spark read"
- "Kafka partition count"
- "REST API ingestion"
- "SFTP file pickup"
- "source system is overwhelmed"
- "how do you parallelize a JDBC read"
- "DB connection pool exhausted"

---

## 3. Detection Signals

| Source | Signal | Where to Look |
|---|---|---|
| JDBC | Source DB CPU at 100% during Spark read | DB monitoring (CloudWatch RDS, pg_stat_activity) |
| JDBC | Connection refused or Too many connections in executor logs | Spark UI - Executor stderr |
| JDBC | Single task reads entire table (1 partition) | Spark UI - Stages - 1 task with 100% of input bytes |
| Kafka | Consumer group lag growing despite Spark running | kafka-consumer-groups.sh --describe |
| Kafka | Spark has 200 tasks but Kafka only has 20 partitions | Spark UI - Stages - task count vs active task count |
| REST API | 429 Too Many Requests in executor logs | Executor stderr |
| REST API | Spark tasks taking 30-120s each (API latency, not compute) | Spark UI - task duration histogram |
| SFTP | Entire read is 1 task, 1 executor, single-threaded | Spark UI - Stages - 1 task |

---

## 4. Root Cause

Spark assumes sources can serve parallel reads. Each Spark partition becomes one or more source connections. Sources have hard limits:

| Source | Parallelism Limit | Controlled By |
|---|---|---|
| JDBC | DB connection pool size | DBA / DB config |
| Kafka | Number of topic partitions | Kafka admin |
| REST API | Rate limit (requests/sec or requests/day) | API provider |
| SFTP | 1 (single SSH session) | Protocol - cannot be changed |

Spark does not know about these limits. Setting `numPartitions=200` on a JDBC read opens 200 simultaneous DB connections. If the DB's `max_connections = 100`, the extra 100 connections are refused, tasks fail, and the job retries until it hits the job timeout.

---

## 5. Fix Patterns

### JDBC

```python
# WRONG: single connection, full table scan, 1 Spark task
df = spark.read.jdbc(
    url="jdbc:postgresql://prod-db:5432/analytics",
    table="large_events",
    properties={"user": "svc_spark", "password": "...", "driver": "org.postgresql.Driver"}
)

# RIGHT: parallel read via numeric column partitioning
df = spark.read.jdbc(
    url="jdbc:postgresql://prod-db:5432/analytics",
    table="large_events",
    column="id",              # must be numeric, uniformly distributed, indexed
    lowerBound=1,
    upperBound=100_000_000,
    numPartitions=50,         # 50 parallel DB connections -- confirm pool limit with DBA
    properties={"user": "svc_spark", "password": "...", "driver": "org.postgresql.Driver"}
)
# Rule: numPartitions <= (DB connection pool size) - (headroom for app connections)
# Typical: connection pool = 200, headroom = 50, numPartitions = 150 max
```

**When the partition column is not numeric -- use `predicates`:**

```python
predicates = [
    "region = 'US'",
    "region = 'EU'",
    "region = 'APAC'",
    "region IS NULL",
]
df = spark.read.jdbc(
    url=url,
    table="large_events",
    predicates=predicates,    # one DB connection per predicate
    properties=props
)
```

**When there is no good partition column:**

```python
# Read entire table in 1 partition (slow but safe)
df = spark.read.jdbc(url=url, table="large_events", properties=props)

# Then repartition in Spark memory for downstream processing
df = df.repartition(200)
# Note: the bottleneck is still the serial read -- repartition only helps downstream transforms
```

**Push down predicates to reduce what the DB scans:**

```python
df = spark.read.jdbc(
    url=url,
    table="(SELECT * FROM large_events WHERE event_date >= '2024-01-01') AS t",
    column="id",
    lowerBound=50_000_000,
    upperBound=100_000_000,
    numPartitions=50,
    properties=props
)
```

---

### Kafka

```python
df = (
    spark.readStream
    .format("kafka")
    .option("kafka.bootstrap.servers", "broker1:9092,broker2:9092")
    .option("subscribe", "events_topic")
    # Spark parallelism = number of Kafka partitions (hard ceiling)
    # To increase parallelism: increase Kafka partition count (Kafka admin action)

    # Throttle Spark from overwhelming downstream systems:
    .option("maxOffsetsPerTrigger", 1_000_000)   # max records per micro-batch

    # Force Spark to split Kafka partitions into more Spark tasks:
    .option("minPartitions", 100)                 # Spark splits partitions to reach 100 tasks
    .load()
)
```

**Key rule**: True parallelism is bounded by Kafka partition count. `minPartitions` makes Spark split one Kafka partition across multiple Spark tasks (more tasks, same data volume -- helps if per-task compute is the bottleneck). To genuinely increase throughput, increase Kafka partition count -- a Kafka admin operation, not a Spark config.

**Check consumer group lag:**

```bash
kafka-consumer-groups.sh \
  --bootstrap-server broker1:9092 \
  --describe \
  --group spark-streaming-group
# LAG column: if growing, Spark is not keeping up
# Fix: increase Kafka partitions or tune maxOffsetsPerTrigger
```

---

### REST API

APIs cannot be read with `spark.read` natively. Use `mapPartitions` to distribute API calls across executors.

```python
import requests
import time

def fetch_api_batch(ids, api_key, rate_limit_sleep=0.1):
    """Fetch records from a rate-limited API for a list of IDs."""
    results = []
    for record_id in ids:
        for attempt in range(5):
            try:
                resp = requests.get(
                    f"https://api.example.com/records/{record_id}",
                    headers={"Authorization": f"Bearer {api_key}"},
                    timeout=10
                )
                if resp.status_code == 429:
                    time.sleep(2 ** attempt)   # exponential backoff
                    continue
                resp.raise_for_status()
                results.append(resp.json())
                break
            except requests.RequestException as e:
                if attempt == 4:
                    results.append({"id": record_id, "error": str(e)})
        time.sleep(rate_limit_sleep)   # steady-state rate limiting
    return results

# Distribute IDs across executors
all_ids = [row.id for row in spark.table("ids_to_fetch").collect()]
id_rdd = spark.sparkContext.parallelize(all_ids, numSlices=20)   # 20 parallel API callers

api_key = "..."   # pass via broadcast variable or environment variable
results_rdd = id_rdd.mapPartitions(lambda ids: fetch_api_batch(list(ids), api_key))

from pyspark.sql.types import StructType, StructField, StringType, IntegerType
schema = StructType([
    StructField("id", IntegerType()),
    StructField("name", StringType()),
])
df = spark.createDataFrame(results_rdd, schema=schema)
```

---

### SFTP

SFTP is physically incapable of Spark-level parallelism. One SSH connection, one stream.

```python
# WRONG: Hadoop SFTP filesystem is 1 connection, 1 task, serial. Avoid.
# df = spark.sparkContext.binaryFiles("sftp://host/path/")

# RIGHT: pre-stage SFTP to S3, then read from S3 in parallel

# Step 1: copy SFTP to S3 using a separate tool (before the Spark job)
# Option A: rclone (recommended)
#   rclone copy sftp:host/data/drop/ s3:bucket/sftp-staging/ --transfers 4

# Option B: Python script with paramiko
import paramiko
import boto3

ssh = paramiko.SSHClient()
ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
ssh.connect("sftp.example.com", username="svc_user", key_filename="/path/to/key")
sftp = ssh.open_sftp()

s3 = boto3.client("s3")
for filename in sftp.listdir("/data/drop/"):
    with sftp.open(f"/data/drop/{filename}") as f:
        s3.upload_fileobj(f, "bucket", f"sftp-staging/{filename}")

sftp.close()
ssh.close()

# Step 2: Spark reads from S3 in parallel -- full parallelism restored
df = spark.read.csv("s3://bucket/sftp-staging/", header=True, inferSchema=True)
```

---

## 6. spark-submit Config Delta

For JDBC, `numPartitions` is set in application code. Tune shuffle partitions to match:

```bash
spark-submit \
  --conf spark.sql.shuffle.partitions=50 \
  --conf spark.streaming.kafka.maxRatePerPartition=10000 \
  ...
```

---

## 7. Gotchas

- **JDBC parallel read can kill a production DB.** Always get DBA sign-off on `numPartitions` before running against prod. Start low (10), benchmark, then increase.
- **`lowerBound` and `upperBound` are not filters -- they are partition boundaries.** All rows in the table are always read. If actual IDs go outside the declared range, rows are still read but unevenly distributed (skewed partitions).
- **Kafka partition count cannot be reduced after creation.** Only increasing partition count is possible. Plan upfront -- increasing partitions reshuffles key assignment and breaks ordering guarantees for keyed producers.
- **API rate limits are per API key, not per IP or per executor.** At extreme scale, use separate API keys per executor. Confirm the rate limit scope in the API docs.
- **SFTP over S3-compatible endpoints supports parallelism.** MinIO, Wasabi, and similar services expose SFTP but the underlying storage is object-based. Confirm the backend before assuming the SFTP bottleneck applies.
- **JDBC pushdown predicates must use the source dialect.** PostgreSQL, Oracle, and MySQL have different SQL syntax. Test the subquery directly on the source DB before embedding it in Spark code.
- **`numPartitions` skew from non-uniform column distribution.** If IDs cluster in a narrow range, most partitions will be nearly empty and one will hold almost all rows. Run `EXPLAIN ANALYZE` or check histogram stats on the source DB before choosing partition bounds.

---

## 8. Interview One-Liner

> "Spark's parallelism is bounded by the source's ability to serve it -- JDBC needs explicit partition column config with `numPartitions` capped at the DB connection pool size, Kafka parallelism is bounded by topic partition count, REST APIs require `mapPartitions` with exponential backoff, and SFTP must be pre-staged to object storage before Spark touches it."
