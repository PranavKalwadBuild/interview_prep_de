<!-- PySpark-patterns: Structured Streaming -->

# Structured Streaming

## How It Works

Structured Streaming treats a live data stream as an unbounded table.
Spark micro-batches query the new data since the last batch and appends/updates results.

```
Source (Kafka, Delta, files)
    |
    v
Stream query (filter, join, aggregate)
    |
    v
Sink (Delta, Kafka, files, console)
```

---

## Micro-Batch vs Continuous Processing

| Mode | Latency | Throughput | Use Case |
|------|---------|-----------|----------|
| Micro-batch (default) | Seconds | High | Most use cases |
| Continuous | Milliseconds | Lower | Ultra-low latency |

Continuous processing is experimental. Micro-batch covers 99% of streaming needs.

---

## Source Types

```python
# Kafka source (most common for real-time streaming)
df = spark.readStream \
    .format("kafka") \
    .option("kafka.bootstrap.servers", "host:9092") \
    .option("subscribe", "my-topic") \
    .option("startingOffsets", "latest") \
    .load()
# Kafka returns: key, value (binary), topic, partition, offset, timestamp, timestampType

# Delta source (change data capture from Delta table)
df = spark.readStream.format("delta").load("/data/delta/events/")

# File source (new files dropped into a directory)
df = spark.readStream \
    .schema(my_schema) \
    .option("maxFilesPerTrigger", 10) \
    .parquet("/data/incoming/")

# Rate source (for testing — generates rows at a fixed rate)
df = spark.readStream \
    .format("rate") \
    .option("rowsPerSecond", 100) \
    .load()
```

---

## Trigger Options

```python
# Default: process as fast as possible (back-to-back micro-batches)
query = stream.writeStream.trigger(processingTime="0 seconds") ...

# Fixed interval: process at most once per interval
query = stream.writeStream.trigger(processingTime="1 minute") ...

# Once: process all available data in one batch, then stop (Spark < 3.3)
query = stream.writeStream.trigger(once=True) ...

# AvailableNow: process all available data (multiple batches if needed), then stop (Spark 3.3+)
query = stream.writeStream.trigger(availableNow=True) ...

# Continuous: low-latency but experimental
query = stream.writeStream.trigger(continuous="1 second") ...
```

`availableNow` is the modern replacement for `once=True` — it respects rate limits
and processes in multiple batches if needed, then stops.

---

## Output Modes

| Mode | What It Writes | Requires Watermark? |
|------|---------------|-------------------|
| `append` | Only new rows (no updates) | Yes, for aggregations |
| `complete` | Full result table every batch | No |
| `update` | Only changed/new rows | No |

```python
# Append: new event rows — no state needed
stream.writeStream.outputMode("append")

# Complete: full aggregated result every batch (e.g., running count)
stream.writeStream.outputMode("complete")

# Update: only rows that changed in this batch
stream.writeStream.outputMode("update")
```

---

## Checkpointing (Mandatory for Fault Tolerance)

Checkpoint stores:
- Source offsets (where to resume after restart)
- State data (for stateful operations)
- Committed batch IDs

```python
query = stream.writeStream \
    .format("delta") \
    .outputMode("append") \
    .option("checkpointLocation", "/checkpoints/my-stream/") \
    .start("/data/delta/output/")
```

**Never share a checkpoint directory between two different queries.**
**Never change the query structure after pointing it at an existing checkpoint**
(e.g., adding a filter, changing aggregation) — this causes schema/state mismatch errors.

---

## Watermarking — Handling Late Data

Without a watermark, Spark keeps state for ALL keys forever — unbounded memory growth.
Watermark tells Spark: "I'm done with events more than X time late."

```python
stream = kafka_df \
    .withWatermark("event_time", "10 minutes") \  # tolerate 10 min late data
    .groupBy(
        F.window("event_time", "5 minutes"),   # 5-minute tumbling windows
        F.col("user_id")
    ) \
    .count()
```

With `append` output mode: a window's result is only written after the watermark
passes the window's end time. Late data within the watermark is included.
Data later than the watermark is dropped.

```python
# Sliding windows
F.window("event_time", "10 minutes", "5 minutes")  # 10 min window, slide every 5 min

# Session windows (Spark 3.2+)
F.session_window("event_time", "30 minutes")  # gap-based sessions
```

---

## Stateful Operations

```python
# Deduplication in streaming (requires watermark for bounded state)
stream.withWatermark("event_time", "1 hour") \
      .dropDuplicates(["event_id", "event_time"])

# Running aggregations
stream.withWatermark("event_time", "10 minutes") \
      .groupBy(F.window("event_time", "1 minute"), "user_id") \
      .agg(F.count("*").alias("event_count"))
```

---

## Full Streaming Query Template

```python
# 1. Define source
raw = spark.readStream \
    .format("kafka") \
    .option("kafka.bootstrap.servers", "host:9092") \
    .option("subscribe", "events") \
    .option("startingOffsets", "latest") \
    .load()

# 2. Parse the binary Kafka value to a DataFrame
from pyspark.sql.types import StructType, StructField, StringType, TimestampType, LongType

schema = StructType([
    StructField("event_id", StringType()),
    StructField("user_id", LongType()),
    StructField("event_time", TimestampType()),
    StructField("action", StringType())
])

events = raw.select(F.from_json(F.col("value").cast("string"), schema).alias("data")) \
            .select("data.*")

# 3. Transform
result = events \
    .withWatermark("event_time", "10 minutes") \
    .groupBy(F.window("event_time", "5 minutes"), "user_id") \
    .count()

# 4. Write to sink
query = result.writeStream \
    .format("delta") \
    .outputMode("append") \
    .option("checkpointLocation", "/checkpoints/event-counts/") \
    .trigger(processingTime="1 minute") \
    .start("/data/delta/event_counts/")

query.awaitTermination()
```

---

## How Streaming Breaks

**Unbounded state without watermark:** groupBy on streaming data without watermark
keeps growing in memory until OOM.

**Checkpoint corruption on schema change:** if you change the query structure
(add a column, change aggregation) after the checkpoint exists, Spark may fail
to resume. Delete the checkpoint and restart from scratch (may lose state).

**Late data beyond watermark:** events arriving after the watermark threshold are
silently dropped. Increase watermark delay if you need to handle later data.

**Kafka topic partition rebalance:** if Kafka partitions change, offsets may
shift. Monitor `startingOffsets` and checkpoint carefully.
