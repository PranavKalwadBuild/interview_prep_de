Change log:

1. Another implementation I need you to do. I want all the SQL patterns to be implemented on a sample of data seperately. Now this sample data should be
  real world data with flaws. When I say flaws I mean it should have NULLs, duplicates skew etc. You can take the domain of employee, department, manager
  etc for creating the tables. The idea is to understand and implement each of these patterns using ANSI SQL. This should be a seperate directory in
  itself and it should have only .sql and .md files. This should contain DDLs, DMLs and all patterns covered in @sql-patterns/ folder. Technically this
  is the implementation of the entire @sql-patterns/ folder using standard data. Get started with this. I do not want .py files which you would run and
  estabilish a connection with DBs. I would copy and paste these SQLs as and when required to implement and understand the patterns. Also make sure to
  create a database called sql-patterns. All the tables are to be created in this database itself. I will be using MySQL to run these sql scripts. Let me
  know if you have any clarifying questions before you get started

2. large-volume-pyspark-ingestion expected to follow the below pattern:

    a. Part 1: The 4 Golden Production GuardrailsThese four metrics form your foundational blueprint for any heavy data warehouse     ingestion workload handling compressed columnar formats like Parquet or ORC:The Safety Buffer (SLA Design): Always design your compute capacity to complete within $2/3$ of the business SLA window. This leaves a $1/3$ operational buffer to absorb unexpected cloud network dips, node drops, or data volume surges.The Worker Core Limit (JVM GC Guardrail): 5 cores per executor max. This is the strict distributed systems sweet spot that maximizes storage read/write parallelism while preventing crippling Java Virtual Machine (JVM) "Stop-the-World" Garbage Collection pauses.The Core Throughput (Operational Baseline): 25 MB/s per core of raw compressed data. This conservative, real-world coefficient factors in network encryption overhead, object store throttling, and the write-side penalty (encoding and file-committing).The RAM-to-Core Ratio (I/O Buffer): 8 GB of total container RAM per core. This ensures that after Spark's internal fractional memory splits, each thread retains enough true Execution Memory (~2 GB) to unpack large Parquet row groups without spilling data to local disk.Part 2: The Master Sizing Blueprint1. The Driver Node (Sized Vertically for Metadata)The Driver does not process data rows, but it coordinates the entire cluster. For multi-terabyte datasets spread across thousands of files, a weak driver will instantly throw an Out-Of-Memory (OOM) error during the file-listing phase.Driver Cores: 8 Cores (--driver-cores 8) — Provides enough concurrent threads to manage worker task scheduling and heartbeats.Driver Heap Memory: 32 GB (--driver-memory 32g) — Stores file paths, block locations, and execution DAG metadata.Driver Overhead Memory: 4 GB (--conf spark.driver.memoryOverhead=4000m) — A 10% off-heap buffer protecting the container from network buffer saturation.Total Driver Footprint: 36 GB RAM | 8 Cores2. The Worker Node / Executor (Sized Horizontally for Data)Workers handle the row-level heavy lifting. Instead of changing container sizes based on the dataset, keep this optimized executor unit locked and simply scale the number of instances up or down to match your payload.Executor Cores: 5 Cores (--executor-cores 5)Executor Heap Memory: 36 GB (--executor-memory 36g)Executor Overhead Memory: 4 GB (--conf spark.executor.memoryOverhead=4000m)Total Executor Footprint: 40 GB RAM | 5 CoresPart 3: The Automated Ingestion Scaling FormulaTo find exactly how many of these standard 5-core executor units your cluster needs to process a given data volume, use this 3-step progression:$$\text{Step 1: Target Velocity (GB/s)} = \frac{\text{Total Data Volume in GB}}{\text{Safe SLA Window } (\frac{2}{3} \times \text{Business SLA in Seconds})}$$$$\text{Step 2: Total Cores Needed} = \frac{\text{Target Velocity}}{0.025\text{ GB/s}} \times 4\text{ (Production Safety Factor)}$$$$\text{Step 3: Number of Executors} = \frac{\text{Total Cores Needed}}{5}$$Part 4: Production-Ready spark-submit CommandWhen asked to summarize your infrastructure choices on the whiteboard, write out this finalized deployment script:Bashspark-submit \
    --master yarn / k8s \
    --deploy-mode cluster \
    --driver-cores 8 \
    --driver-memory 32g \
    --conf spark.driver.memoryOverhead=4000m \
    --num-executors [Result of Step 3] \
    --executor-cores 5 \
    --executor-memory 36g \
    --conf spark.executor.memoryOverhead=4000m \
    --conf spark.sql.shuffle.partitions=[Total Cores *5] \
    --conf spark.default.parallelism=[Total Cores* 5] \
    --conf spark.sql.adaptive.enabled=true \
    --conf spark.sql.adaptive.skewJoin.enabled=true \
    --conf spark.sql.sources.parallelPartitionDiscovery.parallelism=64 \
    --conf spark.sql.properties.mergeSchema=false \
    ingestion_job.py
    Why these exact optimizations are appended:spark.sql.shuffle.partitions & default.parallelism: Set to 5× the total core count. This maps tasks perfectly to your processing cores, keeping your cluster fully saturated without overloading the Driver node with tens of thousands of tiny task trackers.parallelPartitionDiscovery.parallelism=64: Forces the Driver to utilize up to 64 concurrent threads to discover and list files from object storage in parallel, drastically reducing initialization bottleneck.mergeSchema=false: Explicitly instructs Spark not to check for schema variations across individual file footers, eliminating 90% of the Driver's metadata processing overhead during the read phase.adaptive.enabled & skewJoin.enabled: Activates Adaptive Query Execution (AQE) to dynamically handle runtime data skew by automatically splitting over-sized partitions before they can bottleneck a thread or cause an OOM crash.Part 5: The Interview Final PitchConclude your design presentation by standing by your numbers with absolute operational authority:"To guarantee a production-grade ingestion pipeline, I establish a firm separation of concerns: I vertically size the Driver to 8 cores and 36 GB of total memory to easily manage multi-threaded file listing and task tracking without risk of a metadata-driven OOM crash. >For the computing layer, I scale out horizontally using a locked container unit of 5 cores and 40 GB of total memory per executor. This specific profile is structurally optimized to hold uncompressed Parquet row groups in memory without risking local disk spilling. I dynamically adjust the number of these executors based on a conservative throughput coefficient of 25 MB/s per core, while matching our partitions to a 5:1 ratio relative to total cores to keep the cluster perfectly balanced and saturated."

    I need some basic understanding of data sizes. So on an average in a very generalized fashion how much is the size of a table which has 10B records 100B records and similarly what is the number of records in a table with 1 TB 10 TB in size etc.


    - Edge cases that need to be covered:
        - Schema evolution and schema drift
        - Corrupt, malformed, and partially written input files
        - Duplicate files, replayed batches, and exactly-once ingestion guarantees
        - Object store race conditions, file listing issues, and manifest-based ingestion
        - Structured Streaming ingestion with checkpoints, watermarks, and replay recovery
        - Source-specific bottlenecks such as JDBC, Kafka, APIs, and SFTP/file drops
        - Data quality validation, quarantine paths, and row-count reconciliation
        - Metadata/catalog failures such as missing partitions, stale catalogs, and path mismatches
        - Security and governance edge cases such as PII masking, credential expiry, and access failures
        - Multi-tenant cluster issues such as noisy neighbors, executor preemption, and spot interruptions