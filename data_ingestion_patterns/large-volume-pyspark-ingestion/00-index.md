<!-- data-ingestion-patterns: Large-Volume PySpark Ingestion — Index -->

# Large-Volume PySpark Ingestion — Index

## The Anchor Problem
> "Process 10 TB of daily Parquet data from S3 into a data warehouse within 3 hours."

This folder covers 7 scenarios that decompose this problem and its variants.

---

## Files

| # | File | Core Problem |
|---|------|-------------|
| 01 | [baseline-flat-parquet-ingest.md](01-baseline-flat-parquet-ingest.md) | 10 TB flat read → DW write, partition math, cluster sizing |
| 02 | [partitioned-data-with-skew.md](02-partitioned-data-with-skew.md) | Skewed date/region partitions, AQE, salting |
| 03 | [incremental-delta-merge.md](03-incremental-delta-merge.md) | Daily upsert into existing DW table at scale |
| 04 | [small-files-problem.md](04-small-files-problem.md) | 10 TB split into millions of tiny files, S3 listing cost |
| 05 | [oom-and-shuffle-tuning.md](05-oom-and-shuffle-tuning.md) | OOM crashes, shuffle spill, GC pressure |
| 06 | [late-arriving-partitions.md](06-late-arriving-partitions.md) | Data arrives out of order, partition overwrite idempotency |
| 07 | [sla-breach-triage-playbook.md](07-sla-breach-triage-playbook.md) | Job running behind — how to diagnose and recover |

---

## Common Mental Model

```
S3 (Parquet) → Spark Executors → Shuffle (optional) → DW Sink

Throughput bottlenecks (in order of frequency):
1. S3 LIST calls (small files)
2. Executor parallelism mismatch
3. Data skew → one task runs 100x longer
4. Shuffle size → GC / OOM
5. Sink write throughput (DW ingest rate)
```

## Key Formula Cheat Sheet

```
Target parallelism     = Total data size / Target partition size
Target partition size  = 128 MB–512 MB (sweet spot for Parquet)
Executor count         = Total cores / cores-per-executor
Total memory needed    = partitions-in-flight × partition-size × 3.5 (overhead multiplier)
SLA check              = (partition count / total parallelism) × avg task time < SLA
```
