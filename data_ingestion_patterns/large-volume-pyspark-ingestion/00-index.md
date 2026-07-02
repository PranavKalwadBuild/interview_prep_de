# Large-Volume PySpark Ingestion — Master Reference

## Anchor Problem

> **Process 10 TB of daily Parquet data from S3 into a data warehouse within 3 hours.**

Everything in this reference folder is sized, calibrated, and validated against this anchor. When an interviewer presents a different scale, apply the formula from `01-framework.md` and adjust.

---

## File Index

| # | File | Topic |
|---|---|---|
| 01 | [01-framework.md](01-framework.md) | 5-Part Production Framework: Guardrails → Sizing → Formula → spark-submit → Pitch |
| 02 | [02-data-size-reference.md](02-data-size-reference.md) | Records ↔ GB/TB conversion table + practical examples |
| 03 | 03-schema-evolution.md | Schema drift, evolution, mergeSchema trade-offs |
| 04 | 04-corrupt-files.md | Malformed, partially written, corrupt Parquet/ORC files |
| 05 | 05-exactly-once-ingestion.md | Duplicate files, replayed batches, idempotency guarantees |
| 06 | 06-object-store-race-conditions.md | S3/GCS listing races, eventual consistency, manifest-based ingestion |
| 07 | 07-structured-streaming.md | Checkpoints, watermarks, replay recovery |
| 08 | 08-source-bottlenecks.md | JDBC, Kafka, API, SFTP/file-drop specific limits |
| 09 | 09-data-quality-quarantine.md | DQ validation, quarantine paths, row-count reconciliation |
| 10 | 10-metadata-catalog-failures.md | Missing partitions, stale catalog, path mismatches |
| 11 | 11-security-governance.md | PII masking, credential expiry, access failures |
| 12 | 12-multi-tenant-cluster.md | Noisy neighbors, executor preemption, spot interruptions |

---

## Core Mental Model

```
Object Store (S3/GCS/ADLS)
    |  [file listing + partition discovery]
    v
Spark Executors (read + transform)
    |  [optional shuffle]
    v
Sink (Delta Lake / Iceberg / Hive / JDBC DW)

Bottleneck priority (most common first):
1. Object store LIST calls (small files, no manifest)
2. Executor parallelism mismatch (too few/many tasks)
3. Data skew (one task runs 100x longer than others)
4. Shuffle size (OOM / GC pressure)
5. Sink write throughput (DW ingest rate limit)
6. Schema mismatch (mergeSchema overhead)
7. Security / credential rotation mid-job
```

Knowing this hierarchy lets you diagnose any slow or failing ingestion job in a structured way — start at the top and rule out each layer before moving to the next.

---

## Quick Formula Cheat Sheet

From the 5-part framework in `01-framework.md`. Memorize these five lines — they form the entire cluster sizing answer in an interview.

```
Safety window        = (2/3) x business SLA
Target velocity      = total_GB / safety_window_seconds
Total cores needed   = (target_velocity / 0.025 GB/s) x 4
Executor count       = total_cores / 5
shuffle.partitions   = total_cores x 5
```

Applied to the anchor problem (10 TB, 3-hour SLA):

```
Safety window        = (2/3) x 10,800 s = 7,200 s (2 hours)
Target velocity      = 10,000 GB / 7,200 s = 1.39 GB/s
Total cores needed   = (1.39 / 0.025) x 4 = 222 cores
Executor count       = 222 / 5 = ~45 executors
shuffle.partitions   = 222 x 5 = 1,110
```

---

## Interview Trigger Table

When the interviewer introduces one of these phrases, pivot immediately to the corresponding file. Do not try to answer cold — the file has the structured answer.

| If the interviewer says... | Go to file |
|---|---|
| "schema changed overnight", "new column appeared", "schema mismatch" | 03-schema-evolution.md |
| "files are corrupt", "job crashes on read", "bad Parquet footer" | 04-corrupt-files.md |
| "pipeline re-ran twice", "duplicate rows in DW", "replay happened" | 05-exactly-once-ingestion.md |
| "S3 listing slow", "files missing right after write", "eventual consistency" | 06-object-store-race-conditions.md |
| "real-time", "streaming", "Kafka to Delta", "micro-batch" | 07-structured-streaming.md |
| "reading from Oracle/MySQL", "JDBC timeout", "API rate limit" | 08-source-bottlenecks.md |
| "bad rows", "null violations", "row count mismatch", "data quality" | 09-data-quality-quarantine.md |
| "partition not found", "Hive metastore stale", "path mismatch" | 10-metadata-catalog-failures.md |
| "PII", "GDPR", "credentials expired", "access denied mid-job" | 11-security-governance.md |
| "job killed mid-run", "preempted", "spot instance", "noisy neighbor" | 12-multi-tenant-cluster.md |

---

## How to Use This Reference in an Interview

1. **Always anchor the answer first.** State the problem size in GB/TB and the SLA window before touching any config.
2. **Run the formula out loud.** Interviewers want to see the reasoning, not just the final executor count.
3. **Lock the executor shape.** Never change `--executor-cores` or `--executor-memory`. Only change `--num-executors`.
4. **Recite the spark-submit block from memory** (Part 4 of `01-framework.md`). Explain every flag — silence on a flag signals cargo-culting.
5. **Pivot by keyword.** Use the trigger table above to know exactly which edge-case file to pull from when the interview shifts direction.
