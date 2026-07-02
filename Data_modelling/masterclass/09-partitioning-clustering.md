<!-- data-modelling-patterns: Partitioning and Clustering Strategy -->

# Partitioning and Clustering Strategy

## How Query Patterns Drive Partition Key Selection

The partition key should match the most common filter predicate in analytical queries — specifically, the column that, when filtered, eliminates the most data from consideration.

**Rule 1: High-cardinality time columns partition well.** `event_date`, `transaction_date`, `order_date` are the canonical partition keys because nearly all analytical queries have a time range filter. The partition column should be a date (not a timestamp, which creates micro-partitions in Snowflake but the granularity may be too fine).

**Rule 2: Partition cardinality should be bounded and predictable.** A partition key of `customer_id` on a 100M-customer table creates 100M partitions — each holding a handful of rows. This is partition metadata explosion. The warehouse must enumerate partition candidates before pruning, and with 100M partitions the metadata scan overwhelms the actual data scan.

**Rule 3: Hot partitions signal the wrong partition key.** If 80% of queries filter on `status = 'ACTIVE'` and you partition by `status`, all active-record queries hit one partition. You have serialized your I/O into a single partition.

```
Query pattern                     → Partition key
"Give me orders from last week"   → order_date
"Give me all failed transactions" → Do NOT partition by status; use clustering
"Give me inventory for warehouse X" → Do NOT partition by warehouse; volume is even
"Give me CDRs from the last hour" → event_date + event_hour
"Give me lab results for this patient" → partition by date, CLUSTER by patient_key
```

## Cardinality Traps in Clustering

In Snowflake, a clustering key of `(event_date, customer_id)` on a table where `customer_id` has 100M unique values produces poor co-location: rows for the same date/customer combination are spread across many micro-partitions because the customer ID space is too large to cluster effectively. The Snowflake automatic clustering service handles this, but manual clustering keys should observe:

- First clustering column: moderate cardinality (dates, regions, product categories — hundreds to thousands of values)
- Second clustering column: moderate cardinality that is correlated with query filters (status codes, event types)
- Avoid high-cardinality surrogate keys as clustering columns unless the table is queried primarily by individual key lookups (account balance history)

In BigQuery, clustering is column-ordered, with the first column providing the strongest pruning. BigQuery supports up to 4 clustering columns. A common mistake is clustering on a column like `is_active BOOLEAN` — two distinct values means half the table is in each cluster bucket. No pruning occurs.

## Platform-Specific Behavior

| Concept | Snowflake | BigQuery | Redshift |
|---------|-----------|----------|----------|
| Partitioning mechanism | Micro-partitions (automatic, ~16MB compressed) | Explicit partition columns (date/integer/range) | Sort keys + distribution keys |
| Clustering mechanism | Explicit CLUSTER BY keys (automatic clustering service re-sorts) | Explicit CLUSTER BY columns (up to 4) | COMPOUND sort key (ordered) or INTERLEAVED sort key |
| Partition pruning trigger | Metadata scan on micro-partition min/max values | Explicit partition filter in WHERE clause | Zone map on sort key columns |
| Late-arriving data impact | New micro-partitions added; clustering service re-clusters over time | Late data lands in correct partition; no re-clustering needed | Data not in sort order degrades zone map effectiveness; VACUUM REINDEX needed |
| Maximum partitions | Not applicable (micro-partitions are automatic) | 4,000 partitions per table | Not applicable (sort key-based) |
| Optimal partition filter | BETWEEN on clustering key columns | `WHERE _PARTITIONDATE = '...'` or `WHERE date_col = '...'` | `WHERE sort_key_col = '...'` |
| Distribution key (parallel) | Not configurable; Snowflake handles internally | Not configurable; BQ handles internally | DISTKEY column; EVEN or ALL for small dims |

**Redshift Sort Key Specifics**: A compound sort key on `(order_date, customer_id)` means rows are sorted first by date, then by customer_id within a date. Zone maps eliminate blocks where the date range doesn't match. If you filter on `customer_id` alone (without `order_date`), the zone map is useless — the sort key prefix isn't used. For tables with two dominant filter patterns (by date AND by customer), an `INTERLEAVED` sort key distributes equally across all key columns but loses the prefix pruning advantage. This is a no-free-lunch tradeoff.

**BigQuery Partition Expiry**: BigQuery supports automatic partition expiry (`partition_expiration_days`). Setting this to 730 days automatically drops partitions older than 2 years. Combined with Long-Term Storage pricing (data not queried in 90 days gets 50% price reduction), this is a powerful cost control mechanism absent from Snowflake and Redshift.

**Snowflake Micro-Partition Pruning**: Snowflake's automatic clustering service re-sorts micro-partitions over time to maintain clustering quality. The `SYSTEM$CLUSTERING_INFORMATION` function reports the average depth (number of micro-partitions a given value spans) — lower is better. For a well-clustered table, depth < 5 is good. Depth > 20 means queries are scanning too many micro-partitions and re-clustering should be triggered or the clustering key should be reconsidered.
