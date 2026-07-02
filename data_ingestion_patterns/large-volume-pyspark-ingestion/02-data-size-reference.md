# Data Size Reference — Records ↔ GB/TB Conversion

**Purpose**: Give accurate size estimates when an interviewer states a record count, or record count estimates when they state a file size. Both directions matter. Wrong estimates in an interview signal that you have never worked with data at scale.

---

## Section 1 — The Core Insight: Row Size Varies by Schema Width

There is no single "bytes per row" number. The right answer depends on table shape. Three archetypes cover 90% of real-world tables:

| Table Archetype | Raw bytes/row | Compressed Parquet bytes/row | Typical examples |
|---|---|---|---|
| **Narrow** (10-20 columns, integers/dates only) | 100-200 bytes | 30-50 bytes | Dimension tables, lookup tables, status logs |
| **Standard fact table** (30-60 columns, mixed types, some strings) | 300-500 bytes | 80-150 bytes | Order events, transactions, user sessions |
| **Wide/semi-structured** (100+ columns, JSON blobs, arrays, nested) | 1,000-5,000 bytes | 300-1,000 bytes | Clickstream with properties, ML feature tables, audit logs |

> **Interview default**: Unless the interviewer specifies schema width, use the standard fact table archetype (~100 bytes/row compressed). This matches the anchor problem (10 TB, ~100 billion rows) and is the most common table shape in a data warehouse.

---

## Section 2 — Records to Size (Standard Fact Table, ~100 bytes/row compressed)

| Records | Compressed Size (Parquet) | Uncompressed Equivalent | Real-world Example |
|---|---|---|---|
| 1 million (1M) | ~100 MB | ~300-500 MB | Small daily delta load, single-region event table |
| 10 million (10M) | ~1 GB | ~3-5 GB | Medium event table, one day of activity |
| 100 million (100M) | ~10 GB | ~30-50 GB | Large transactional table, one month |
| 1 billion (1B) | ~100 GB | ~300-500 GB | E-commerce orders, one year |
| 10 billion (10B) | ~1 TB | ~3-5 TB | Clickstream data, one year, mid-size platform |
| 100 billion (100B) | ~10 TB | ~30-50 TB | Telco CDRs, financial tick data, large-scale clickstream |
| 1 trillion (1T) | ~100 TB | ~300-500 TB | Global streaming platform, multi-year event history |

---

## Section 3 — Size to Records (Standard Fact Table, ~100 bytes/row compressed)

| Compressed Size | Approx Records | Notes |
|---|---|---|
| 1 GB | ~10 million rows | Fits in a single Spark executor's memory — trivial job |
| 10 GB | ~100 million rows | Single-partition run feasible, no real parallelism needed |
| 100 GB | ~1 billion rows | Mid-size job — 5-10 executors is sufficient |
| 1 TB | ~10 billion rows | The framework's lower anchor — 14 executors (per scaling table) |
| 10 TB | ~100 billion rows | The primary anchor problem — 45 executors per the framework |
| 100 TB | ~1 trillion rows | Enterprise scale, 450-500 executors — multi-hour job on large cluster |
| 1 PB | ~10 trillion rows | Rare in interviews, but exists: financial exchanges, telcos |

---

## Section 4 — Row Width Impact Table

Schema width changes everything. The same 1 TB of compressed Parquet represents wildly different record counts depending on whether those columns are integers or JSON blobs.

| Table Type | Compressed bytes/row | Records per GB | Records per TB |
|---|---|---|---|
| Narrow (IDs + dates only) | ~30 bytes | ~33 million | ~33 billion |
| Standard fact table | ~100 bytes | ~10 million | ~10 billion |
| Wide analytics table | ~300 bytes | ~3.3 million | ~3.3 billion |
| Semi-structured (nested JSON, arrays) | ~1,000 bytes | ~1 million | ~1 billion |

### How to use this in an interview

If the interviewer says "we have a clickstream table with 100+ event properties stored as a JSON column", immediately recalibrate: that 10 TB is not 100 billion rows — it is closer to 10-30 billion rows. The distinction matters for partition sizing, driver memory planning, and join strategy.

---

## Section 5 — Parquet Compression Ratios by Data Type

Not all columns compress equally. Knowing these ratios helps you estimate how large a dataset is in raw CSV versus Parquet, and explain why Parquet compression is so much better for some column types.

| Data Type | Compression Factor (vs raw CSV) | Mechanism | Notes |
|---|---|---|---|
| Integer columns | 4-8x | Run-length encoding, delta encoding | Very effective — sequential IDs compress near-perfectly |
| String columns (low cardinality, e.g. status codes, country) | 6-10x | Dictionary encoding | Dictionary encodes all distinct values once, stores indexes |
| String columns (high cardinality, e.g. UUIDs, email addresses) | 1.5-2x | No dictionary benefit; near-random bytes | UUID columns are nearly incompressible |
| Timestamp columns | 3-5x | Delta encoding on sorted data | Assumes timestamps are roughly ordered — out-of-order data compresses worse |
| Nested / JSON blobs | 2-3x | Limited structure for columnar | JSON is stored as a string column — columnar layout provides minimal benefit |
| Float/Double numerical | 2-4x | Gorilla compression, XOR encoding | Depends heavily on value distribution |

### Key takeaway for interviews

When someone says "our Parquet files are 10 TB", the corresponding CSV would be 30-80 TB. When Spark reads those 10 TB Parquet files and fully materializes them in memory (uncompressed JVM objects), you are looking at 50-100 TB of heap pressure. This is why you never `collect()` a large DataFrame — you would pull 50-100 TB of uncompressed data into the driver heap.

---

## Section 6 — Quick Mental Math Rules

Five rules to memorize. Use these to sanity-check any estimate under time pressure.

**Rule 1**: For a typical fact table, 1 TB Parquet ≈ 10 billion rows.

**Rule 2**: Raw CSV is 3-5x larger than Parquet for the same data. If someone gives you a CSV size, divide by 4 to estimate Parquet equivalent.

**Rule 3**: In-memory uncompressed data (JVM heap) is 5-10x larger than Parquet on disk. Spark reads Parquet off disk, decompresses, and materializes columns as JVM objects — each row expands significantly. Never assume your 10 TB Parquet job needs only 10 TB of cluster memory.

**Rule 4**: 1 executor with 36 GB heap and 5 cores processes approximately 500 MB of Parquet per minute at the 25 MB/s per core baseline. (5 cores × 25 MB/s × 60 s = 7,500 MB ≈ 7.5 GB/min per executor — but including overhead, planning, and write time, 500 MB/min per executor is a conservative planning number.)

**Rule 5**: 10 TB Parquet expands to ~50-100 TB in Spark memory if fully materialized. Never use `collect()`, `toPandas()`, or unbounded `show()` on large DataFrames. Always use `write()` to push results to a sink.

---

## Section 7 — Interview Calibration Table

When the interviewer states a problem size, use this table to instantly know what it means in concrete terms and what executor count the framework produces.

| Problem says... | What it actually means | Framework executor count | Signal this gives the interviewer |
|---|---|---|---|
| "1 TB daily" | ~10 billion rows, standard table | 14 executors | Small-to-mid job — should complete in minutes on a modest cluster |
| "10 TB daily" | ~100 billion rows | 45 executors | The anchor problem — framework answer applies directly |
| "100 TB daily" | ~1 trillion rows | ~450-500 executors | Enterprise scale — ask about cluster budget and time window |
| "streaming, 1 million events/sec" | ~100 MB/s continuous ingestion | 10-20 executors for micro-batch | Latency matters more than throughput here; switch to streaming framework discussion |
| "100 million rows daily CDC" | ~10 GB delta per day | 3-5 executors | Trivially small — caution: the CDC overhead may exceed the data size |
| "500 million rows daily" | ~50 GB delta | 5-8 executors | Small cluster job; focus shifts to correctness (CDC, dedup) not scale |
| "10 billion rows historical backfill" | ~1 TB | 14 executors | Single large batch — partitioned write, simple scaling problem |

### Reading the signals

- **Very large dataset + tight SLA**: The interviewer wants to see the scaling formula applied.
- **Medium dataset + correctness requirements**: The interviewer wants to see deduplication, CDC, exactly-once semantics (files 05, 09).
- **Streaming framing**: The interviewer is pivoting to checkpointing, watermarks, and late data (file 07).
- **"Historical backfill" or "one-time migration"**: Focus on partition pruning, cluster sizing, and avoiding shuffle — not operational monitoring.
