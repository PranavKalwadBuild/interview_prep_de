<!-- python-patterns: Concurrency Patterns -->

# Concurrency Patterns

## The GIL — What It Means for DE

The **Global Interpreter Lock** allows only one thread to execute Python bytecode at a time. Key implications:

| Workload | Use | Why |
|---|---|---|
| S3 downloads, API calls, DB queries | `ThreadPoolExecutor` | GIL **releases** during I/O system calls — threads run concurrently |
| XML/JSON parsing, data transforms | `ProcessPoolExecutor` | Separate processes bypass GIL — true CPU parallelism |
| Many async I/O with async-native libs | `asyncio` | Single thread, event loop — zero thread overhead |
| Mixed I/O + CPU | Multiprocessing + threads inside workers | Complex, use sparingly |

```python
# Interview question: "You're downloading 1000 S3 files. Threading or multiprocessing?"
# ANSWER: ThreadPoolExecutor — I/O bound, GIL releases during S3 download syscalls

# Interview question: "You're parsing 1000 large XML files. Threading or multiprocessing?"
# ANSWER: ProcessPoolExecutor — CPU bound, each process has its own GIL
```

---

## `ThreadPoolExecutor`

```python
from concurrent.futures import ThreadPoolExecutor, as_completed

# Pattern 1: map — simple, blocks until ALL done, raises on first exception
def download(key):
    return s3.get_object(Bucket="bucket", Key=key)["Body"].read()

with ThreadPoolExecutor(max_workers=20) as pool:
    results = list(pool.map(download, keys))   # order preserved, matches input order
    # raises the first exception after all tasks complete

# Pattern 2: submit + as_completed — process results as they arrive
futures = {}
with ThreadPoolExecutor(max_workers=16) as pool:
    for table in table_names:
        future = pool.submit(load_table, table, config)
        futures[future] = table   # map future → original input

    for future in as_completed(futures):
        table = futures[future]
        try:
            row_count = future.result()
            logging.info(f"{table}: loaded {row_count} rows")
        except Exception as e:
            logging.error(f"{table} failed: {e}")

# Pattern 3: submit + timeout per future
future = pool.submit(slow_query, table)
try:
    result = future.result(timeout=60)   # raises TimeoutError if not done in 60s
except TimeoutError:
    future.cancel()   # attempt to cancel (may not succeed if already running)
    raise
```

---

## `ProcessPoolExecutor`

```python
from concurrent.futures import ProcessPoolExecutor

# Functions must be picklable (no lambdas, no local functions)
def parse_xml_file(path):
    import xml.etree.ElementTree as ET   # import inside function — safe for multiprocessing
    tree = ET.parse(path)
    return extract_records(tree)

def transform_partition(df_path):
    import pandas as pd
    df = pd.read_parquet(df_path)
    return df.groupby("region")["amount"].sum().to_dict()

with ProcessPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(parse_xml_file, xml_files))

# Gotcha: ProcessPoolExecutor spawns full Python processes — startup overhead
# For many small tasks, overhead > benefit; use only for CPU-heavy tasks that take >1s each
```

### Pickling Limitation

```python
# Functions passed to ProcessPoolExecutor must be picklable
# BAD — lambda is not picklable
with ProcessPoolExecutor() as pool:
    pool.map(lambda x: x**2, data)   # PicklingError

# BAD — closure over local variable
def make_processor(config):
    def process(item):          # closure — not picklable at module level
        return transform(item, config)
    return process

# GOOD — top-level function or functools.partial
import functools
def process_with_config(item, config):
    return transform(item, config)

with ProcessPoolExecutor() as pool:
    results = list(pool.map(
        functools.partial(process_with_config, config=config),
        items
    ))
```

---

## Rate Limiting

```python
import threading, time

class TokenBucket:
    """Thread-safe token bucket rate limiter."""

    def __init__(self, rate_per_second, capacity=None):
        self.rate = rate_per_second
        self.capacity = capacity or rate_per_second
        self.tokens = float(self.capacity)
        self.last_refill = time.monotonic()
        self._lock = threading.Lock()

    def acquire(self):
        with self._lock:
            now = time.monotonic()
            elapsed = now - self.last_refill
            self.tokens = min(self.capacity, self.tokens + elapsed * self.rate)
            self.last_refill = now
            if self.tokens < 1:
                sleep_time = (1 - self.tokens) / self.rate
                time.sleep(sleep_time)
                self.tokens = 0
            else:
                self.tokens -= 1

# Usage: wrap API call with rate limiter
limiter = TokenBucket(rate_per_second=10)   # max 10 calls/second

def rate_limited_fetch(url):
    limiter.acquire()
    return requests.get(url, timeout=30)

with ThreadPoolExecutor(max_workers=20) as pool:
    results = list(pool.map(rate_limited_fetch, urls))
```

---

## `threading` — Lower-Level Patterns

```python
import threading

# Producer-consumer with Queue
from queue import Queue

def producer(queue, items):
    for item in items:
        queue.put(item)
    queue.put(None)   # sentinel to signal done

def consumer(queue, results):
    while True:
        item = queue.get()
        if item is None:
            break
        result = process(item)
        results.append(result)

q = Queue(maxsize=100)   # bounded — producer blocks when full
results = []

t_prod = threading.Thread(target=producer, args=(q, items))
t_cons = threading.Thread(target=consumer, args=(q, results))
t_prod.start(); t_cons.start()
t_prod.join(); t_cons.join()

# threading.Event — signal between threads
stop_event = threading.Event()

def worker():
    while not stop_event.is_set():
        do_work()
        time.sleep(1)

t = threading.Thread(target=worker, daemon=True)
t.start()
# Later:
stop_event.set()   # signals worker to stop

# threading.Lock — mutual exclusion
counter_lock = threading.Lock()
shared_counter = 0

def increment():
    global shared_counter
    with counter_lock:
        shared_counter += 1   # atomic block
```

---

## `asyncio` — When to Use in DE

Use asyncio when:
- API client library is async-native (`aiohttp`, `aiobotocore`, `asyncpg`)
- Need many concurrent I/O operations with minimal thread overhead
- Building event-driven pipelines

```python
import asyncio
import aiohttp

async def fetch_page(session, url, page):
    async with session.get(url, params={"page": page}) as resp:
        resp.raise_for_status()
        return await resp.json()

async def paginate_api(base_url, total_pages):
    async with aiohttp.ClientSession() as session:
        tasks = [
            fetch_page(session, base_url, page)
            for page in range(1, total_pages + 1)
        ]
        # gather — run all concurrently, collect results
        pages = await asyncio.gather(*tasks, return_exceptions=True)

    records = []
    for page_data in pages:
        if isinstance(page_data, Exception):
            logging.error(f"Page failed: {page_data}")
            continue
        records.extend(page_data)
    return records

# Run async from sync context
results = asyncio.run(paginate_api("https://api.example.com/events", total_pages=50))
```

### Mixing Async with Sync Code

```python
import asyncio

# Run blocking sync code in a thread from async context
async def load_to_db_async(df):
    loop = asyncio.get_event_loop()
    # run_in_executor wraps sync call in a thread pool
    await loop.run_in_executor(None, lambda: df.to_sql("table", engine))

# Semaphore — limit concurrency inside async
async def fetch_all_with_limit(urls, limit=10):
    sem = asyncio.Semaphore(limit)

    async def fetch_one(url):
        async with sem:   # at most `limit` concurrent fetches
            async with aiohttp.ClientSession() as s:
                async with s.get(url) as r:
                    return await r.json()

    return await asyncio.gather(*[fetch_one(url) for url in urls])
```

---

## Choosing the Right Tool

```python
# Decision:
# 1. Is the work I/O bound (network, disk, DB)?
#    → ThreadPoolExecutor (simple, effective, GIL releases on I/O)
# 2. Is the work CPU bound (parsing, computing, transforming)?
#    → ProcessPoolExecutor (bypasses GIL, true parallelism)
# 3. Am I using async-native libraries (aiohttp, aiobotocore, asyncpg)?
#    → asyncio (best for high fan-out async I/O)
# 4. Is the task sequential or simple?
#    → Just a loop. Don't add concurrency complexity unnecessarily.

# How many workers?
# ThreadPoolExecutor: 10–50 for I/O bound (depends on API limits, network)
# ProcessPoolExecutor: os.cpu_count() or os.cpu_count() - 1
import os
max_workers = os.cpu_count() - 1 or 1
```

---

## Interview Questions

**Q: What is the GIL and how does it affect threading in Python?**
The GIL (Global Interpreter Lock) ensures only one thread runs Python bytecode at a time. For CPU-bound work, threads give no speedup. For I/O-bound work, the GIL releases during system calls, so threads run concurrently. Use `ProcessPoolExecutor` for CPU-bound, `ThreadPoolExecutor` for I/O-bound.

**Q: `ThreadPoolExecutor.map` vs `submit` + `as_completed` — when to use each?**
`map` is simpler, preserves input order, raises on the first exception. `as_completed` processes results as they finish (order depends on completion time), allows per-task error handling. Use `as_completed` when tasks have variable duration or you need fault tolerance.

**Q: Why can't you pass a lambda to `ProcessPoolExecutor.map`?**
`ProcessPoolExecutor` pickles the function to send it to worker processes. Lambdas and locally defined closures can't be pickled. Use top-level functions or `functools.partial`.

**Q: When would you use `asyncio` instead of `ThreadPoolExecutor` for DE?**
When your I/O library is async-native (aiohttp, aiobotocore, asyncpg) and you need very high concurrency (hundreds of concurrent requests) with minimal overhead. `ThreadPoolExecutor` is simpler and works for moderate concurrency with synchronous libraries.
