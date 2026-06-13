# Scenario 06 — Window Function at Scale: Sessionization

**Domain:** Clickstream sessionization — web analytics platform
**Difficulty:** Intermediate
**Primary Concepts:** Window function execution, partitionBy shuffle, sort within window partition, frame evaluation, memory per window partition, OOM conditions for large window partitions

---

## Cluster Specification

| Component | Count | Cores | RAM |
|---|---|---|---|
| Executor nodes | 8 | 6 cores each | 40 GB each |
| Driver node | 1 | 8 cores | 16 GB |
| **Total executor cores** | — | **48 cores** | **320 GB total** |

- `spark.executor.memory = 40 GB`
- `spark.executor.cores = 6`
- `spark.executor.instances = 8`
- `spark.driver.memory = 16 GB`

---

## Data Characteristics

| Attribute | Value |
|---|---|
| Total dataset size | 150 GB (Parquet, Snappy-compressed) |
| Total event records | 3,000,000,000 (3 billion) |
| Distinct user_ids | 10,000,000 (10 million) |
| Average row size | ~50 bytes (user_id: 8B, event_timestamp: 8B, event_type: 10B, url: 20B, misc: 4B) |
| Sanity check | 3B rows x 50 bytes = 150,000,000,000 bytes = ~139.7 GB (~150 GB on disk with Snappy ~1:1 for mixed types) |

### User Distribution (Skew Profile)

| Segment | User Count | Events per User | Total Events | Share of Data |
|---|---|---|---|---|
| Standard users (bottom 99%) | 9,900,000 | < 500 | 2,100,000,000 | 70% |
| Power users (top 1%) | 100,000 | 5,000-50,000 (avg ~9,000) | 900,000,000 | 30% |

- Power user average event count: 900,000,000 / 100,000 = **9,000 events per power user**
- Top individual power user upper bound: **50,000 events**

### File Layout

- Format: Parquet with Snappy compression
- Assumed file count: 150 GB / 128 MB per file = 1,172 files (one row group per file for simplicity)
- Parquet is splittable; each 128 MB chunk is an independent split

---

## Transformation Chain

| Step | Operation | Type | Shuffle? |
|---|---|---|---|
| 1 | Read 150 GB Parquet from storage | Source | No |
| 2 | Filter / select relevant columns (if any) | Narrow | No |
| 3 | Window: partitionBy(user_id).orderBy(event_timestamp) — LAG for session gap detection | Wide | Yes — shuffle to co-locate all rows per user_id |
| 4 | Window: running count to assign session_id within each user partition | Wide | No additional shuffle (same partition key, same ordering already computed) |
| 5 | Write sessionized output | Sink | No |

The window operation is the sole shuffle boundary. Steps 3 and 4 share the same window spec, so Spark's optimizer combines them into one WindowExec node with one shuffle.

---

## Pre-Execution Sizing Math

### Input Partition Count

```
maxPartitionBytes = 128 MB (default spark.sql.files.maxPartitionBytes)
total_data        = 150 GB = 150 x 1,024 MB = 153,600 MB

input_partitions  = ceil(153,600 MB / 128 MB)
                  = ceil(1,200)
                  = 1,200 input partitions
```

Commonly cited as ~1,172 when using 150 x 1,000 MB convention; using binary: 1,200. Both are valid estimates.

### Shuffle Partition Count (Default)

```
spark.sql.shuffle.partitions = 200 (default)
```

After the partitionBy(user_id) shuffle, all 3 billion events are redistributed into 200 output partitions. User assignment to shuffle partitions is by hash: hash(user_id) % 200.

### Average Users per Shuffle Partition

```
distinct_users          = 10,000,000
shuffle_partitions      = 200

avg_users_per_partition = 10,000,000 / 200 = 50,000 users per partition
```

### Average Rows per Shuffle Partition

```
total_rows              = 3,000,000,000
shuffle_partitions      = 200

avg_rows_per_partition  = 3,000,000,000 / 200 = 15,000,000 rows per partition
```

### Average Shuffle Partition Size (Bytes)

```
avg_row_size            = 50 bytes
avg_rows_per_partition  = 15,000,000

avg_partition_bytes     = 15,000,000 x 50 bytes
                        = 750,000,000 bytes
                        = 750 MB per shuffle partition (average)
```

This is the average case. The skew analysis below shows the pathological case.

---

## Power User Skew Analysis

### Single Power User Memory Footprint

```
top_user_events     = 50,000 (max)
avg_user_events     = 9,000 (power user average)
row_size            = 50 bytes

top_user_raw_bytes  = 50,000 x 50 bytes = 2,500,000 bytes = 2.5 MB
avg_user_raw_bytes  = 9,000 x 50 bytes  = 450,000 bytes   = 0.45 MB
```

A single power user is small on its own. The OOM risk comes from partition co-location of many power users.

### Worst-Case Partition: All Power Users Hash to One Partition

With 200 shuffle partitions and 100,000 power users:

```
power_users_per_partition      = 100,000 / 200 = 500 power users (expected per partition)
avg_events_per_power_user      = 9,000
total_events_in_hot_partition  = 500 x 9,000 = 4,500,000 events
hot_partition_bytes            = 4,500,000 x 50 bytes = 225,000,000 bytes = 225 MB
```

This is the expected hot partition. However, hash(user_id) is not perfectly uniform. A skew scenario:

```
Skew estimate: if 20% of power users cluster into one partition (hash collision / non-uniform IDs)
skewed_power_users    = 100,000 x 0.20 = 20,000 power users
events_in_skew        = 20,000 x 9,000 = 180,000,000 events
skew_partition_bytes  = 180,000,000 x 50 bytes = 9,000,000,000 bytes = 9 GB
```

For the absolute worst-case instructional bound (all power users in one partition):

```
all_power_users            = 100,000
avg_events_per_power_user  = 9,000
worst_partition_events     = 100,000 x 9,000 = 900,000,000 events
worst_partition_bytes      = 900,000,000 x 50 bytes = 45,000,000,000 bytes = 45 GB
```

The 45 GB figure represents the theoretical maximum. A realistic high-skew scenario with 20% concentration yields a 9 GB partition — still catastrophically larger than available execution memory per task.

---

## Memory Budget Analysis

### Step 1: Raw JVM Heap

```
spark.executor.memory   = 40 GB = 40,960 MB
Reserved memory         = 300 MB (hardcoded by Spark)

Usable heap             = 40,960 - 300 = 40,660 MB
```

### Step 2: Memory Overhead (YARN Container)

```
memoryOverhead = max(384 MB, 0.10 x 40,960 MB)
               = max(384, 4,096)
               = 4,096 MB (~4 GB)

Total YARN container per executor = 40,960 + 4,096 = 45,056 MB (~44 GB)
```

### Step 3: Unified Memory Pool

```
spark.memory.fraction   = 0.6 (default)

Unified Memory (M)      = 40,660 MB x 0.6 = 24,396 MB (~23.8 GB)
User Memory             = 40,660 MB x 0.4 = 16,264 MB (~15.9 GB)
```

### Step 4: Storage and Execution Split

```
spark.memory.storageFraction = 0.5 (default)

Protected Storage (R)        = 24,396 MB x 0.5 = 12,198 MB (~11.9 GB)
Initial Execution Memory     = 24,396 MB x 0.5 = 12,198 MB (~11.9 GB)
```

If no data is cached, execution can borrow the full unified pool:

```
Max Execution Memory (no cache) = 24,396 MB (~23.8 GB)
```

### Step 5: Memory Per Concurrent Task

```
spark.executor.cores          = 6
concurrent_tasks_per_executor = 6

If execution borrows full unified pool (no cache):
Max memory per task = 24,396 MB / 6 = 4,066 MB (~3.97 GB)
```

Using the scenario's approximate figure for round numbers (treating 4 GB overhead as reducing usable heap directly):

```
Usable heap (approx)   ~= 36,000 MB (40 GB - 4 GB overhead)
Unified Memory          = 36,000 x 0.6 = 21,600 MB
Execution Memory        = 21,600 x 0.5 = 10,800 MB (initial; can grow to 21,600 MB)
Memory per task         = 21,600 / 6   = 3,600 MB (3.6 GB) -- commonly used estimate
```

**Key number: ~3.6 GB execution memory available per task (optimistic, no cache contention).**

### Full Memory Budget Summary

| Region | Formula | Value |
|---|---|---|
| JVM heap | spark.executor.memory | 40 GB |
| Reserved memory | hardcoded | 300 MB |
| Usable heap | 40 GB - 300 MB | ~39.7 GB |
| YARN overhead | max(384 MB, 10% x 40 GB) | ~4 GB |
| Total container | 40 GB + 4 GB | ~44 GB |
| Unified Memory | 39.7 GB x 0.6 | ~23.8 GB |
| User Memory | 39.7 GB x 0.4 | ~15.9 GB |
| Protected Storage | 23.8 GB x 0.5 | ~11.9 GB |
| Initial Execution | 23.8 GB x 0.5 | ~11.9 GB |
| Max Execution (no cache) | 23.8 GB x 1.0 | ~23.8 GB |
| Memory per task (6 cores) | 23.8 GB / 6 | ~3.97 GB |

---

## OOM Condition: Where the Math Breaks

### Average Case (Fine)

```
avg_partition_bytes       = 750 MB (raw data)
JVM overhead factor       = 2-3x (deserialized objects: 16B headers, UTF-16 strings)
in-memory partition size  = 750 MB x 3 = 2,250 MB (2.25 GB)

Memory per task (3.6 GB)  > in-memory partition (2.25 GB): OK -- fits in memory
```

The average shuffle partition (750 MB on disk, ~2.25 GB in JVM memory) fits within the 3.6 GB task budget. Spill may occur intermittently but the job completes.

### Sort Cost for Average Partition

Spark's window sort uses TimSort, which requires approximately 2x the data in memory for merge passes:

```
sort_memory_needed = 2 x in-memory partition size
                   = 2 x 2,250 MB
                   = 4,500 MB (4.5 GB)
```

This already exceeds the 3.6 GB task budget for average partitions. Spark will spill sort runs to disk and merge them, incurring I/O cost but not failing. The O(n log n) sort on 15 million rows at 50 bytes each:

```
n log2 n comparisons:
n          = 15,000,000
log2(n)    = log2(15,000,000) = 23.8
operations = 15,000,000 x 23.8 = 357,000,000 comparisons per partition
```

This is a measurable CPU cost multiplied by 200 shuffle partitions.

### Skewed Case (OOM)

```
skewed_partition_raw    = 9 GB (20% power user concentration)
JVM overhead factor     = 3x
in-memory partition     = 9 GB x 3 = 27 GB

Memory per task         = 3.6 GB
OOM threshold exceeded  = 27 GB >> 3.6 GB by 7.5x
```

Spark's ExternalAppendOnlyUnsafeRowArray begins spilling at spark.sql.windowExec.buffer.spill.threshold = 4,096 rows (default). For a 9 GB partition:

```
rows_before_spill      = 4,096 rows
rows_in_hot_partition  = 180,000,000 rows (20% power user concentration scenario)

spill_cycles = ceil(180,000,000 / 4,096) = 43,945 spill events for this one partition
```

Each spill writes sorted runs to spark.local.dir. The merge phase then reads all runs back. At extreme skew (9 GB partition):

```
spill_write_bytes  = 9 GB written to disk
merge_read_bytes   = 9 GB read back
total_spill_IO     = 18 GB of local disk I/O for one task
```

If local disk is slower than network (common on spinning disk nodes), this single task blocks the entire stage. All other 5 executor cores on that node sit idle waiting for the skewed task to finish — this is the straggler task problem.

---

## WindowExec Spill Mechanics

### Buffer Threshold

```
spark.sql.windowExec.buffer.spill.threshold = 4,096 rows (default)
```

This is the number of rows Spark buffers in memory per window partition before spilling. For a standard user (< 500 events), the buffer is never exceeded — entire user session stays in memory. For a power user (9,000-50,000 events), spill is guaranteed with default settings.

### Increasing the Threshold (Trade-off)

```
If spark.sql.windowExec.buffer.spill.threshold = 100,000:
  Power users with < 100,000 events avoid spill overhead
  Each task holds up to 100,000 x 50 bytes = 5,000,000 bytes = 5 MB in the buffer at once
  Across 6 concurrent tasks per executor: 6 x 5 MB = 30 MB -- negligible
  A power user with exactly 100,001 events: forces one spill cycle instead of many
```

Raising the threshold reduces spill overhead for power users but increases peak memory pressure per task. The memory trade-off is manageable here because individual power users (max 50,000 events x 50 bytes = 2.5 MB) are still small.

---

## DAG Structure

```
Stage 1: Read + Map
  1,200 tasks (input partitions)
  Narrow: read 150 GB Parquet
  No shuffle
       |
       | Shuffle Write
       | 3B rows -> 200 buckets
       | hash(user_id) % 200
       | Shuffle Write: ~150 GB
       |
Stage 2: Window Execution
  200 tasks (shuffle partitions)
  Wide: sort by event_timestamp within each user_id bucket
  WindowExec: LAG + running count
  Shuffle Read: ~150 GB
       |
Write Output
```

Stage 1 ends at the shuffle write. Tasks hash each row's user_id and write to the appropriate shuffle bucket file. 1,200 tasks run in parallel (limited by cluster parallelism).

Stage 2 begins after all shuffle writes complete. 200 tasks read their shuffle partitions, sort by event_timestamp within each user_id, and evaluate the window functions (LAG for session boundary, running count for session_id). Only 200 tasks run — this is the bottleneck stage.

---

## Stage-by-Stage Execution Trace

### Stage 1: Read and Shuffle Write

| Metric | Value | Derivation |
|---|---|---|
| Task count | 1,200 | 153,600 MB / 128 MB = 1,200 input partitions |
| Cluster parallelism | 48 cores | 8 nodes x 6 cores |
| Parallelism waves | ceil(1,200 / 48) = **25 waves** | — |
| Data read per task | 128 MB | maxPartitionBytes |
| Shuffle write per task | ~128 MB / task | Same data, redistributed by hash |
| Total shuffle write | 1,200 x 128 MB = 150 GB | Full dataset crosses the network |
| Task duration (estimated) | ~10-20 seconds | Read + hash + write, network-bound |
| Stage duration (estimated) | 25 waves x 15 sec = **375 seconds** | ~6.25 minutes |

Each task in Stage 1 reads one 128 MB Parquet split, deserializes rows, computes hash(user_id) % 200 for each row, and writes 200 small shuffle files to local disk. The 1,200 tasks x 200 buckets = 240,000 shuffle files created on local disk across all executors.

### Stage 2: Shuffle Read, Sort, and Window Evaluation

| Metric | Value | Derivation |
|---|---|---|
| Task count | 200 | spark.sql.shuffle.partitions = 200 |
| Cluster parallelism | 48 cores | 8 nodes x 6 cores |
| Parallelism waves | ceil(200 / 48) = **5 waves** | — |
| Avg shuffle read per task | 750 MB | 150 GB / 200 partitions |
| Avg rows per task | 15,000,000 | 3B rows / 200 partitions |
| Avg in-memory size per task | ~2.25 GB | 750 MB x 3x JVM overhead |
| Sort memory needed (2x for merges) | ~4.5 GB | 2 x 2.25 GB |
| Memory per task available | ~3.6 GB | See Memory Budget Analysis |
| Sort outcome (average) | **Spills** | 4.5 GB > 3.6 GB |
| Skewed partition shuffle read | 9 GB (20% skew scenario) | 180M rows x 50 bytes |
| Skewed partition in-memory | ~27 GB | 9 GB x 3x JVM overhead |
| Skewed partition outcome | **OOM or extreme spill** | 27 GB >> 3.6 GB |
| Stage duration (estimated) | **Dominated by skewed task** | Straggler holds all waves |

#### Spill Estimate for Average Task

```
In-memory data needed for sort  = 4,500 MB
Available execution memory      = 3,600 MB
Overflow                        = 4,500 - 3,600 = 900 MB must spill to disk

Spill write I/O per average task  = 900 MB
Spill read I/O per average task   = 900 MB (merge phase)
Total spill I/O across Stage 2    = 200 tasks x 1,800 MB = 360,000 MB = 360 GB of local disk I/O
```

---

## Parallelism and Wave Analysis

### Default Configuration (200 Shuffle Partitions)

```
Total executor cores        = 8 executors x 6 cores = 48 cores
Stage 2 task count          = 200
Parallelism waves           = ceil(200 / 48) = ceil(4.17) = 5 waves

Wave utilization:
  Wave 1:   48 tasks -- 100% utilization
  Wave 2:   48 tasks -- 100%
  Wave 3:   48 tasks -- 100%
  Wave 4:   48 tasks -- 100%
  Wave 5:    8 tasks --  8/48 = 16.7% utilization (40 cores idle)

Remaining tasks in Wave 5: 200 - (4 x 48) = 200 - 192 = 8 tasks

Average utilization across waves = (4 x 100% + 1 x 16.7%) / 5 = 83.3%
```

Wave 5 is the final wave with only 8 tasks. If Wave 5 contains the skewed partition, one straggler task delays job completion while 47 cores are idle.

### Tuned Configuration (2,000 Shuffle Partitions)

```
spark.sql.shuffle.partitions  = 2,000

Parallelism waves             = ceil(2,000 / 48) = ceil(41.67) = 42 waves
Avg shuffle read per task     = 150 GB / 2,000   = 75 MB per partition
Avg rows per task             = 3B / 2,000        = 1,500,000 rows per partition
Avg in-memory per task        = 75 MB x 3x        = 225 MB per partition
Sort memory needed            = 2 x 225 MB        = 450 MB -- well within 3.6 GB budget

Power users per partition      = 100,000 / 2,000   = 50 power users per partition
Power user events per partition = 50 x 9,000       = 450,000 events
Hot partition bytes             = 450,000 x 50 B   = 22,500,000 bytes = 22.5 MB raw
In-memory hot partition         = 22.5 MB x 3x     = 67.5 MB -- trivially fits in memory

Remaining tasks in final wave: 2,000 - (41 x 48) = 2,000 - 1,968 = 32 tasks

Wave utilization:
  Waves 1-41: 48 tasks each -- 100% utilization
  Wave 42:    32 tasks      -- 32/48 = 66.7% utilization

Average utilization = (41 x 100% + 1 x 66.7%) / 42 = 98.4%
```

### Comparison Table: 200 vs 2,000 Shuffle Partitions

| Metric | 200 Partitions | 2,000 Partitions | Improvement |
|---|---|---|---|
| Parallelism waves | 5 | 42 | 8.4x more waves |
| Avg partition size | 750 MB | 75 MB | 10x smaller |
| Avg in-memory size | 2.25 GB | 225 MB | 10x less pressure |
| Sort spill (avg task) | 900 MB spill | 0 MB spill | Eliminated |
| Hot partition in-memory | 27 GB (OOM) | 67.5 MB (fine) | OOM eliminated |
| Final wave utilization | 16.7% | 66.7% | 4x better |
| Shuffle file count | 1,200 x 200 = 240,000 | 1,200 x 2,000 = 2,400,000 | 10x more files (cost) |

The 10x increase in shuffle files is the cost. This increases shuffle file management overhead on the driver and the number of network connections during shuffle read. In practice, this is acceptable for most clusters with solid-state local storage.

---

## Bottleneck Identification

### Primary Bottleneck: Skewed Shuffle Partition in Stage 2

**Stage:** Stage 2 (Window Execution)
**Task:** The shuffle partition(s) containing disproportionate power user traffic
**Metric:** Single task requires 27 GB in-memory (at 20% skew concentration) vs. 3.6 GB available
**Root cause:** hash(user_id) % 200 distributes users to partitions, but power users are not uniformly distributed in hash space. A cluster of user_ids with similar hash values (e.g., sequential numeric IDs) can concentrate many power users in the same partition.

**How to detect pre-execution:**

```
Pre-flight diagnostic (execution tracing):
  Step 1: GROUP BY user_id, COUNT(*) AS event_count, ORDER BY event_count DESC LIMIT 100
  
  If top user has 50,000 events:
    Single user = 50,000 x 50 bytes = 2.5 MB (fine on its own)
  
  If top 500 users have avg 9,000 events in one partition:
    500 x 9,000 x 50 bytes = 225,000,000 bytes = 225 MB raw -> 675 MB in JVM (fine at 200 partitions)
  
  Expected hash distribution (random user_ids):
    Users per partition = 10M / 200 = 50,000 (expected)
    Standard deviation  = sqrt(n x p x (1-p))
                        = sqrt(10,000,000 x 0.005 x 0.995)
                        = sqrt(49,750)
                        = ~223 users standard deviation
    Range: 50,000 +/- 223 -- very tight for random IDs
  
  OOM risk is real when user_id values are NOT random (e.g., region-prefixed IDs,
  sequential IDs), causing systematic hash clustering.
  
  Step 2: Validate bucket distribution:
    SELECT hash(user_id) % 200 AS partition_bucket,
           COUNT(DISTINCT user_id) AS users,
           SUM(event_count) AS total_events
    FROM (user_event_counts)
    GROUP BY partition_bucket
    ORDER BY total_events DESC LIMIT 10
  
  If top bucket has total_events >> 15,000,000 (the average per partition),
  skew is real and shuffle partition count must be increased.
```

### Secondary Bottleneck: Low Parallelism in Final Wave

With 200 shuffle partitions and 48 cores, the 5th wave has only 8 tasks. If any of those 8 tasks is a straggler (due to skew or GC pressure), 40 cores sit idle for the entire duration of the straggler. This is the classic "last reducer" problem. With 2,000 partitions, the final wave has 32 tasks — 4x more work in the tail, reducing the idle core problem proportionally.

---

## Optimizer Decisions

### Adaptive Query Execution (AQE)

AQE is enabled by default in Spark 3.0+: spark.sql.adaptive.enabled = true.

**AQE Skew Join Detection** does NOT apply here — this is a window function, not a join. AQE's skew join coalescing only activates for sort-merge joins.

**AQE Coalescing Small Partitions** (spark.sql.adaptive.coalescePartitions.enabled = true) DOES apply. After Stage 1 shuffle write completes, AQE inspects shuffle file sizes. Partitions with very few rows can be coalesced:

```
spark.sql.adaptive.advisoryPartitionSizeInBytes = 64 MB (default)

At 200 shuffle partitions: avg = 750 MB --> AQE will NOT coalesce (750 MB >> 64 MB)
At 2,000 shuffle partitions: avg = 75 MB --> AQE may coalesce some small partitions,
  but hot partitions remain large and stay as-is
```

**AQE does not protect against window function OOM from skewed partitions.** It can coalesce small partitions but cannot split large ones for window functions. Splitting would break window semantics — all rows for a user_id must be in the same partition.

### Broadcast Threshold

No broadcast decision occurs in this job. There is no join — only a window function. The spark.sql.autoBroadcastJoinThreshold (default 10 MB) is irrelevant here.

### Projection Pushdown and Column Pruning

Spark's optimizer pushes column pruning into the Parquet scan. If the window function only needs (user_id, event_timestamp, event_type), and the Parquet file has 20 columns, only the required columns are decoded:

```
5 of 20 columns needed:
  effective read size = 150 GB x (5 / 20) = 37.5 GB actually decoded
  (Columnar format: unused columns are skipped entirely at the block level)

This reduces Stage 1 shuffle write volume by the same proportion:
  Actual shuffle write     = 37.5 GB (5 columns) vs 150 GB (all columns)
  Avg shuffle partition    = 37.5 GB / 200 = 187.5 MB (instead of 750 MB)
  Avg in-memory per task   = 187.5 MB x 3x = 562.5 MB -- well within 3.6 GB
```

Column pruning is one of the most impactful free optimizations for window functions on wide schemas.

---

## Key Numbers Summary

| Metric | Value | Notes |
|---|---|---|
| Input partitions | 1,200 | 153,600 MB / 128 MB |
| Shuffle partitions (default) | 200 | spark.sql.shuffle.partitions |
| Shuffle partitions (tuned) | 2,000 | 10x increase |
| Total executor cores | 48 | 8 x 6 |
| Stage 1 waves | 25 | ceil(1,200 / 48) |
| Stage 2 waves (200 parts) | 5 | ceil(200 / 48) |
| Stage 2 waves (2,000 parts) | 42 | ceil(2,000 / 48) |
| Avg rows per shuffle partition (200) | 15,000,000 | 3B / 200 |
| Avg rows per shuffle partition (2,000) | 1,500,000 | 3B / 2,000 |
| Avg shuffle partition size (200) | 750 MB | 15M x 50 bytes |
| Avg shuffle partition size (2,000) | 75 MB | 1.5M x 50 bytes |
| Avg in-memory partition (200, 3x JVM) | 2,250 MB | 750 MB x 3 |
| Avg in-memory partition (2,000, 3x JVM) | 225 MB | 75 MB x 3 |
| Sort memory needed avg (200 parts) | 4,500 MB | 2 x 2,250 MB |
| Sort memory needed avg (2,000 parts) | 450 MB | 2 x 225 MB |
| Executor unified memory | ~23.8 GB | (40 GB - 300 MB) x 0.6 |
| Execution memory per task (6 cores) | ~3.97 GB | 23.8 GB / 6 |
| Spill for avg task (200 parts) | ~900 MB | 4,500 - 3,600 = 900 MB |
| Spill for avg task (2,000 parts) | 0 MB | 450 MB << 3,600 MB |
| Skewed partition in-memory (20% conc.) | ~27 GB | 9 GB x 3x |
| OOM threshold | ~3.97 GB | execution memory per task |
| OOM risk at 200 partitions | **Yes** | 27 GB >> 3.97 GB |
| OOM risk at 2,000 partitions | **No** | 67.5 MB << 3.97 GB |
| WindowExec spill threshold | 4,096 rows | spark.sql.windowExec.buffer.spill.threshold |
| Top power user (50K events) raw size | 2.5 MB | 50,000 x 50 bytes |
| Power users per partition (2,000 parts) | 50 | 100,000 / 2,000 |
| YARN container per executor | ~44 GB | 40 GB + 4 GB overhead |
| Total cluster YARN memory | ~352 GB | 8 x 44 GB |
| Stage 2 total spill I/O (200 parts, avg) | ~360 GB | 200 x 900 MB x 2 (write+read) |
| Stage 2 total spill I/O (2,000 parts) | ~0 GB | No spill at 75 MB partitions |

---

## Interview Takeaways

**1. The window shuffle partition is a hard memory boundary — there is no sub-partitioning.**

Unlike a sort-merge join where AQE can detect and split skewed partitions, a window function's partitionBy key is a physical constraint. Every row for user_id = X must arrive at the same task before the window can be evaluated. If hash(user_id) % 200 sends 9 GB of data to one task and that task has 3.6 GB of execution memory, the only options are: spill to disk (slow), increase memory per task (fewer cores per executor), or increase shuffle partition count to spread the load. There is no AQE escape hatch for window skew.

**2. Increasing shuffle partition count is the primary lever for window OOM prevention.**

Going from 200 to 2,000 partitions reduces average partition size from 750 MB to 75 MB (10x), eliminates sort spill for average tasks (450 MB needed vs. 3.6 GB available), reduces hot-partition in-memory footprint from 27 GB to 67.5 MB, and improves final-wave parallelism utilization from 16.7% to 66.7%. The cost is 2,400,000 shuffle files vs. 240,000 — a 10x increase in shuffle file management overhead, which is generally acceptable on clusters with solid-state local storage.

**3. The spark.sql.windowExec.buffer.spill.threshold default of 4,096 rows is extremely conservative.**

For a power user with 50,000 events, this means approximately 12 spill cycles minimum. Raising this threshold to 100,000 rows allows the entire power user's session to buffer in memory before any spill decision. At 50 bytes per row, 100,000 rows = 5 MB in the buffer — negligible memory cost for a 3.6 GB budget — but it eliminates the I/O overhead of repeated small spill-and-merge cycles for the vast majority of power users.

**4. Column pruning is a free 4-10x reduction in shuffle volume for wide schemas.**

If the source Parquet has 20 columns but the window function only needs 3 (user_id, event_timestamp, event_type), Spark's optimizer pushes a projection into the Parquet scan. The shuffle write carries only 3 columns worth of data. For this scenario: 150 GB x (3/20) = 22.5 GB shuffled instead of 150 GB. This single optimization eliminates most spill before any tuning of memory or partition counts.

**5. Pre-execution skew detection is more reliable than post-OOM diagnosis.**

Before running the window job, run a GROUP BY user_id COUNT(*) and inspect the distribution — specifically: what is the max events per user, and what does hash(user_id) % N look like across buckets? If any bucket holds > 5x the average event count, the window job will produce a straggler. The diagnostic query costs one full scan of the data but prevents an OOM failure that requires re-running the entire multi-hour job. In production, this check should be part of the pipeline's pre-flight validation.
