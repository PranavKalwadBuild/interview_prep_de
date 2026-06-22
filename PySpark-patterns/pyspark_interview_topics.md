# PySpark/Spark Interview Question Varieties

## 1. Writing PySpark Transformations
- Basic transformations: `select`, `filter`, `where`, `drop`, `withColumn`, `rename`
- Aggregations: `groupBy`, `agg`, `sum`, `avg`, `count`, `min`, `max`, `collect_list`
- Window functions: `over`, `partitionBy`, `orderBy`, `row_number`, `rank`, `lead`, `lag`
- Joins: `join` (inner, left, right, full, semi, anti), broadcast hints
- UDFs: defining and registering scalar and vectorized UDFs (Pandas UDF)
- Complex types: working with arrays, maps, structs (`explode`, `posexplode`, `split`, `getItem`)
- SQL vs DataFrame API intermixing
- Handling duplicates: `dropDuplicates`, `distinct`

## 2. PySpark Ingestion Based on Scenarios
- Streaming ingestion: Kafka, Kinesis, socket, rate source
- Batch ingestion: reading from cloud storage (S3, ADLS, GCS) with partitioning
- Schema evolution: handling changing schemas, merging schemas
- Incremental loads: using watermarks, change data capture (CDC) patterns
- File format considerations: Parquet, ORC, Avro, JSON, CSV options
- Bad record handling: `mode` (PERMISSIVE, DROP MALFORMED, FAILFAST), `columnNameOfCorruptRecord`
- Multi-source joins: joining streaming with static data
- Exactly-once semantics: using checkpointing, idempotent writes

## 3. Reading Files
- Format-specific options: CSV (header, delimiter, inferSchema), JSON (multiLine, primitivesAsString), Parquet (pushdown predicates)
- Partition discovery and pruning
- Reading nested JSON and flattening
- Reading from Hive tables vs external tables
- Reading with custom schemas (StructType) to avoid inference overhead
- Reading multiple files with glob patterns
- Reading from databases via JDBC (partitioning, predicates)

## 4. Conceptual Questions
- Spark Architecture: Driver, Executor, Cluster Manager (Standalone, YARN, Kubernetes, Mesos)
- Execution model: DAG, Stages, Tasks, Job scheduler
- Shuffle: why it happens, shuffle read/write, spill to disk, shuffle service
- Broadcast joins: when to use, size limits, alternatives (bucketed joins)
- Caching and persistence: `cache`, `persist`, storage levels (MEMORY_ONLY, MEMORY_AND_DISK, etc.)
- Lazy evaluation: when transformations are executed
- Lineage and fault tolerance: RDD lineage graph
- Accumulators and Broadcast variables: use cases and limitations
- Serialization: Java vs Kryo, registering custom classes

## 5. Performance Tuning
- Partition sizing: ideal partition size (128MB-256MB), avoiding too small/too many partitions
- Data skew: detecting skew (skew join, salting), mitigating with `skewJoin`, `repartitionByRange`
- Memory management: executor memory, storage memory, off-heap, `spark.memory.fraction`
- Broadcast threshold: adjusting `spark.sql.autoBroadcastJoinThreshold`
- Adaptive Query Execution (AQE): enabling coalesce shuffle partitions, skew join handling
- File format and columnar optimization: Parquet column pruning, predicate pushdown
- Vectorized Parquet reading: enabling `spark.sql.parquet.enableVectorizedReader`
- Avoiding shuffles: using `mapPartitions`, `reduceByKey` vs `groupByKey`
- Writing optimized: partitioning output files, bucketing, Z-ordering (Delta Lake)

## 6. Troubleshooting & Debugging
- Out-of-memory (OOM) errors: executor OOM, driver OOM, solutions (increase memory, reduce collect, increase partitions)
- Stage failures: checking logs, task failures, retry policies
- Slow tasks: identifying stragglers, locality issues, speculative execution
- Shuffle read/write spills: monitoring shuffle shuffle read/write metrics, increasing shuffle memory
- Network bottlenecks: checking executor-to-executor communication, disk I/O
- GC tuning: selecting appropriate GC (G1, CMS), logging GC
- Unsupported operations: checking for actions that trigger collects (`show`, `collect`) on large data
- Version compatibility: ensuring library versions match Spark version

## 7. Streaming Concepts
- Microbatch vs continuous processing modes
- Event time vs processing time, watermarks
- Stateful operations: `mapGroupsWithState`, `flatMapGroupsWithState`
- Windowing: tumbling, sliding, session windows
- Exactly-once guarantees: checkpointing, write-ahead logs (WAL), idempotent sinks
- Rate control: `maxRatePerPartition`, `backpressure`
- Monitoring streaming queries: `streamingQuery.lastProgress`, `status`
- Recovery from failures: checkpoint location, replay

## 8. MLlib & Machine Learning
- ML Pipeline stages: Estimator, Transformer, Pipeline
- Feature engineering: `VectorAssembler`, `StringIndexer`, `OneHotEncoder`, `StandardScaler`, `Tokenizer`, `StopWordsRemover`, `NGram`
- ML algorithms: classification (Logistic Regression, Decision Trees, Random Forest, GBT), regression, clustering (KMeans)
- Model evaluation: `BinaryClassificationEvaluator`, `MulticlassClassificationEvaluator`, `RegressionEvaluator`
- Cross-validation: `CrossValidator`, `ParamGridBuilder`
- Saving and loading models: `write`, `read`
- Distributed deep learning: Spark TensorFlow, Horovod on Spark
- Handling imbalanced data: weighting, sampling

## 9. SparkSQL
- intermixing DataFrame and SQL: `createOrReplaceTempView`, `spark.sql`
- User Defined Functions (UDF) in SQL: registering and using
- Query optimization: Catalyst optimizer, rule-based vs cost-based
- Table management: permanent vs temporary views, managed vs external tables
- Partitioned tables: `PARTITIONED BY`, `MSCK REPAIR TABLE`
- Transactional guarantees: Delta Lake ACID transactions (`BEGIN`, `COMMIT`, `ROLLBACK`)
- Time travel: querying previous versions (`VERSION AS OF`, `TIMESTAMP AS OF`)
- Optimize and Z-Order commands (`OPTIMIZE`, `ZORDER BY`)

## 10. Deployment & Cluster Management
- Submission modes: `spark-submit` arguments (`--master`, `--deploy-mode`, `--executor-memory`, `--num-executors`)
- Cluster managers: Standalone, YARN, Kubernetes, Mesos
- Monitoring: Spark UI (Stages, Storage, Environment, Executors, SQL tabs), Event logs, History server
- Logging: configuring log4j, log levels
- Dependency management: `--packages`, `--py-files`, `--jars`
- Kerberos security: authentication, delegation tokens
- Resource allocation: dynamic allocation (`spark.dynamicAllocation.enabled`)
- Secrets management: integrating with vaults, secret providers

## 11. Best Practices & Common Pitfalls
- Avoid `collect()` on large datasets; use `take`, `show`, `limit`
- Use `mapPartitions` for expensive per-partition initialization
- Prefer DataFrame/DataSet APIs over RDD for optimization
- Use `broadcast` hint for small tables in joins
- Cache only when data reused multiple times; unpersist when done
- Check for data leakage: ensure train/test split before expensive operations
- Use appropriate file formats: Parquet for columnar, Avro for row-based with schema evolution
- Manage shuffle files: clean up temporary directories, monitor disk usage
- Use `spark.sql.adaptive.enabled` for better performance in newer Spark versions
- Prefer `spark.read.schema()` over `inferSchema` for production jobs
- Unit testing: using `spark-testing-base`, `DataFrameSuiteBase`
- Code readability: meaningful column names, avoid overly complex chains

## 12. Checklist for Interview Preparation
- [ ] Practice writing transformations on sample datasets (flights, sales)
- [ ] Implement a simple streaming pipeline (Kafka → console)
- [ ] Tune a job suffering from skew or spills
- [ ] Explain Spark architecture and shuffle internals
- [ ] Build an ML pipeline with feature engineering and model evaluation
- [ ] Write SparkSQL queries involving window functions and joins
- [ ] Discuss deployment options and monitoring tools
- [ ] Review common pitfalls and how to avoid them
- [ ] Study recent Spark features (AQE, Pandas UDF, Kubernetes support)

--- 
*Use this as a study guide to cover the breadth of PySpark/Spark topics frequently seen in interviews.*
