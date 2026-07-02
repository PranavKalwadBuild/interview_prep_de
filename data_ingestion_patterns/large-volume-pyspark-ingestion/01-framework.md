# 5-Part Production Framework: Large-Volume PySpark Ingestion

**Anchor problem**: Process 10 TB of daily Parquet data from S3 into a data warehouse within 3 hours.

This framework gives you a complete, defensible answer to any cluster-sizing question in a data engineering interview. Work through all five parts in order. Each part builds on the previous one.

---

## Part 1 — The 4 Golden Production Guardrails

These four constants form the foundational blueprint for any heavy data warehouse ingestion workload on compressed columnar formats like Parquet or ORC. They are not arbitrary — each number has a specific engineering reason behind it.

| Guardrail | Value | Rule |
|---|---|---|
| Safety Buffer (SLA Design) | 2/3 of business SLA | Always complete within 2/3 of the SLA window to absorb cloud network dips, node drops, and volume surges |
| Worker Core Limit (JVM GC Guardrail) | 5 cores per executor max | Sweet spot for storage read/write parallelism without triggering Stop-the-World GC pauses |
| Core Throughput (Operational Baseline) | 25 MB/s per core | Conservative real-world coefficient accounting for network encryption, object store throttling, and write-side encoding penalty |
| RAM-to-Core Ratio (I/O Buffer) | 8 GB total container RAM per core | After Spark's fractional memory splits, each thread retains ~2 GB true Execution Memory — avoids spilling Parquet row groups to disk |

### Why each number — not just what

**Safety Buffer (2/3 of SLA)**
Cloud infrastructure is probabilistic, not deterministic. A 3-hour SLA does not mean you have 3 hours of guaranteed compute. Node drops, spot preemptions, S3 throttling spikes, and reshuffles can add 20-40 minutes to any run. Designing to 2/3 of SLA means you finish in 2 hours on the anchor problem, leaving a full hour of operational buffer. This is not conservatism — it is the difference between a pipeline that passes its SLA 99% of months and one that misses it every time there is a cloud hiccup.

**Worker Core Limit (5 cores per executor)**
The JVM garbage collector becomes a bottleneck above 5 cores per executor for I/O-heavy Parquet workloads. With more cores, multiple threads compete for the same GC cycle, causing Stop-the-World pauses that freeze the entire executor — not just one task. 5 cores is the distributed systems sweet spot: enough parallelism to saturate the local storage bus, not so much that GC becomes a tax on throughput. This is a hard limit, not a soft guideline.

**Core Throughput (25 MB/s per core)**
Raw network bandwidth in a cloud executor is much higher — often 500 MB/s to 1 GB/s. The 25 MB/s figure is a conservative operational coefficient that factors in: (1) object store throttling at LIST and GET scale, (2) TLS/encryption overhead on the wire, (3) write-side penalty from Parquet footer writing and file commit protocols (S3A committer, rename operations), and (4) Spark's own task scheduling overhead. Production data from AWS EMR and Databricks clusters consistently yields 20-30 MB/s per core for Parquet-to-Parquet transforms. 25 MB/s is the safe planning number.

**RAM-to-Core Ratio (8 GB per core)**
An executor with 5 cores needs 40 GB total container RAM (5 × 8 GB). Of the 36 GB heap (the remaining 4 GB is off-heap overhead), Spark reserves 60% (21.6 GB) for its managed memory pool. That pool is split 50/50 between Execution Memory (processing) and Storage Memory (caching). Execution Memory is what each thread uses to unpack and process Parquet row groups — each thread gets ~2.16 GB. A Parquet row group is typically 128 MB on disk but expands to 500 MB-1 GB uncompressed in the JVM. 2 GB per thread is just enough to hold one row group without spilling. Going below 8 GB per core causes spill to local disk — a 5-10× throughput drop.

---

## Part 2 — The Master Sizing Blueprint

Two separate sizing decisions: the Driver (vertical, metadata) and the Executors (horizontal, data).

### Driver Node — Sized Vertically for Metadata

The Driver does not process data rows. It coordinates the entire cluster: file listing, DAG construction, task scheduling, and heartbeat management. For multi-terabyte datasets spread across thousands of files, a weak driver will OOM during the file-listing phase before a single row is processed.

| Parameter | Value | Flag |
|---|---|---|
| Driver Cores | 8 | `--driver-cores 8` |
| Driver Heap Memory | 32 GB | `--driver-memory 32g` |
| Driver Overhead Memory | 4 GB | `--conf spark.driver.memoryOverhead=4000m` |
| **Total Driver Footprint** | **36 GB RAM, 8 cores** | |

**Why these numbers:**
- 8 cores: enough concurrent threads to manage task scheduling and executor heartbeats across 45+ executors without queuing delays
- 32 GB heap: holds the full file path list, block location map, and execution DAG for thousands of files without OOM
- 4 GB overhead: off-heap buffer protecting the container from network buffer saturation — this is what absorbs the spike when 45 executors all report task completion simultaneously

**What happens with a weak driver:** On a 10 TB dataset split into 10,000 files, the driver must resolve all 10,000 file paths during planning. A driver with 8 GB heap will OOM here, before a single executor starts. The job dies during initialization — a confusing failure mode that is often misdiagnosed as a data problem.

### Executor Node — Sized Horizontally for Data

Executors handle row-level processing. The key operational rule: **lock this unit**. Never change executor cores or executor memory based on dataset size. Only change the number of executors.

| Parameter | Value | Flag |
|---|---|---|
| Executor Cores | 5 | `--executor-cores 5` |
| Executor Heap Memory | 36 GB | `--executor-memory 36g` |
| Executor Overhead Memory | 4 GB | `--conf spark.executor.memoryOverhead=4000m` |
| **Total Executor Footprint** | **40 GB RAM, 5 cores** | |

### Spark's Internal Memory Fractions at 36 GB Heap

Understanding how Spark actually allocates the 36 GB helps you explain why 36 GB and not 20 GB or 64 GB.

| Memory Region | Fraction | Amount | Purpose |
|---|---|---|---|
| Reserved Memory | Fixed | 300 MB | Spark internal structures — untouchable |
| User Memory | (1 - 0.6) = 40% of usable | ~14.3 GB | Application objects, UDF state, collected results |
| Spark Managed Memory (`spark.memory.fraction = 0.6`) | 60% of usable | ~21.6 GB | Execution + Storage combined pool |
| Execution Memory (`spark.memory.storageFraction = 0.5` of managed) | 50% of managed | ~10.8 GB | Active task processing — unpacking row groups, aggregations |
| Storage Memory | 50% of managed | ~10.8 GB | Cached RDDs/DataFrames, broadcast variables |
| **Per-core Execution Memory** | 10.8 GB / 5 cores | **~2.16 GB per thread** | What each task thread actually has for a Parquet row group |

The 2.16 GB per thread is the critical number. A Parquet row group (128 MB compressed) expands to 400 MB - 1 GB uncompressed in the JVM. 2.16 GB per thread is enough headroom. Drop below 8 GB per core in your sizing, and this per-thread budget drops below 1 GB — spill begins, throughput collapses.

> **Rule of thumb**: The executor shape (5 cores, 40 GB) is an atomic unit. Treat it like a VM instance type. You would not change the instance type for every workload — you change the number of instances. Same logic applies here.

---

## Part 3 — The Automated Scaling Formula

Given any dataset size and business SLA, this 3-step formula produces the exact executor count. Practice this until you can write it from memory.

### The Formula

```
Step 1: Target Velocity
  Safe SLA window     = (2/3) x Business SLA in seconds
  Target velocity     = Total Data (GB) / Safe SLA window (seconds)

Step 2: Total Cores Needed
  Throughput per core = 0.025 GB/s  (25 MB/s operational baseline)
  Raw cores needed    = Target velocity / 0.025
  Apply safety factor = Raw cores x 4

Step 3: Number of Executors
  Executor count      = Total cores / 5
```

### Worked Example — The Anchor Problem (10 TB, 3-hour SLA)

```
Step 1: Target Velocity
  Business SLA        = 3 hours = 10,800 seconds
  Safe SLA window     = (2/3) x 10,800 = 7,200 seconds (2 hours)
  Total data          = 10 TB = 10,000 GB
  Target velocity     = 10,000 GB / 7,200 s = 1.39 GB/s

Step 2: Total Cores Needed
  Throughput per core = 0.025 GB/s
  Raw cores needed    = 1.39 / 0.025 = 55.6 cores
  x 4 safety factor   = 55.6 x 4 = ~222 cores

Step 3: Number of Executors
  Cores per executor  = 5
  Executors needed    = 222 / 5 = ~45 executors
```

**Answer**: 45 executors, each with 5 cores and 40 GB RAM, for a total of 225 cores and 1,800 GB cluster RAM.

### Scaling Table — Common Interview Scenarios

| Dataset | Business SLA | Safe Window | Target Velocity | Total Cores | Executors |
|---|---|---|---|---|---|
| 1 TB | 1 hour | 40 min (2,400 s) | 0.42 GB/s | 67 | 14 |
| 10 TB | 3 hours | 2 hours (7,200 s) | 1.39 GB/s | 222 | 45 |
| 50 TB | 6 hours | 4 hours (14,400 s) | 3.47 GB/s | 555 | 111 |
| 100 TB | 12 hours | 8 hours (28,800 s) | 3.47 GB/s | 555 | 111 |
| 500 TB | 24 hours | 16 hours (57,600 s) | 8.68 GB/s | 1,389 | 278 |

> **Note on the 100 TB row**: The SLA is generous relative to 50 TB. The formula still produces the same velocity as 50 TB because more clock time is available. The cluster is actually smaller relative to data volume — this is intentional. The formula optimizes for meeting the SLA, not maximizing throughput.

---

## Part 4 — Production-Ready spark-submit Command

This is the command to write on the whiteboard. Every flag has a reason — be ready to explain any of them.

```bash
spark-submit \
    --master yarn \
    --deploy-mode cluster \
    --driver-cores 8 \
    --driver-memory 32g \
    --conf spark.driver.memoryOverhead=4000m \
    --num-executors 45 \
    --executor-cores 5 \
    --executor-memory 36g \
    --conf spark.executor.memoryOverhead=4000m \
    --conf spark.sql.shuffle.partitions=1110 \
    --conf spark.default.parallelism=1110 \
    --conf spark.sql.adaptive.enabled=true \
    --conf spark.sql.adaptive.skewJoin.enabled=true \
    --conf spark.sql.sources.parallelPartitionDiscovery.parallelism=64 \
    --conf spark.sql.properties.mergeSchema=false \
    ingestion_job.py
```

### Config Explanation Table

Every flag, every value, and the exact reason behind it:

| Config | Value | Why |
|---|---|---|
| `--master yarn` | yarn | Cluster manager — use `k8s` if on Kubernetes |
| `--deploy-mode cluster` | cluster | Driver runs on cluster, not client machine — survives laptop disconnection |
| `--driver-cores 8` | 8 | Multi-threaded file listing and task scheduling |
| `--driver-memory 32g` | 32 GB | Holds file path list, DAG metadata for 10,000+ files |
| `spark.driver.memoryOverhead` | 4000m | Off-heap buffer for network spikes during task reporting |
| `--num-executors 45` | 45 | Result of Step 3 of the scaling formula |
| `--executor-cores 5` | 5 | JVM GC guardrail — never exceed 5 |
| `--executor-memory 36g` | 36 GB | 8 GB per core; yields ~2.16 GB per thread after Spark memory fractions |
| `spark.executor.memoryOverhead` | 4000m | Off-heap buffer — absorbs network/JVM native overhead per executor |
| `spark.sql.shuffle.partitions` | 1110 (= 222 cores × 5) | Maps shuffle tasks 1:1 to cores; keeps cluster fully saturated without overloading driver with too many tiny trackers |
| `spark.default.parallelism` | 1110 | Same as above — covers RDD operations not governed by `sql.shuffle.partitions` |
| `parallelPartitionDiscovery.parallelism` | 64 | Driver uses 64 concurrent threads to list files from S3 — eliminates initialization bottleneck on large datasets |
| `mergeSchema` | false | Skips footer-level schema check across all Parquet files — eliminates 90% of driver metadata overhead during read planning |
| `adaptive.enabled` | true | AQE dynamically coalesces small shuffle partitions, applies broadcast joins at runtime when possible |
| `skewJoin.enabled` | true | AQE auto-splits oversized partitions before they bottleneck a single thread or cause OOM |

> **Common interview trap**: If you write `mergeSchema=false`, be prepared to answer "what if schemas do differ between files?" The answer: catch schema drift at ingestion time via explicit schema validation before reading, not during the read (see `03-schema-evolution.md`).

---

## Part 5 — The Interview Final Pitch

This is the closing paragraph you deliver after walking through the framework. It signals operational authority — not just theoretical knowledge.

---

### The Verbatim Pitch

> "To guarantee a production-grade ingestion pipeline, I establish a firm separation of concerns: I vertically size the Driver to 8 cores and 36 GB of total memory to easily manage multi-threaded file listing and task tracking without risk of a metadata-driven OOM crash. For the computing layer, I scale out horizontally using a locked container unit of 5 cores and 40 GB of total memory per executor. This specific profile is structurally optimized to hold uncompressed Parquet row groups in memory without risking local disk spilling. I dynamically adjust the number of these executors based on a conservative throughput coefficient of 25 MB/s per core, while matching our partitions to a 5:1 ratio relative to total cores to keep the cluster perfectly balanced and saturated."

---

### Sentence-by-Sentence Annotation

What each sentence signals to the interviewer:

| Phrase | What it demonstrates |
|---|---|
| "firm separation of concerns" | You understand that Driver and Executors have fundamentally different failure modes and must be sized independently |
| "vertically size the Driver" | You know the Driver is a metadata bottleneck, not a data bottleneck — it scales vertically (bigger), not horizontally (more) |
| "8 cores and 36 GB of total memory" | You have specific numbers memorized, not vague approximations — signals real production experience |
| "metadata-driven OOM crash" | You know the specific failure mode: file listing OOM, not row processing OOM — shows depth |
| "locked container unit" | You understand why executor shape must never change — GC tuning, memory fraction math, and operational predictability all break if you resize the container |
| "structurally optimized to hold uncompressed Parquet row groups" | You know what happens inside the JVM when Parquet is read: decompression, column materialization, row assembly — and that it requires headroom |
| "conservative throughput coefficient of 25 MB/s" | You have a real-world operational baseline number, not a theoretical peak — signals you have debugged slow jobs and measured actual throughput |
| "5:1 ratio relative to total cores" | You know the shuffle partition tuning rule and its rationale — not cargo-culted, derived from core count |
| "keep the cluster perfectly balanced and saturated" | You understand the goal: no idle cores, no overloaded tasks, no driver overwhelmed with tiny task trackers |

---

### What to Do After the Pitch

The pitch invites follow-up questions. Be ready for:

1. **"What if the data volume changes month to month?"** → The formula auto-adjusts. Only `--num-executors` changes. Everything else stays locked.
2. **"What if there's data skew?"** → AQE handles it via `skewJoin.enabled`. For severe skew, add a salt key before the join (see `12-multi-tenant-cluster.md`).
3. **"What if schema changes?"** → `mergeSchema=false` means the job fails fast on schema drift. That is intentional — catch it at ingestion, not in the DW (see `03-schema-evolution.md`).
4. **"What if files are corrupt?"** → Use `badRecordsPath` to quarantine bad files, then process the clean set (see `04-corrupt-files.md`).
5. **"How do you prevent duplicate loads?"** → Idempotent writes with Delta Lake `MERGE` or Iceberg's upsert semantics (see `05-exactly-once-ingestion.md`).
