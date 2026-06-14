<!-- python-patterns: Pandas for Data Engineering -->

# Pandas for Data Engineering

## Reading Data

```python
import pandas as pd

# CSV — always specify dtypes for large files
df = pd.read_csv(
    "data.csv",
    dtype={"id": str, "amount": float, "status": "category"},
    parse_dates=["created_at", "updated_at"],
    usecols=["id", "amount", "status", "created_at"],  # read only needed columns
    na_values=["N/A", "NULL", "NONE", ""],
)

# Parquet — preferred format for DE (columnar, compressed, typed)
df = pd.read_parquet("data.parquet", columns=["id", "amount"])  # selective columns

# CSV chunked read — for large files
def read_large_csv(path, chunk_size=100_000):
    for chunk in pd.read_csv(path, chunksize=chunk_size, dtype=str):
        yield chunk

# Parquet chunked read — use PyArrow directly
import pyarrow.parquet as pq
pf = pq.ParquetFile("large.parquet")
for batch in pf.iter_batches(batch_size=100_000):
    df = batch.to_pandas()
    process(df)
```

---

## `groupby` — Traps and Patterns

### NaN Key Dropped Silently

```python
df = pd.DataFrame({
    "region": ["US", None, "EU", "US"],
    "sales": [100, 200, 300, 400]
})

# BAD — NaN region row (200) silently disappears
df.groupby("region")["sales"].sum()
# region
# EU    300
# US    500

# GOOD — dropna=False preserves NaN keys (pandas 1.1+)
df.groupby("region", dropna=False)["sales"].sum()
# region
# EU      300.0
# NaN     200.0
# US      500.0
```

### `agg` vs `transform` — Most Common Interview Q

```python
# agg — reduces: one output row per group
df.groupby("region")["sales"].sum()            # returns Series indexed by region
df.groupby("region").agg({"sales": "sum", "qty": "mean"})  # multiple aggs

# transform — preserves shape: same length as original df, aligned by index
df["region_total"] = df.groupby("region")["sales"].transform("sum")
# Useful for: adding group stats back to original row

# Example: flag rows where individual sale > group average
df["group_avg"] = df.groupby("region")["sales"].transform("mean")
df["above_avg"] = df["sales"] > df["group_avg"]
```

### Named Aggregations (pandas 0.25+)

```python
result = df.groupby("region").agg(
    total_sales=("sales", "sum"),
    avg_sales=("sales", "mean"),
    max_sale=("sales", "max"),
    order_count=("order_id", "nunique"),
)
```

### Custom Aggregation Functions

```python
def pct_above_threshold(s, threshold=100):
    return (s > threshold).mean() * 100

df.groupby("region")["sales"].agg(["sum", "mean", pct_above_threshold])
df.groupby("region")["sales"].agg(pct_high=("sales", lambda x: (x > 1000).sum()))
```

---

## merge vs join

```python
# merge — explicit column-based, recommended for DE
result = pd.merge(
    orders, customers,
    on="customer_id",
    how="left",               # left/right/inner/outer
    suffixes=("_order", "_customer"),   # resolve column name conflicts
    validate="many_to_one",   # raises if right side has duplicates on key — data quality check
)

# outer merge + indicator — reconciliation / data quality
result = pd.merge(source, target, on="id", how="outer", indicator=True)
result["_merge"].value_counts()
# left_only    → in source, missing from target
# right_only   → in target, not in source (new records)
# both         → matched

# join — index-based (less common in DE)
df.join(other_df, on="customer_id")   # requires other_df to be indexed by customer_id

# Merge on multiple keys
pd.merge(df1, df2, on=["date", "region", "product_id"], how="inner")

# validate parameter — ALWAYS use in DE to catch cardinality bugs
pd.merge(fact, dim, on="product_id", how="left", validate="many_to_one")
# raises MergeError if dim has duplicate product_ids → catches schema bugs early
```

---

## apply vs Vectorization

```python
import numpy as np

# Performance order (fastest → slowest):
# NumPy ufuncs > pandas built-ins > df.eval() > apply(axis=0) > apply(axis=1) > iterrows()

# BAD — apply(axis=1) is a Python loop disguised
df["tax"] = df.apply(lambda row: row["amount"] * 0.08 if row["amount"] > 0 else 0, axis=1)

# GOOD — vectorized with np.where
df["tax"] = np.where(df["amount"] > 0, df["amount"] * 0.08, 0)

# BAD — string ops with apply
df["upper"] = df["name"].apply(str.upper)

# GOOD — string accessor
df["upper"] = df["name"].str.upper()

# BAD — date parsing with apply
df["year"] = df["date"].apply(lambda x: pd.to_datetime(x).year)

# GOOD — vectorized
df["year"] = pd.to_datetime(df["date"]).dt.year

# np.select — vectorized multiple conditions (replaces nested np.where)
conditions = [
    df["amount"] > 10_000,
    df["amount"] > 1_000,
    df["amount"] > 0,
]
choices = ["premium", "standard", "basic"]
df["tier"] = np.select(conditions, choices, default="zero")

# When apply IS acceptable:
# - Complex row-level logic involving multiple columns that can't be vectorized
# - Small DataFrames where performance doesn't matter
# - When the alternative is significantly more complex code
```

---

## Deduplication

```python
# drop_duplicates — keep first occurrence by default
df = df.drop_duplicates(subset=["id"])               # deduplicate on one column
df = df.drop_duplicates(subset=["id", "date"])       # composite key
df = df.drop_duplicates(subset=["id"], keep="last")  # keep most recent

# With ranking — keep row with max value per group
df = (
    df.assign(rank=df.groupby("id")["updated_at"].rank(method="first", ascending=False))
    .query("rank == 1")
    .drop(columns="rank")
)

# With idxmax — keep row with max value
idx = df.groupby("id")["updated_at"].idxmax()
df = df.loc[idx].reset_index(drop=True)
```

---

## Null Handling

```python
# Detection
df.isnull().sum()                    # null count per column
df.isnull().any()                    # True/False per column
df[df["amount"].isnull()]            # filter to null rows

# Filling
df["amount"].fillna(0)               # fill with scalar
df["region"].fillna(df["country"])   # fill from another column
df.ffill()                           # forward fill
df.bfill()                           # backward fill
df.fillna({"amount": 0, "region": "UNKNOWN"})  # per-column fill

# Dropping
df.dropna(subset=["id", "amount"])   # drop rows where these columns are null
df.dropna(how="all")                 # drop rows where ALL columns are null

# Assertion
assert df["id"].notnull().all(), "Primary key has nulls"
assert df["amount"].ge(0).all(), "Negative amounts found"
```

---

## Memory Optimization

```python
# Check memory usage
df.memory_usage(deep=True).sum() / 1e6  # total MB
df.memory_usage(deep=True) / 1e6        # per column

# Downcast numeric types
df["id"] = pd.to_numeric(df["id"], downcast="integer")    # int64 → int32/int16/int8
df["score"] = pd.to_numeric(df["score"], downcast="float")  # float64 → float32

# String columns with low cardinality → category
df["status"] = df["status"].astype("category")    # massive savings for "active"/"inactive" etc.
df["region"] = df["region"].astype("category")

# Typical memory reduction: 2-4x with dtypes alone

# read_csv with dtypes specified upfront
dtype_map = {
    "id": "int32",
    "user_id": "int32",
    "amount": "float32",
    "status": "category",
    "region": "category",
}
df = pd.read_csv("large.csv", dtype=dtype_map)
```

---

## Window Functions (SQL equivalent)

```python
# ROW_NUMBER — rank within group
df["row_num"] = df.groupby("customer_id").cumcount() + 1

# RANK — rank by value within group
df["rank"] = df.groupby("region")["sales"].rank(method="dense", ascending=False)

# Running total
df["running_total"] = df.groupby("customer_id")["amount"].cumsum()

# LAG / LEAD
df = df.sort_values(["customer_id", "date"])
df["prev_amount"] = df.groupby("customer_id")["amount"].shift(1)   # LAG(1)
df["next_amount"] = df.groupby("customer_id")["amount"].shift(-1)  # LEAD(1)

# Rolling window
df["7d_avg"] = df.groupby("region")["sales"].transform(
    lambda x: x.rolling(7, min_periods=1).mean()
)
```

---

## SCD Type 2 in Pandas

```python
from datetime import datetime

def apply_scd2(existing: pd.DataFrame, updates: pd.DataFrame, key: str) -> pd.DataFrame:
    """Apply SCD2 updates: expire changed rows, insert new versions."""
    now = datetime.utcnow().isoformat()

    # Merge existing active rows with updates
    active = existing[existing["dbt_valid_to"].isnull()]
    merged = pd.merge(active, updates, on=key, how="outer", suffixes=("_old", "_new"), indicator=True)

    # Rows that changed — expire old version
    changed = merged[
        (merged["_merge"] == "both") &
        (merged["value_old"] != merged["value_new"])
    ]
    if not changed.empty:
        existing.loc[existing[key].isin(changed[key]), "dbt_valid_to"] = now

    # Insert new rows for changed + new records
    new_rows = merged[merged["_merge"].isin(["right_only"])]
    changed_new = changed.rename(columns={"value_new": "value"})[[key, "value"]]
    inserts = pd.concat([changed_new, new_rows[[key, "value_new"]].rename(columns={"value_new": "value"})])
    inserts["dbt_valid_from"] = now
    inserts["dbt_valid_to"] = None

    return pd.concat([existing, inserts], ignore_index=True)
```

---

## Interview Questions

**Q: What is `transform` vs `agg` in groupby?**
`agg` reduces each group to a scalar — output has one row per group. `transform` preserves the original DataFrame shape — output is aligned back to the original index, one row per original row. Use `transform` to add group-level stats as new columns.

**Q: `merge` with `validate="many_to_one"` — what does it do?**
Raises `MergeError` if the right DataFrame has duplicate values on the join key. Prevents fan-out (row multiplication) — a critical data quality guard in DE joins.

**Q: `apply(axis=1)` is 100x slower than vectorized operations — why?**
`apply(axis=1)` is a Python-level loop: for each row, Python overhead for function call, row extraction, and type coercion. Vectorized ops (NumPy ufuncs, pandas built-ins) run in compiled C with no Python overhead per element.

**Q: How do you read a 20 GB Parquet file in Pandas?**
Use PyArrow's `ParquetFile.iter_batches(batch_size=N)` — processes in chunks. If you only need some columns, pass `columns=` to `read_parquet`. Never `pd.read_parquet("huge.parquet")` without column selection on large files.

**Q: `groupby("col")` dropped my NaN rows — why?**
`groupby` drops NaN keys by default. Use `groupby("col", dropna=False)` to include them.
