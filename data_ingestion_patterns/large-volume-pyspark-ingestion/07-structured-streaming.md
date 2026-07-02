# 07 — Structured Streaming: Checkpoints, Watermarks, and Replay Recovery

## 1. The Problem

A streaming ingestion job fails mid-run. On restart it either:

**(a) Reprocesses all data from the beginning** — duplicates appear in the sink, downstream aggregates double-count.

**(b) Misses data between the last checkpoint and the failure** — silent data loss; the gap won't appear in monitoring unless you compare Kafka offsets against sink row counts.

A third failure mode: **late-arriving events are silently dropped**. A window closes at 10:00. An event with `event_time = 09:58` arrives at 10:03. With no watermark configured (or watermark set too aggressively), Spark discards it with no error.

---

## 2. Interview Trigger Phrases

- "Kafka to Delta"
- "real-time ingestion"
- "streaming job crashed"
- "checkpoint"
- "watermark"
- "late data"
- "replay from offset"
- "micro-batch"
- "trigger interval"
- "exactly-once streaming"
- "streaming job crashed and I lost data"
- "offset lag growing"

---

## 3. Detection Signals

| Signal | Where to Look |
|---|---|
| Duplicate rows keyed by `event_time` + business key | Query sink: `GROUP BY key HAVING COUNT(*) > 1` |
| Kafka consumer group lag growing despite Spark running | Kafka UI / `kafka-consumer-groups.sh --describe` |
| Checkpoint directory missing or zero-byte | `ls -la s3://bucket/checkpoints/job_name/` |
| Corrupted checkpoint — job fails on restart with `StreamingQueryException` | Driver logs on startup |
| Valid late events missing from aggregates | Compare event source counts vs. aggregated sink counts by window |
| Watermark advancing too fast — state store evicting prematurely | Spark UI → Streaming → Watermark column in progress report |
| State store OOM on executors | Executor logs: `java.lang.OutOfMemoryError` during stateful aggregation |

---

## 4. Root Cause

**Fault tolerance via checkpointing**: Structured Streaming writes offsets and operator state to a checkpoint directory at the end of each micro-batch. On restart, it reads the checkpoint to resume from exactly where it left off. Without a valid checkpoint, Spark has no record of what it already processed — restart reads from the configured `startingOffsets` (usually `latest`, meaning all data written during the outage is lost).

**Watermarks control state retention**: A watermark on `event_time` tells Spark: "I will wait at most X time for late data, then close the window and evict its state." Set too tight → valid late events dropped. Set too loose → state accumulates unboundedly, leading to executor OOM on stateful operations (joins, aggregations over time windows).

**Schema evolution breaks checkpoints**: Spark encodes the query plan into the checkpoint. If you change the query (add a column, change a join) without deleting the checkpoint, Spark rejects the checkpoint on startup.

---

## 5. Fix Pattern

### Checkpoint setup

```python
query = (
    df
    .writeStream
    .format("delta")
    .outputMode("append")
    .option("checkpointLocation", "s3://bucket/checkpoints/kafka_to_delta_v1/")
    .option("mergeSchema", "true")
    .start("s3://bucket/delta/events/")
)
```

**Rule**: `checkpointLocation` must be unique per streaming query. Two queries sharing a checkpoint directory will corrupt each other.

### Watermark for late data

```python
from pyspark.sql import functions as F

windowed = (
    df
    .withWatermark("event_time", "2 hours")          # wait up to 2h for late events
    .groupBy(
        F.window("event_time", "10 minutes"),         # 10-minute tumbling window
        "user_id"
    )
    .agg(F.count("*").alias("event_count"))
)
```

The watermark `"2 hours"` means: the maximum event time Spark has seen minus 2 hours = the threshold below which late events are discarded. State for windows older than this threshold is evicted.

### Trigger strategies

```python
# Micro-batch: process every 5 minutes
.trigger(processingTime="5 minutes")

# One-shot batch (Spark < 3.3): process all available data, then stop
.trigger(once=True)          # DEPRECATED in Spark 3.3

# AvailableNow (Spark 3.3+): process all available data, then stop — preferred
.trigger(availableNow=True)  # replaces trigger(once=True)

# Continuous processing (experimental, low-latency, limited operators)
.trigger(continuous="1 second")
```

`trigger(availableNow=True)` is the canonical pattern for scheduled batch-as-streaming: it processes all data available at query start, then terminates cleanly. It respects rate limits and checkpoints correctly, unlike `trigger(once=True)`.

### Kafka source configuration

```python
df = (
    spark.readStream
    .format("kafka")
    .option("kafka.bootstrap.servers", "broker1:9092,broker2:9092")
    .option("subscribe", "events_topic")
    .option("startingOffsets", "latest")       # production: start from now
    # .option("startingOffsets", "earliest")   # recovery: replay from beginning
    .option("maxOffsetsPerTrigger", 500_000)   # throttle: max records per micro-batch
    .option("failOnDataLoss", "false")         # tolerate Kafka log compaction/retention gaps
    .load()
)
```

### Replay recovery (corrupted or missing checkpoint)

```python
# Step 1: delete the corrupted checkpoint
import boto3
s3 = boto3.resource("s3")
bucket = s3.Bucket("bucket")
bucket.objects.filter(Prefix="checkpoints/kafka_to_delta_v1/").delete()

# Step 2: restart from earliest offsets to replay missed data
df = (
    spark.readStream
    .format("kafka")
    .option("startingOffsets", "earliest")    # replay all unprocessed data
    .option("endingOffsets", "latest")        # stop at current head
    ...
    .load()
)

# Step 3: after replay completes, deduplicate in Delta via MERGE
spark.sql("""
    MERGE INTO delta.`s3://bucket/delta/events/` AS target
    USING (
        SELECT DISTINCT event_id, event_time, user_id, payload
        FROM delta.`s3://bucket/delta/events_replay/`
    ) AS source
    ON target.event_id = source.event_id
    WHEN NOT MATCHED THEN INSERT *
""")
```

### Exactly-once end-to-end with Delta Lake

Structured Streaming + Delta Lake = exactly-once semantics without manual deduplication, because:
1. Spark checkpoints committed offsets per micro-batch.
2. Delta's transaction log commits the write atomically.
3. On restart, Spark re-reads the checkpoint and resumes — no double-write possible.

```python
# Exactly-once: Kafka → Delta
(
    df.writeStream
    .format("delta")
    .outputMode("append")
    .option("checkpointLocation", "s3://bucket/checkpoints/exactly_once_v1/")
    .start("s3://bucket/delta/events/")
)
# No deduplication needed — Delta + checkpoint = exactly-once
```

### spark-submit config delta

```bash
spark-submit \
  # RocksDB state store: required for large stateful operations (joins, windowed aggs)
  --conf spark.sql.streaming.stateStore.providerClass=org.apache.spark.sql.execution.streaming.state.RocksDBStateStoreProvider \
  # Retain 100 micro-batches of checkpoint metadata (default is 100, set explicitly)
  --conf spark.sql.streaming.minBatchesToRetain=100 \
  # Async checkpointing: don't block micro-batch on checkpoint write
  --conf spark.sql.streaming.checkpointFileManagerClass=org.apache.spark.sql.execution.streaming.CheckpointFileManager \
  ...
```

---

## 6. Gotchas

- **checkpointLocation must be unique per query.** Two streaming queries sharing one checkpoint directory silently corrupt each other's state.
- **Changing the query schema (adding/removing columns) requires deleting the checkpoint.** Spark encodes the logical plan in the checkpoint. Schema changes = checkpoint invalidated = you must replay from earliest offsets.
- **`withWatermark` must be on an event-time column, not processing time.** `current_timestamp()` cannot be used as the watermark column; it must be a column representing when the event actually occurred.
- **`trigger(once=True)` is deprecated in Spark 3.3.** Use `trigger(availableNow=True)`. `trigger(once=True)` does not correctly handle `maxFilesPerTrigger` and can miss data in edge cases.
- **RocksDB state store is required for large stateful operations.** Default in-memory state store OOMs easily with joins across large time windows. Always use RocksDB for production stateful streaming.
- **`outputMode("complete")` re-writes the entire result table every micro-batch.** Only use for small aggregations (e.g., global counts). For append-only streams, use `outputMode("append")`.
- **`failOnDataLoss=false` should be set intentionally.** Kafka log compaction or short retention periods can cause offset gaps. Setting `failOnDataLoss=false` tells Spark to skip missing offsets rather than fail. Know that you're accepting data loss when you set this.
- **Watermark advancement depends on data arriving.** If no events arrive for a topic partition, Spark's watermark does not advance for that partition's data. In multi-partition scenarios with skewed traffic, the watermark can stall.

---

## 7. Interview One-Liner

> "Structured Streaming achieves fault tolerance via checkpointing offsets and state to durable storage — pair it with Delta Lake for exactly-once end-to-end semantics, set watermarks based on acceptable late-arrival SLA rather than zero, and always use a unique checkpoint path per query."
