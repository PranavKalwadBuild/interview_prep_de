<!-- python-patterns: File and IO Patterns -->

# File and IO Patterns

## pathlib — The Modern Way

```python
from pathlib import Path

# Create path objects
p = Path("/data/raw/2024/events.csv")
p = Path.home() / "data" / "events.csv"   # cross-platform joining with /

# Inspection
p.exists()          # True/False
p.is_file()         # True for files
p.is_dir()          # True for directories
p.stat().st_size    # size in bytes
p.suffix            # ".csv"
p.stem              # "events"
p.name              # "events.csv"
p.parent            # Path("/data/raw/2024")

# Creating
p.parent.mkdir(parents=True, exist_ok=True)   # create all missing dirs

# Globbing
csv_files = list(Path("/data/raw").glob("**/*.csv"))   # recursive
parquet_files = list(Path("/data").glob("*.parquet"))

# Reading/writing
text = p.read_text(encoding="utf-8")
p.write_text("content", encoding="utf-8")
data = p.read_bytes()
p.write_bytes(b"binary content")

# Iteration
for csv_path in sorted(Path("/data").glob("*.csv")):
    process(csv_path)
```

---

## Reading Files

### Text Files

```python
# Basic — entire file into memory
with open("file.txt", encoding="utf-8") as f:
    content = f.read()

# Line by line — O(1) memory
with open("large.txt", encoding="utf-8") as f:
    for line in f:          # file is an iterator
        process(line.rstrip("\n"))

# readlines() — all lines as a list (into memory)
with open("file.txt") as f:
    lines = f.readlines()   # includes \n

# Strip newlines efficiently
lines = [line.rstrip() for line in open("file.txt")]   # one-liner for small files
```

### Binary Chunked Reading

```python
import functools

def read_in_chunks(filepath, chunk_size=65536):
    """Read a binary file in fixed-size chunks."""
    with open(filepath, "rb") as f:
        for chunk in iter(functools.partial(f.read, chunk_size), b""):
            yield chunk

# Useful for: hashing large files, streaming uploads, binary protocols
import hashlib

def sha256_file(filepath):
    h = hashlib.sha256()
    for chunk in read_in_chunks(filepath):
        h.update(chunk)
    return h.hexdigest()
```

---

## CSV Patterns

```python
import csv

# Reading with DictReader — each row is a dict
def read_csv(path, encoding="utf-8"):
    with open(path, encoding=encoding, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            yield row

# Writing with DictWriter
def write_csv(path, records, fieldnames):
    with open(path, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(records)

# Handling custom delimiters, quoting
with open("pipe_delimited.txt") as f:
    reader = csv.DictReader(f, delimiter="|", quotechar='"')

# sniffing dialect from first few lines
with open("unknown.csv") as f:
    sample = f.read(2048)
    dialect = csv.Sniffer().sniff(sample)
    f.seek(0)
    reader = csv.reader(f, dialect)
```

---

## JSON Patterns

```python
import json
from pathlib import Path

# Load/dump — standard
data = json.loads('{"key": "value"}')
text = json.dumps(data, indent=2, ensure_ascii=False)

# File I/O
with open("data.json", encoding="utf-8") as f:
    data = json.load(f)

with open("output.json", "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, default=str)   # default=str handles dates, Decimals

# Streaming JSONL (newline-delimited JSON) — huge datasets
def read_jsonl(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                yield json.loads(line)

def write_jsonl(path, records):
    with open(path, "w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record, default=str) + "\n")

# Custom JSON encoder
class PipelineEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, datetime):
            return obj.isoformat()
        if isinstance(obj, Decimal):
            return float(obj)
        if isinstance(obj, set):
            return list(obj)
        return super().default(obj)

json.dumps(data, cls=PipelineEncoder)
```

---

## YAML Patterns

```python
import yaml

# Load config — use safe_load (never yaml.load without Loader)
with open("config.yml") as f:
    config = yaml.safe_load(f)

# Write
with open("output.yml", "w") as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

# Multi-document YAML (---)
with open("multi.yml") as f:
    docs = list(yaml.safe_load_all(f))

# Typical DE config YAML
config_yaml = """
pipeline:
  source_bucket: my-bucket
  target_schema: prod
  batch_size: 10000
  tables:
    - orders
    - customers
    - products
"""
config = yaml.safe_load(config_yaml)
tables = config["pipeline"]["tables"]  # ["orders", "customers", "products"]
```

---

## Parquet with PyArrow (No Pandas)

```python
import pyarrow as pa
import pyarrow.parquet as pq

# Write
table = pa.table({
    "id": [1, 2, 3],
    "name": ["alice", "bob", "charlie"],
    "amount": [10.5, 20.0, 30.75],
})
pq.write_table(table, "output.parquet", compression="snappy")

# Read
table = pq.read_table("output.parquet")
df = table.to_pandas()

# Selective column read (avoids loading all columns)
table = pq.read_table("large.parquet", columns=["id", "amount"])

# Chunked reading — critical for large files
parquet_file = pq.ParquetFile("large.parquet")
for batch in parquet_file.iter_batches(batch_size=100_000):
    df = batch.to_pandas()
    process(df)

# Schema inspection
schema = pq.read_schema("file.parquet")
metadata = pq.read_metadata("file.parquet")
metadata.num_rows        # total rows
metadata.num_row_groups  # how many row groups

# Partitioned read — only read relevant partitions
dataset = pq.ParquetDataset("s3://bucket/data/", filters=[("region", "=", "US")])
table = dataset.read()
```

---

## Temporary Files and Atomic Writes

```python
import tempfile, os, shutil

# tempfile — auto-cleaned temp file
with tempfile.NamedTemporaryFile(suffix=".csv", delete=False) as tmp:
    tmp_path = tmp.name
    tmp.write(b"id,name\n1,alice\n")
# file persists after with block (delete=False)
# clean up manually:
os.unlink(tmp_path)

# tempfile as intermediate for atomic write
def atomic_write_csv(target_path, records):
    """Write to temp, then rename atomically — safe for concurrent readers."""
    dir_path = os.path.dirname(target_path)
    with tempfile.NamedTemporaryFile(
        mode="w", dir=dir_path, suffix=".tmp", delete=False, encoding="utf-8"
    ) as tmp:
        writer = csv.DictWriter(tmp, fieldnames=records[0].keys())
        writer.writeheader()
        writer.writerows(records)
        tmp_path = tmp.name
    os.replace(tmp_path, target_path)   # atomic on POSIX, near-atomic on Windows

# tempfile directory
with tempfile.TemporaryDirectory() as tmpdir:
    local_path = os.path.join(tmpdir, "data.csv")
    download_from_s3(bucket, key, local_path)
    df = pd.read_csv(local_path)
# tmpdir and all contents deleted automatically
```

---

## File Watching / Detection

```python
import os, time

def wait_for_file(path, timeout=300, poll_interval=5):
    """Block until a file appears or timeout."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return True
        time.sleep(poll_interval)
    raise TimeoutError(f"File {path} did not appear within {timeout}s")

# File modification time — detect new files since last run
import glob

def files_modified_after(directory, pattern, cutoff_ts):
    for path in glob.glob(os.path.join(directory, pattern)):
        if os.path.getmtime(path) > cutoff_ts:
            yield path
```

---

## Interview Questions

**Q: Why use `pathlib.Path` over `os.path`?**
`pathlib` is object-oriented, more readable, and cross-platform. Path joining with `/` operator avoids string concatenation bugs. Methods like `.glob()`, `.mkdir(parents=True)`, `.read_text()` are more ergonomic than `os.path` equivalents.

**Q: How do you read a 10 GB CSV file in Python without running out of memory?**
Open the file as an iterator (file objects iterate line by line in O(1) memory), or use `csv.DictReader` which is lazy. Process rows in batches, yield them as chunks from a generator. Never call `f.readlines()` or `list(reader)` on large files.

**Q: What's the difference between `json.load()` and `json.loads()`?**
`json.load(f)` reads from a file object (stream). `json.loads(s)` parses a string. Same for `json.dump` / `json.dumps`.

**Q: Why is `yaml.load()` dangerous?**
Without a `Loader`, it can execute arbitrary Python objects. Always use `yaml.safe_load()` which restricts to primitive Python types.

**Q: What is JSONL and when do you use it over JSON?**
JSON Lines (newline-delimited JSON) stores one JSON object per line. Allows streaming reads (no need to parse the whole file), easy appending, and works well with `grep`, `wc -l`, and Spark's `spark.read.json()`. Standard JSON requires loading the entire file to parse.
