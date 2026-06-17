# Scenario 06 — Late-Arriving Partitions and Idempotent Re-runs

## The Problem Statement
> Daily batch at midnight. Most data arrives on time, but ~5% of records have `event_date` from 3 days ago (late-arriving transactions). Also: the pipeline failed halfway through last night. How do you re-run without duplicates?

---

## Clarifying Questions

| Question | Why It Matters |
|----------|---------------|
| How late can records arrive? (hours, days, weeks?) | Determines how far back to look for affected partitions |
| Is the data partitioned by event_date or ingestion_date? | Determines where late data lands |
| Is downstream expecting idempotent results? | Re-runs must produce same output |
| What defines a duplicate? (same primary key? same row?) | Determines dedup strategy |
| Are downstream queries real-time or daily batch? | Determines whether partition rewrite causes read inconsistency |
| Can you write to a staging area before committing? | Yes → two-phase commit pattern |

---

## Problem 1 — Late-Arriving Records in Wrong Partitions

### Scenario A: Partition by event_date (data goes to old partition)

```
Today's batch (2024-01-15) contains records with event_date = 2024-01-12 (3 days late)
These belong in the date=2024-01-12 partition
That partition was already written 3 days ago

Naive overwrite: df.write.mode("overwrite").partitionBy("event_date") 
→ static overwrite mode DELETES and rewrites the ENTIRE table
→ loses all historical data
```

```python
# WRONG (static overwrite — rewrites all partitions)
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "static")  # DEFAULT
df_new.write \
    .mode("overwrite") \
    .partitionBy("event_date") \
    .parquet(TABLE_PATH)   # ← nukes every partition

# RIGHT (dynamic overwrite — only touches affected date partitions)
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")
df_new.write \
    .mode("overwrite") \
    .partitionBy("event_date") \
    .parquet(TABLE_PATH)   # ← only overwrites date=2024-01-12 and date=2024-01-15
```

### Scenario B: Partition by ingestion_date (late data goes to today's partition)

```python
# Add ingestion_date separately from event_date
df_new = df_new \
    .withColumn("ingestion_date", lit(BATCH_DATE)) \
    .withColumn("event_date", col("event_timestamp").cast("date"))

# Write partitioned by ingestion_date (today)
df_new.write \
    .mode("overwrite") \
    .partitionBy("ingestion_date") \
    .parquet(TABLE_PATH)

# Downstream query handles late data with watermark logic:
# SELECT * FROM table WHERE event_date BETWEEN '...' AND '...'
# This naturally picks up late data once it's in any ingestion_date partition
```

---

## Problem 2 — Idempotent Re-runs (Most Common Interview Question)

### What Idempotency Means

```
Running the pipeline once   → produces correct result
Running the pipeline twice  → produces same correct result (no duplicates, no missing data)
Running after partial fail  → picks up from last consistent state
```

### Pattern 1 — Deterministic Output Path (Simplest)

```python
# Write to a path keyed by BATCH_DATE — same key = same path = overwrite is safe
OUTPUT_PATH = f"s3a://bucket/processed/table/{BATCH_DATE}/"

df_transformed.write \
    .mode("overwrite") \           # second run overwrites first run's output
    .parquet(OUTPUT_PATH)

# Idempotent because:
# - Same batch date → same output path
# - mode("overwrite") → second run replaces first
# - No append → no duplicates

# Risk: if BATCH_DATE is wrong or changes between runs → wrong path
# Mitigation: derive BATCH_DATE from the input manifest, not from current timestamp
```

### Pattern 2 — Watermark / Checkpoint File

```python
WATERMARK_PATH = "s3a://bucket/metadata/ingestion_watermarks/"
BATCH_WATERMARK = f"{WATERMARK_PATH}date={BATCH_DATE}/_SUCCESS"

def is_already_processed(batch_date: str) -> bool:
    try:
        spark.read.text(f"{WATERMARK_PATH}date={batch_date}/").count()
        return True
    except Exception:
        return False

def mark_as_processed(batch_date: str):
    spark.sparkContext.parallelize(["SUCCESS"]) \
        .coalesce(1) \
        .saveAsTextFile(f"{WATERMARK_PATH}date={batch_date}/")

# Pipeline entry point
if is_already_processed(BATCH_DATE):
    print(f"Batch {BATCH_DATE} already processed. Skipping.")
    sys.exit(0)

# ... run pipeline ...

mark_as_processed(BATCH_DATE)
```

### Pattern 3 — Two-Phase Commit (Atomic Safety)

```python
STAGING_PATH = f"s3a://bucket/staging/table/{BATCH_DATE}/"
FINAL_PATH   = f"s3a://bucket/processed/table/"

# Phase 1: Write to staging (idempotent — overwrite same staging path)
df_transformed.write \
    .mode("overwrite") \
    .parquet(STAGING_PATH)

# Phase 2: Validate staging
staging_count = spark.read.parquet(STAGING_PATH).count()
expected_count = get_expected_count(BATCH_DATE)  # from manifest/control table
assert staging_count >= expected_count * 0.99, \
    f"Staging count {staging_count} < 99% of expected {expected_count}"

# Phase 3: Promote staging → final (with dynamic overwrite)
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")
spark.read.parquet(STAGING_PATH) \
    .write \
    .mode("overwrite") \
    .partitionBy("event_date") \
    .parquet(FINAL_PATH)

# Phase 4: Mark complete (write watermark)
mark_as_processed(BATCH_DATE)
```

---

## Problem 3 — Re-running After Partial Failure Mid-Shuffle

```
Scenario: Job fails at Stage 3 (shuffle write) after Stage 1 and 2 completed.
Spark's task-level retry handles intra-stage failures automatically.
But if the DRIVER crashes, no checkpoint = restart from beginning.

Solution: Checkpoint expensive intermediate results
```

```python
# Set checkpoint directory (HDFS or S3 path — NOT local, must be accessible by all executors)
spark.sparkContext.setCheckpointDir("s3a://bucket/checkpoints/")

# After expensive operation (large join, complex aggregation):
df_after_join = df_a.join(df_b, on="key", how="left")
df_after_join.checkpoint()   # materializes to checkpoint dir — survives driver restart
# ↑ Checkpoint is eager: triggers action and saves partitioned data to checkpoint dir

# Re-run from checkpoint if available
CHECKPOINT_PATH = f"s3a://bucket/checkpoints/{BATCH_DATE}/after_join/"

try:
    df_after_join = spark.read.parquet(CHECKPOINT_PATH)
    print("Resuming from checkpoint")
except:
    df_after_join = df_a.join(df_b, on="key", how="left")
    df_after_join.write.mode("overwrite").parquet(CHECKPOINT_PATH)
    df_after_join = spark.read.parquet(CHECKPOINT_PATH)
```

**Note:** `df.checkpoint()` is eager (triggers computation). `df.cache()` is lazy (recomputes on access after eviction). For crash recovery, use explicit write-to-path pattern — it's more reliable than Spark's built-in checkpoint which uses the same SparkContext.

---

## Handling Late Data: Window-Based Reprocessing

```python
# Determine which historical partitions need updating due to late arrivals
BATCH_DATE = "2024-01-15"
MAX_LATE_DAYS = 7   # records can arrive up to 7 days late

affected_event_dates = (
    df_new
    .select("event_date")
    .distinct()
    .filter(col("event_date") < BATCH_DATE)  # only historical dates = late records
    .filter(col("event_date") >= date_sub(lit(BATCH_DATE), MAX_LATE_DAYS))
    .rdd.flatMap(lambda r: r)
    .collect()
)

if affected_event_dates:
    print(f"Late data found for: {affected_event_dates}")
    
    # Re-merge those historical partitions
    for event_date in affected_event_dates:
        df_historical = spark.read.parquet(FINAL_PATH) \
            .filter(col("event_date") == event_date)
        
        df_late = df_new.filter(col("event_date") == event_date)
        
        # Merge: new records win, else keep historical
        df_corrected = df_historical.alias("h").join(
            df_late.alias("l"), on=MERGE_KEY, how="full_outer"
        ).select(
            coalesce(col("l.id"),    col("h.id")).alias("id"),
            coalesce(col("l.value"), col("h.value")).alias("value"),
            lit(event_date).alias("event_date")
        )
        
        spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")
        df_corrected.write \
            .mode("overwrite") \
            .partitionBy("event_date") \
            .parquet(FINAL_PATH)
```

---

## Key Configs

```python
# Dynamic overwrite — MUST for late-arriving + incremental writes
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")

# AQE for efficient re-merge of varied partition sizes
spark.conf.set("spark.sql.adaptive.enabled", "true")
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")

# Checkpoint dir for crash recovery
spark.sparkContext.setCheckpointDir("s3a://bucket/spark-checkpoints/")
```

---

## Follow-up Questions Interviewers Ask

**Q: static vs dynamic partition overwrite — what's the default?**
A: Static is the default. It overwrites the ENTIRE table (all partitions). Dynamic overwrites only the partitions present in the output DataFrame. For any incremental workload, always set dynamic. Common interview gotcha — many candidates don't know the default is static.

**Q: Is S3 rename atomic?**
A: No. S3 does not support atomic renames on standard buckets. `rename()` in S3A is implemented as copy + delete — O(data). If process crashes mid-rename, you get partial data in both source and destination. Pattern: write to versioned path, update metadata pointer (that pointer update is small, but also not transactional unless using a catalog with ACID support).

**Q: What's the risk of using `df.checkpoint()` vs writing to a path explicitly?**
A: `df.checkpoint()` writes to `spark.sparkContext.checkpointDir` and truncates lineage. If the SparkContext dies and restarts, the old checkpoint files still exist but the new context doesn't know about them unless you read them explicitly. Explicit `write.parquet(path)` + `read.parquet(path)` is more portable and easier to resume manually.

**Q: How do you handle re-runs when downstream consumers are reading the data concurrently?**
A: Write to a new versioned path, then atomically swap a "current" pointer in a metadata catalog. Consumers always read from the "current" pointer — they see the old version until the swap, then the new version after. Never write-in-place while consumers are reading.
