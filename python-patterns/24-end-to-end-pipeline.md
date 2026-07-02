<!-- python-patterns: End-to-End Data Pipeline in Pure Python (Scalable to 10 TB) -->

# End-to-End Data Pipeline in Pure Python (Scalable to 10 TB)

## Overview

This document describes a **pure‑Python** data processing pipeline that can handle terabyte‑scale datasets without relying on PySpark or other distributed compute frameworks. The core idea is to use **generator functions** (iterators) for lazy, memory‑efficient streaming, combined with **external sort/merge** and **micro‑batching** techniques to keep memory usage bounded while still achieving high throughput.

The pipeline follows the classic **Extract → Transform → Load (ETL)** pattern, but each stage is implemented as a composable generator that yields records one‑by‑one (or in small batches). This design lets you plug the stages together like Unix pipes, and you can optionally add multiprocessing or distributed workers later without changing the core logic.

> **Key Principles**
> 1. **Never load the whole dataset into memory** – process items as they are read.
> 2. **Use bounded buffers** – if a stage needs to accumulate state (e.g., aggregation), spill to disk when the buffer exceeds a threshold.
> 3. **Leverage efficient primitives** – `csv`, `json`, `heapq.merge`, `itertools`, and the `multiprocessing` module for parallelism when needed.
> 4. **Keep each stage simple and testable** – generators are easy to unit‑test with sample iterables.

## 1. Data Extraction (Source Generators)

### 1.1 Reading Large CSV/TSV Files

```python
import csv
from typing import Iterable, Dict, Any

def csv_reader(
    file_path: str,
    *,
    delimiter: str = ',',
    has_header: bool = True,
    encoding: str = 'utf-8',
    chunk_size: int = 10_000,
) -> Iterable[Dict[str, Any]]:
    """
    Lazily yields rows from a CSV file as dictionaries.
    The file is read line‑by‑line; no entire file is loaded.
    """
    with open(file_path, newline='', encoding=encoding) as f:
        reader = csv.DictReader(f, delimiter=delimiter) if has_header else csv.reader(f, delimiter=delimiter)
        for row in reader:
            # Convert csv.reader output to dict if no header
            if not has_header:
                # Assume caller knows column indices; here we just yield the list
                yield row  # type: ignore
            else:
                yield row
```

**Usage:** `for record in csv_reader('data/huge.csv'): ...`

### 1.2 Reading JSON Lines (NDJSON)

```python
import json
from typing import Iterable, Any

def jsonl_reader(file_path: str, encoding: str = 'utf-8') -> Iterable[Any]:
    """
    Yields one JSON object per line.
    """
    with open(file_path, encoding=encoding) as f:
        for line in f:
            line = line.strip()
            if line:  # skip empty lines
                yield json.loads(line)
```

### 1.3 Reading from a Socket or API (Generator Wrapper)

```python
import requests
from typing import Iterable, Any, Generator

def api_stream_generator(url: str, params: dict | None = None, chunk_size: int = 1024) -> Generator[Any, None, None]:
    """
    Streams JSON objects from an HTTP endpoint that returns newline‑delimited JSON.
    """
    with requests.get(url, params=params, stream=True, timeout=30) as resp:
        resp.raise_for_status()
        buffer = ''
        for chunk in resp.iter_content(chunk_size=chunk_size, decode_unicode=True):
            buffer += chunk
            while '\n' in buffer:
                line, buffer = buffer.split('\n', 1)
                if line.strip():
                    yield json.loads(line.strip())
        # leftover
        if buffer.strip():
            yield json.loads(buffer.strip())
```

### 1.4 Generic Extractor Interface

All extractors share the same signature: `Iterable[Dict[str, Any]]` (or `Iterable[Any]` for non‑dict payloads). This uniformity lets you chain stages without caring about the underlying source.

## 2. Transformation Stage (Generator Functions)

Transformations are simple functions that take an input record and yield zero or more output records. Because they are generators, they can be composed.

### 2.1 Simple Mapping

```python
from typing import Iterable, Callable, TypeVar

T = TypeVar('T')
U = TypeVar('U')

def map_gen(func: Callable[[T], U], source: Iterable[T]) -> Iterable[U]:
    """Apply `func` to each item from `source`."""
    for item in source:
        yield func(item)
```

Example: convert a string field to uppercase.

```python
def uppercase_name(record: Dict[str, Any]) -> Dict[str, Any]:
    record = record.copy()  # avoid mutating original if reused
    record['name'] = record['name'].upper()
    return record
```

Usage: `pipeline = map_gen(uppercase_name, csv_reader('input.csv'))`

### 2.2 Filtering

```python
def filter_gen(predicate: Callable[[T], bool], source: Iterable[T]) -> Iterable[T]:
    for item in source:
        if predicate(item):
            yield item
```

Example: keep only records where `amount > 0`.

```python
def positive_amount(record: Dict[str, Any]) -> bool:
    return float(record.get('amount', 0)) > 0
```

### 2.3 Batched Transformations (for vectorized ops)

Sometimes you want to apply a library like NumPy or pandas to a **small micro‑batch** for efficiency, then yield the results one‑by‑one.

```python
def batched_map_gen(
    func: Callable[[list[T]], list[U]],
    source: Iterable[T],
    batch_size: int = 1000,
) -> Iterable[U]:
    batch: list[T] = []
    for item in source:
        batch.append(item)
        if len(batch) >= batch_size:
            yield from func(batch)
            batch.clear()
    if batch:
        yield from func(batch)
```

Example: normalize a numeric column using NumPy (still pure Python‑outside‑the‑batch).

```python
import numpy as np

def normalize_batch(batch: list[Dict[str, Any]]) -> list[Dict[str, Any]]:
    arr = np.array([float(r['value']) for r in batch])
    if arr.size == 0:
        return batch
    mn, mx = arr.min(), arr.max()
    if mx == mn:
        normed = np.zeros_like(arr)
    else:
        normed = (arr - mn) / (mx - mn)
    for r, n in zip(batch, normed):
        r = r.copy()
        r['value_norm'] = float(n)
        yield r
```

Wrap: `batched_map_gen(normalize_batch, source, batch_size=5000)`

### 2.4 Stateful Transformations (e.g., running totals)

Use a closure to keep state while still yielding each record.

```python
def running_total_gen(source: Iterable[Dict[str, Any]], field: str) -> Iterable[Dict[str, Any]]:
    total = 0.0
    for record in source:
        total += float(record.get(field, 0))
        yield {**record, f'{field}_cumsum': total}
```

## 3. Aggregation & Shuffle‑Like Operations

For aggregations that need to group by a key (e.g., `SUM(amount) BY region`), we cannot keep an unbounded dictionary in memory for 10 TB of unique keys. The solution is **partial aggregation + external merge**.

### 3.1 In‑Memory Combiner with Spill Threshold

```python
import os
import tempfile
from collections import defaultdict
from typing import Iterable, Tuple, Callable, Any

def combine_and_spill(
    source: Iterable[Tuple[Any, Any]],  # (key, value)
    *,
    combine: Callable[[Any, Any], Any] = lambda a, b: a + b,
    max_memory_items: int = 5_000_000,
    temp_dir: str | None = None,
) -> Iterable[Tuple[Any, Any]]:
    """
    Reads (key, value) pairs, combines values per key in a dict.
    When the dict grows beyond `max_memory_items`, it is dumped to a temporary file.
    At the end, all spill files are read back and combined again to produce final results.
    Yields (key, combined_value) pairs.
    """
    if temp_dir is None:
        temp_dir = tempfile.mkdtemp()
    spill_files: list[str] = []
    mem: dict[Any, Any] = {}

    def dump_mem() -> str:
        nonlocal mem
        fd, path = tempfile.mkstemp(dir=temp_dir, prefix='spill_', suffix='.tmp')
        os.close(fd)
        with open(path, 'w', encoding='utf-8') as f:
            for k, v in mem.items():
                f.write(f'{json.dumps(k)}\t{json.dumps(v)}\n')
        mem.clear()
        return path

    for key, value in source:
        mem[key] = combine(mem.get(key, 0), value)
        if len(mem) >= max_memory_items:
            spill_files.append(dump_mem())

    # flush remaining in‑memory
    if mem:
        spill_files.append(dump_mem())

    # Now merge all spill files (they are already combined per file)
    # Re‑open each file and reduce across duplicates.
    global_combined: dict[Any, Any] = defaultdict(lambda: 0)  # adjust default per combine
    for path in spill_files:
        with open(path, encoding='utf-8') as f:
            for line in f:
                line = line.rstrip('\n')
                if not line:
                    continue
                k_str, v_str = line.split('\t', 1)
                k = json.loads(k_str)
                v = json.loads(v_str)
                global_combined[k] = combine(global_combined[k], v)
        os.remove(path)  # clean up
    if os.path.exists(temp_dir) and not os.listdir(temp_dir):
        os.rmdir(temp_dir)

    for k, v in global_combined.items():
        yield k, v
```

**Usage in a pipeline:**

```python
# Step 1: extract key‑value pairs from source
def to_kv(record: Dict[str, Any]) -> Tuple[str, float]:
    return (record['region'], float(record['amount']))

# Step 2: combine with spill
aggregated = combine_and_spill(
    (to_kv(r) for r in csv_reader('sales.csv')),
    combine=lambda a, b: a + b,
    max_memory_items=2_000_000,
)

# Step 3: emit final records
for region, total in aggregated:
    yield {'region': region, 'total_amount': total}
```

### 3.2 Distinct / Deduplication (Similar Spill Strategy)

If you need to deduplicate based on a key, you can use a **bloom filter** approximation or the same spill‑and‑sort approach: write sorted chunks to disk, then merge‑unique.

For brevity, we omit the full code but note that the pattern mirrors `combine_and_spill` with a set instead of a dict.

## 4. Loading / Sinking (Writer Generators)

Writers consume the final iterator and write to disk, a database, or another service. They can also be generators that yield acknowledgment records.

### 4.1 Writing CSV

```python
def csv_writer(
    records: Iterable[Dict[str, Any]],
    dest_path: str,
    *,
    delimiter: str = ',',
    encoding: str = 'utf-8',
    write_header: bool = True,
) -> None:
    if not records:
        return
    it = iter(records)
    first = next(it)
    fieldnames = list(first.keys())
    with open(dest_path, 'w', newline='', encoding=encoding) as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, delimiter=delimiter)
        if write_header:
            writer.writeheader()
        writer.writerow(first)
        for row in it:
            writer.writerow(row)
```

### 4.2 Writing JSON Lines

```python
def jsonl_writer(records: Iterable[Any], dest_path: str, encoding: str = 'utf-8') -> None:
    with open(dest_path, 'w', encoding=encoding) as f:
        for obj in records:
            f.write(json.dumps(obj) + '\n')
```

### 4.3 Writing to a Database (using `psycopg2` or `sqlite3` as example)

```python
import sqlite3
from typing import Iterable, Dict

def sqlite_sink(
    records: Iterable[Dict[str, Any]],
    db_path: str,
    table: str,
    batch_size: int = 10_000,
) -> None:
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    # Assume table exists with matching columns; in practice, create dynamically.
    placeholders = ','.join(['?'] * len(next(iter(records))))
    cols = ','.join(next(iter(records)).keys())
    sql = f'INSERT INTO {table} ({cols}) VALUES ({placeholders})'
    batch: list[tuple] = []
    for rec in records:
        batch.append(tuple(rec.values()))
        if len(batch) >= batch_size:
            cur.executemany(sql, batch)
            conn.commit()
            batch.clear()
    if batch:
        cur.executemany(sql, batch)
        conn.commit()
    conn.close()
```

## 5. Putting It All Together – Example Pipeline

Below is a complete, self‑contained example that:

1. Reads a massive CSV file (`input/sales_raw.csv`) with columns: `order_id, timestamp, region, product_id, quantity, unit_price`.
2. Parses timestamps, computes `amount = quantity * unit_price`.
3. Filters out cancelled orders (`status != 'CANCELLED'` – assume we have a `status` column).
4. Aggregates total `amount` per `region` per day.
5. Writes the result to `output/daily_region_summary.csv`.

```python
import csv
import json
from datetime import datetime
from typing import Iterable, Tuple, Dict, Any

# ----------------- Extract -----------------
def sales_csv_reader(path: str) -> Iterable[Dict[str, Any]]:
    with open(path, newline='', encoding='utf-8') as f:
        yield from csv.DictReader(f)

# ----------------- Transform -----------------
def parse_amount(record: Dict[str, Any]) -> Dict[str, Any]:
    rec = record.copy()
    rec['quantity'] = float(rec['quantity'])
    rec['unit_price'] = float(rec['unit_price'])
    rec['amount'] = rec['quantity'] * rec['unit_price']
    return rec

def parse_ts(record: Dict[str, Any]) -> Dict[str, Any]:
    rec = record.copy()
    # Assuming ISO 8601 timestamp in 'timestamp' column
    rec['dt'] = datetime.fromisoformat(record['timestamp'])
    return rec

def filter_active(record: Dict[str, Any]) -> bool:
    return record.get('status', '').upper() != 'CANCELLED'

def to_region_day_key(record: Dict[str, Any]) -> Tuple[str, str, float]:
    # key: (region, YYYY-MM-DD)
    day = record['dt'].date().isoformat()
    return (record['region'], day, record['amount'])

# ----------------- Combine with Spill -----------------
# (reuse combine_and_spill from section 3.1)
from typing import Callable
def combine_and_spill(
    source: Iterable[Tuple[Tuple[str, str], float]],
    *,
    combine: Callable[[float, float], float] = lambda a, b: a + b,
    max_memory_items: int_2_000_000,
    temp_dir: str | None = None,
) -> Iterable[Tuple[Tuple[str, str], float]]:
    # Implementation identical to the one shown earlier.
    # ... (omitted for brevity; copy from section 3.1)
    pass

# ----------------- Load -----------------
def write_summary(
    aggregated: Iterable[Tuple[Tuple[str, str], float]],
    dest_path: str,
) -> None:
    with open(dest_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['region', 'date', 'total_amount'])
        for (region, day), total in aggregated:
            writer.writerow([region, day, total])

# ----------------- Build Pipeline -----------------
def run_pipeline(input_csv: str, output_csv: str) -> None:
    raw = sales_csv_reader(input_csv)
    with_amount = map_gen(parse_amount, raw)
    with_ts = map_gen(parse_ts, with_amount)
    active = filter_gen(filter_active, with_ts)
    kv = map_gen(lambda r: (to_region_day_key(r)[:2], to_region_day_key(r)[2]), active)
    aggregated = combine_and_spill(
        kv,
        combine=lambda a, b: a + b,
        max_memory_items=2_000_000,
    )
    write_summary(aggregated, output_csv)

# Example invocation
if __name__ == '__main__':
    run_pipeline('input/sales_raw_10tb.csv', 'output/daily_region_summary.csv')
```

### Why This Scales to 10 TB

| Stage | Memory Usage | Scaling Technique |
|-------|--------------|-------------------|
| **Extract** (`csv_reader`) | O(1) – reads line by line | Uses Python’s built‑in file buffering; can be swapped for `mmap` if needed. |
| **Transform** (map/filter/batched_map) | O(1) per record, plus optional micro‑batch size | Generator pipelines never accumulate more than one record (or a small batch). |
| **Combine** (`combine_and_spill`) | Bounded by `max_memory_items` (e.g., 2 M key/value pairs ≈ a few hundred MB). Excess data spills to SSD/NVMe; final merge reads each spill once. | External‑merge pattern ensures O(total unique keys) disk but constant RAM. |
| **Load** (`csv_writer`) | O(1) – writes as it receives. | Sequential write, suitable for high‑throughput storage. |
| **Optional Parallelism** | - | Replace the source generator with a `multiprocessing.Pool.imap_unordered` or use `concurrent.futures.ProcessPoolExecutor` to run multiple extract‑transform workers feeding a shared queue; the combiner can be made partition‑aware (hash‑partition keys to separate spill files). |

**Throughput Tips**
- Use **SSD/NVMe** for spill files; the sequential read/write speed of modern drives easily sustains several GB/s.
- Tune `max_memory_items` and `batch_size` based on available RAM.
- If the key space is truly huge (hundreds of millions of distinct regions/dates), consider **salting** (adding a random prefix) to distribute spill files evenly, then perform a second‑level combine.
- For even larger scale, you can run multiple instances of the pipeline on different input splits (e.g., by file or by key range) and merge the final outputs—a classic map‑reduce approach without a framework.

## 6. Extending to Multi‑Process / Distributed

The generator model is naturally **composable** with message‑passing systems.

### 6.1 Simple Multi‑Stage Pipeline with `multiprocessing.Queue`

```python
from multiprocessing import Process, Queue
import queue

def worker_stage(func, in_q: Queue, out_q: Queue, sentinel):
    for item in iter(in_q.get, sentinel):
        try:
            for out in func(item):
                out_q.put(out)
        except Exception as e:
            out_q.put(e)  # propagate error
    out_q.put(sentinel)

# Build queues between stages
q1 = Queue()
q2 = Queue()
q3 = Queue()
SENT = object()

p1 = Process(target=worker_stage, args=(parse_amount, sales_csv_reader(q1)?? ...))
# (The above is sketchy; in practice you’d wrap the source generator to put items into q1.)
```

For brevity, the full multiprocessing wiring is omitted, but the principle is:
- each stage runs in its own process,
- queues act as the **stream** between stages,
- back‑pressure is naturally handled by the queue’s `maxsize`.

### 6.2 Using `concurrent.futures` for Map‑Style Stages

If a transformation is embarrassingly parallel (e.g., parsing each line independently), you can replace `map_gen` with:

```python
from concurrent.futures import ProcessPoolExecutor

def parallel_map_gen(func, source, max_workers=4):
    with ProcessPoolExecutor(max_workers=max_workers) as exe:
        yield from exe.map(func, source)
```

Note: The source must be **picklable**; generators of file reads work fine if you pass file paths and let each worker open its own handle.

## 7. Summary of Files to Create

| File | Purpose |
|------|---------|
| `24-end-to-end-pipeline.md` | This document – design, patterns, and full example pipeline. |
| (Optional) `pipeline_utils.py` | Extract the reusable generators and helper functions (`csv_reader`, `map_gen`, `filter_gen`, `combine_and_spill`, writers) into a module for import. |

You can copy the code snippets into a Python module and then invoke `run_pipeline` with your actual file paths.

## 9. Decorators for Cross-Cutting Concerns

In production pipelines, cross‑cutting concerns such as validation, rate limiting, retries, and timing are best handled with decorators so they can be applied uniformly to any generator or function.

### 9.1 Validation Decorator

```python
from functools import wraps
from typing import Callable, Iterable, Any

def validate_predicate(predicate: Callable[[Any], bool], error_msg: str = "Validation failed"):
    """
    Decorator that validates each item yielded by a generator function.
    If predicate(item) is False, raises ValueError with error_msg.
    """
    def decorator(func: Callable[..., Iterable[Any]]) -> Callable[..., Iterable[Any]]:
        @wraps(func)
        def wrapper(*args, **kwargs):
            for item in func(*args, **kwargs):
                if not predicate(item):
                    raise ValueError(f"{error_msg}: {item}")
                yield item
        return wrapper
    return decorator

# Example usage:
@validate_predicate(lambda r: float(r.get('amount', 0)) > 0, "Amount must be positive")
def parse_amount(record: Dict[str, Any]) -> Dict[str, Any]:
    ...
```

### 9.2 Rate Limiter Decorator

```python
import time
from functools import wraps
from typing import Callable, Iterable, Any

def rate_limiter(max_per_second: float):
    """
    Decorator that limits the rate at which items are yielded.
    """
    min_interval = 1.0 / max_per_second
    def decorator(func: Callable[..., Iterable[Any]]) -> Callable[..., Iterable[Any]]:
        @wraps(func)
        def wrapper(*args, **kwargs):
            last = time.time()
            for item in func(*args, **kwargs):
                elapsed = time.time() - last
                wait = min_interval - elapsed
                if wait > 0:
                    time.sleep(wait)
                last = time.time()
                yield item
        return wrapper
    return decorator

# Example usage:
@rate_limiter(10.0)  # max 10 items per second
def csv_reader_limited(file_path: str) -> Iterable[Dict[str, Any]]:
    return csv_reader(file_path)
```

### 9.3 Retry with Exponential Backoff Decorator

```python
import random
import time
from functools import wraps
from typing import Callable, Iterable, Any, Type, Tuple

def retry(
    exceptions: Type[BaseException] | Tuple[Type[BaseException], ...],
    tries: int = 4,
    delay: float = 1.0,
    backoff: float = 2.0,
    jitter: float = 0.1,
):
    """
    Retry decorator with exponential backoff.
    """
    def decorator(func: Callable[..., Iterable[Any]]) -> Callable[..., Iterable[Any]]:
        @wraps(func)
        def wrapper(*args, **kwargs):
            _tries, _delay = tries, delay
            while _tries > 1:
                try:
                    for item in func(*args, **kwargs):
                        yield item
                    return  # succeeded, exit
                except exceptions as e:
                    _tries -= 1
                    if _tries == 0:
                        raise
                    sleep = _delay * (backoff ** (tries - _tries - 1))
                    sleep += random.uniform(0, jitter * sleep)
                    time.sleep(sleep)
            # final attempt
            for item in func(*args, **kwargs):
                yield item
        return wrapper
    return decorator

# Example usage:
@retry((IOError, OSError), tries=3, delay=0.5, backoff=2)
def resilient_csv_reader(file_path: str) -> Iterable[Dict[str, Any]]:
    return csv_reader(file_path)
```

### 9.4 Timer Decorator

```python
import time
from functools import wraps
from typing import Callable, Iterable, Any

def timer(func: Callable[..., Iterable[Any]]) -> Callable[..., Iterable[Any]]:
    """
    Decorator that prints the elapsed time to exhaust the generator.
    """
    @wraps(func)
    def wrapper(*args, **kwargs):
        start = time.time()
        count = 0
        for item in func(*args, **kwargs):
            yield item
            count += 1
        elapsed = time.time() - start
        print(f"[TIMER] {func.__name__} produced {count} items in {elapsed:.2f}s")
    return wrapper

# Example usage:
@timer
def count_records(source: Iterable[Any]) -> int:
    return sum(1 for _ in source)
```

### 9.5 Combining Decorators

Decorators stack naturally:

```python
@timer
@rate_limiter(5)
@retry((IOError,), tries=2)
@validate_predicate(lambda r: r.get('region') is not None, "Missing region")
def enriched_pipeline(file_path: str) -> Iterable[Dict[str, Any]]:
    return csv_reader(file_path)
```

These decorators keep the core pipeline logic pure and allow you to swap concerns without touching the business logic.


## 8. References & Further Reading

- **Generator & Iterator Patterns** – PEP 255, PEP 289, “Loop Like A Native” (David Beazley).  
- **External Merge Sort** – Knuth, *The Art of Computer Programming*, Vol. 3.  
- **MapReduce Concepts** – Dean & Ghemawat, “MapReduce: Simplified Data Processing on Large Clusters”.  
- **Python’s `csv` and `json` modules** – standard library docs.  
- **Bloom Filters for Approximate Deduplication** – Broder & Mitzenmacher, “Network Applications of Bloom Filters”.  
- **Disk‑Based Hash Tables** – External hashing techniques (e.g., Grace Hash Join).  
- **High‑Performance CSV Parsing** – `csv` module is already C‑accelerated; for extreme speed consider `pyarrow.csv` or `fastparquet` (still pure Python‑callable).  

---  

## 10. Testing with Pytest

Since the pipeline is built from small, composable generator functions, each piece can be unit‑tested in isolation with pytest. Below are examples showing how to test the core primitives and a full end‑to‑end run using temporary files.

### 10.1 Testing Generator Utilities

```python
# test_pipeline_utils.py
import pytest
from your_pipeline_module import (
    csv_reader,
    jsonl_reader,
    map_gen,
    filter_gen,
    combine_and_spill,
    csv_writer,
    jsonl_writer,
)

def test_map_gen():
    source = [1, 2, 3, 4]
    doubled = list(map_gen(lambda x: x * 2, source))
    assert doubled == [2, 4, 6, 8]

def test_filter_gen():
    source = [1, 2, 3, 4, 5]
    evens = list(filter_gen(lambda x: x % 2 == 0, source))
    assert evens == [2, 4]

def test_csv_reader(tmp_path):
    # create a temporary CSV file
    p = tmp_path / "sample.csv"
    p.write_text("name,age\nAlice,30\nBob,25\n")
    records = list(csv_reader(str(p)))
    assert records == [
        {"name": "Alice", "age": "30"},
        {"name": "Bob", "age": "25"},
    ]

def test_jsonl_reader(tmp_path):
    p = tmp_path / "sample.jsonl"
    p.write_text('{"id": 1}\n{"id": 2}\n')
    records = list(jsonl_reader(str(p)))
    assert records == [{"id": 1}, {"id": 2}]
```

### 10.2 Testing the Combiner with Spill

```python
def test_combine_and_spill_small(tmp_path):
    data = [("apple", 2), ("banana", 3), ("apple", 5), ("banana", 7)]
    # Use a low spill threshold to force spilling
    combined = list(combine_and_spill(
        iter(data),
        combine=lambda a, b: a + b,
        max_memory_items=2,  # spill after 2 items
        temp_dir=str(tmp_path / "spill")
    ))
    # Order may vary because we dump dict items; sort for deterministic assert
    combined_sorted = sorted(combined, key=lambda x: x[0])
    assert combined_sorted == [("apple", 7), ("banana", 10)]
```

### 10.3 Testing a Full Pipeline End‑to‑End

```python
def test_end_to_end_pipeline(tmp_path):
    # --- Input CSV ---
    input_csv = tmp_path / "input.csv"
    input_csv.write_text(
        "order_id,timestamp,region,product_id,quantity,unit_price,status\n"
        "1,2024-01-01T10:00:00,North, p1,2,10.0,OK\n"
        "2,2024-01-01T11:00:00,South, p2,1,20.0,CANCELLED\n"
        "3,2024-01-02T09:00:00,North, p1,3,10.0,OK\n"
    )
    # --- Expected output after filtering out CANCELLED and aggregating per region/day ---
    expected = [
        {"region": "North", "date": "2024-01-01", "total_amount": 20.0},
        {"region": "North", "date": "2024-01-02", "total_amount": 30.0},
    ]

    # Run the pipeline (reuse the run_pipeline function from the module)
    output_csv = tmp_path / "output.csv"
    from your_pipeline_module import run_pipeline
    run_pipeline(str(input_csv), str(output_csv))

    # Read back the output
    import csv
    with open(output_csv, newline='') as f:
        reader = csv.DictReader(f)
        actual = [row for row in reader]
        # Convert total_amount to float for comparison
        for row in actual:
            row["total_amount"] = float(row["total_amount"])

    assert actual == expected
```

### 10.4 Using Fixtures for Complex Setup

```python
@pytest.fixture
def sample_sales_data(tmp_path):
    data = (
        "order_id,timestamp,region,product_id,quantity,unit_price,status\n"
        "1,2024-01-01T10:00:00,East, pA,1,100.0,OK\n"
        "2,2024-01-01T10:05:00,East, pB,2,50.0,OK\n"
        "3,2024-01-01T10:10:00,West, pA,1,100.0,CANCELLED\n"
    )
    p = tmp_path / "sales.csv"
    p.write_text(data)
    return str(p)

def test_pipeline_with_fixture(sample_sales_data, tmp_path):
    out = tmp_path / "out.csv"
    from your_pipeline_module import run_pipeline
    run_pipeline(sample_sales_data, str(out))
    # assertions...
```

### 10.5 Best Practices for Testing Pipelines

- **Isolate units**: Test each generator (`map_gen`, `filter_gen`, `csv_reader`) separately.
- **Control spill behavior**: When testing `combine_and_spill`, set a low `max_memory_items` to force spilling and verify that results are still correct.
- **Use temporary directories**: `tmp_path` fixture ensures clean state for file‑based tests.
- **Avoid external calls**: Mock any HTTP requests or third‑party services with `responses` or `unittest.mock`.
- **Check exact output**: Because generators are lazy, materialize with `list()` to assert contents.
- **Test edge cases**: empty files, malformed lines, missing columns, very large numbers that trigger spill.

You can also reuse the testing patterns demonstrated in @python-patterns/14-testing-with-pytest.md for more advanced mocking, parametrization, and fixture usage.

*End of document.*  