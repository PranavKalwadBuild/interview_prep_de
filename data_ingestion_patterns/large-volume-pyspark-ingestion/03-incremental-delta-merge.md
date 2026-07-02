<!-- data-ingestion-patterns: Scenario 03 — Incremental Delta Merge at Scale -->

# Scenario 03 — Incremental Delta Merge at Scale

## The Problem Statement
> The 10 TB daily file is not a full replacement — it contains inserts AND updates to existing records. You must merge these into the existing data warehouse table without duplicates. Table already has 500 TB of historical data.

---

## Clarifying Questions

| Question | Why It Matters |
|----------|---------------|
| What's the merge key? (primary key columns) | Multi-column keys = complex join, more skew risk |
| What percentage is inserts vs updates? | 99% inserts → write-time upsert cheap. 50/50 → heavy merge |
| Can you tolerate eventual consistency (lag)? | Yes → micro-batch merge. No → must do atomic swap |
| How many partitions does the existing table have? | Determines how many files get rewritten |
| Is late-arriving data possible (updates to old records)? | Yes → must scan wider historical range |
| Are deletes required (GDPR)? | Changes merge to MERGE + DELETE |

---

## The Core Challenge

```
Naive approach:
  df_existing.join(df_new, on=merge_key, how="full_outer") → 510 TB shuffle
  → OOM, hours of shuffle, SLA blown

Smart approach:
  Only touch the partitions that have changed records
  → Reduce scope from 500 TB to 10–50 TB
```

---

## Pattern 1 — Partition Pruning Merge (Most Common)

Works when: existing table is partitioned by date/event_date and updates only affect recent partitions.

```python
# Step 1: Find which target partitions are affected by today's batch
affected_dates = (
    df_new
    .select("event_date")
    .distinct()
    .rdd.flatMap(lambda x: x)
    .collect()
)
# e.g., affected_dates = ['2024-01-10', '2024-01-11', '2024-01-15']

# Step 2: Read ONLY those partitions from existing table
df_existing_slice = spark.read.parquet(EXISTING_TABLE_PATH) \
    .filter(col("event_date").isin(affected_dates))
# If 10 days affected × 1 TB/day = 10 TB scan vs 500 TB full scan

# Step 3: Merge within the slice
df_merged = df_existing_slice.alias("existing").join(
    df_new.alias("new"),
    on=MERGE_KEY,
    how="full_outer"
).select(
    coalesce(col("new.id"),        col("existing.id")).alias("id"),
    coalesce(col("new.amount"),    col("existing.amount")).alias("amount"),
    coalesce(col("new.event_date"),col("existing.event_date")).alias("event_date"),
    coalesce(col("new.updated_at"),col("existing.updated_at")).alias("updated_at"),
    # Rule: take new value if exists, else keep existing
)

# Step 4: Write back ONLY the affected partition slices
# Requires dynamic partition overwrite
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")

df_merged.write \
    .mode("overwrite") \
    .partitionBy("event_date") \
    .parquet(EXISTING_TABLE_PATH)
# Only overwrites the partitions that appear in df_merged, not all partitions
```

**Note on dynamic partition overwrite:**
`partitionOverwriteMode=dynamic` overwrites only partitions present in the output DataFrame. Default (`static`) overwrites the ENTIRE table. Always set dynamic mode for incremental merges.

---

## Pattern 2 — Anti-Join Insert + Update Separation

Better when insert/update ratio is known and you want to avoid full join overhead.

```python
# Identify new records (not in existing table)
df_inserts = df_new.join(
    df_existing_slice.select(MERGE_KEY),
    on=MERGE_KEY,
    how="left_anti"                # rows in df_new NOT in existing = pure inserts
)

# Identify updates (keys exist in both)
df_updates = df_new.join(
    df_existing_slice,
    on=MERGE_KEY,
    how="inner"                    # rows in both = updates
).select(df_new["*"])              # take new version

# Remove old versions of updated records from existing
df_existing_minus_updated = df_existing_slice.join(
    df_updates.select(MERGE_KEY),
    on=MERGE_KEY,
    how="left_anti"
)

# Combine: existing (without stale updates) + inserts + updates
df_final = df_existing_minus_updated.unionByName(df_inserts).unionByName(df_updates)

df_final.write \
    .mode("overwrite") \
    .partitionBy("event_date") \
    .parquet(EXISTING_TABLE_PATH)
```

---

## Pattern 3 — Staging Table → Atomic Swap

Best for: complex merges, ACID requirements, or when you cannot do partial partition rewrites.

```python
STAGING_PATH = "s3a://bucket/staging/table_name_staging/"
FINAL_PATH   = "s3a://bucket/processed/table_name/"

# Step 1: Write merged result to staging path
df_merged.write \
    .mode("overwrite") \
    .parquet(STAGING_PATH)

# Step 2: Validate staging (row count, null check, checksum)
staging_count = spark.read.parquet(STAGING_PATH).count()
assert staging_count > MINIMUM_EXPECTED_ROWS, "Staging validation failed"

# Step 3: Atomic rename staging → final
# In S3: this is NOT atomic (copy + delete). Use versioned paths instead.
# Pattern: write to date-keyed path, update a "current" pointer file/table

VERSIONED_PATH = f"s3a://bucket/processed/table_name/version={BATCH_DATE}/"
df_merged.write.mode("overwrite").parquet(VERSIONED_PATH)

# Step 4: Update metadata catalog to point "current" to new version
# (catalog-specific — write a _CURRENT file with the version path)
spark.sparkContext.parallelize([VERSIONED_PATH]) \
    .saveAsTextFile("s3a://bucket/processed/table_name/_CURRENT")
```

---

## Math: Merge Cost Estimate

```
Existing table      = 500 TB
Affected partitions = 10 days × 1 TB/day = 10 TB  (2% of table)
Incoming batch      = 10 TB

Join inputs         = 10 TB (existing slice) + 10 TB (new) = 20 TB
Shuffle size        = 20 TB (full outer join) → needs sufficient partitions

shuffle.partitions  = 20 TB / 128 MB target = 160,000 partitions
                     (set HIGHER than needed — AQE will coalesce down)

Executor memory check:
  One shuffle partition in memory: 128 MB × 3.5 overhead = ~448 MB
  4 concurrent tasks per executor (4 cores): 4 × 448 MB = 1.8 GB → fits in 16 GB executor
```

---

## Key Configs for Merge Workloads

```python
# Shuffle must be set HIGH — AQE coalesces down, cannot go up
spark.conf.set("spark.sql.shuffle.partitions", "20000")   # for 20 TB join input

# AQE to handle post-merge partition imbalance
spark.conf.set("spark.sql.adaptive.enabled", "true")
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")
spark.conf.set("spark.sql.adaptive.advisoryPartitionSizeInBytes", "128m")

# For parallelismFirst=false: AQE respects advisory size
# For parallelismFirst=true (default): AQE maximizes parallelism, ignores advisory size
# Set to false when you want controlled output file sizes
spark.conf.set("spark.sql.adaptive.coalescePartitions.parallelismFirst", "false")

# Dynamic partition overwrite — CRITICAL for incremental merge
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")

# Avoid huge shuffle spill
spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionFactor", "5")
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes", "256m")
```

---

## Idempotency for Merges

```python
# Pattern: check if batch already processed before running merge
WATERMARK_PATH = "s3a://bucket/metadata/merge_watermark.txt"

try:
    last_processed = spark.read.text(WATERMARK_PATH).first()[0]
    if last_processed == BATCH_DATE:
        print(f"Batch {BATCH_DATE} already processed. Exiting.")
        sys.exit(0)
except:
    pass  # No watermark yet = first run

# ... run merge ...

# Write watermark after successful merge
spark.sparkContext.parallelize([BATCH_DATE]) \
    .coalesce(1) \
    .saveAsTextFile(WATERMARK_PATH)
```

---

## Follow-up Questions Interviewers Ask

**Q: Why not just OVERWRITE the whole table daily?**
A: 500 TB full overwrite daily = 500 TB read + 500 TB write every day. At S3 throughput of 5 GB/s, that's 500,000 GB / 5 GB/s = 27.7 hours — already over the 3-hour SLA before any compute.

**Q: What if updates span all historical partitions (e.g., GDPR delete)?**
A: Cannot avoid full table scan. Options: (1) use a soft-delete flag + compact periodically, (2) maintain a separate "delete log" and apply at query time, (3) accept that GDPR deletes run in a separate off-SLA job.

**Q: dynamic vs static partition overwrite — explain simply.**
A: Static (default) = `OVERWRITE TABLE` — rewrites every partition. Dynamic = `INSERT OVERWRITE` scoped to only the partitions present in the output. Always use dynamic for incremental workloads.

**Q: What's the risk of Pattern 3 (staging swap) on S3?**
A: S3 rename is NOT atomic — it's a copy + delete. If the process crashes mid-rename, you get partial data in both paths. Mitigate with versioned paths + catalog pointer update (two-phase: write new version, then flip pointer atomically). Never rely on S3 rename for atomicity.
