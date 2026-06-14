<!-- python-patterns: DE Scripting: boto3 and requests -->

# DE Scripting: boto3 and requests

## boto3 Setup

```python
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, NoCredentialsError

# Always configure retries and timeouts
config = Config(
    retries={
        "max_attempts": 5,
        "mode": "adaptive",    # adaptive backs off when throttled; "standard" is simpler
    },
    connect_timeout=5,
    read_timeout=30,
)

s3 = boto3.client("s3", region_name="us-east-1", config=config)
```

---

## S3 — Core Patterns

### Upload and Download

```python
import boto3

s3 = boto3.client("s3")

# Upload
s3.upload_file("/local/path/file.csv", "my-bucket", "prefix/file.csv")
s3.put_object(Bucket="my-bucket", Key="prefix/data.json", Body=json.dumps(data).encode())

# Download
s3.download_file("my-bucket", "prefix/file.csv", "/local/path/file.csv")
obj = s3.get_object(Bucket="my-bucket", Key="prefix/data.json")
content = obj["Body"].read().decode("utf-8")

# Stream large file — don't load entire response into memory
response = s3.get_object(Bucket="my-bucket", Key="huge.csv")
for chunk in response["Body"].iter_chunks(chunk_size=65536):
    process_chunk(chunk)
```

### Pagination — Critical Gotcha

```python
# BAD — list_objects_v2 returns max 1,000 objects
response = s3.list_objects_v2(Bucket="bucket", Prefix="raw/")
keys = [obj["Key"] for obj in response.get("Contents", [])]
# Silent truncation if > 1,000 objects

# GOOD — always use paginator
def list_all_keys(bucket, prefix="", suffix=None):
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if suffix is None or key.endswith(suffix):
                yield key

# Usage
parquet_keys = list(list_all_keys("my-bucket", prefix="raw/2024/", suffix=".parquet"))
```

### Multipart Upload for Large Files

```python
import boto3
from boto3.s3.transfer import TransferConfig

s3_resource = boto3.resource("s3")

transfer_config = TransferConfig(
    multipart_threshold=100 * 1024 * 1024,    # 100MB — files above this use multipart
    multipart_chunksize=100 * 1024 * 1024,    # 100MB per part
    max_concurrency=10,                        # parallel upload threads
    use_threads=True,
)

s3_resource.meta.client.upload_file(
    "/local/large_file.parquet",
    "my-bucket",
    "output/large_file.parquet",
    Config=transfer_config,
)
```

### Check if Object Exists

```python
from botocore.exceptions import ClientError

def s3_key_exists(bucket, key):
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "404":
            return False
        raise   # unexpected error — re-raise
```

### S3 Select (Server-Side Filtering)

```python
# Run SQL directly on S3 — avoids downloading entire file
response = s3.select_object_content(
    Bucket="my-bucket",
    Key="raw/events.csv",
    ExpressionType="SQL",
    Expression="SELECT * FROM S3Object WHERE event_type = 'click'",
    InputSerialization={"CSV": {"FileHeaderInfo": "USE"}, "CompressionType": "NONE"},
    OutputSerialization={"CSV": {}},
)
for event in response["Payload"]:
    if "Records" in event:
        data = event["Records"]["Payload"].decode("utf-8")
```

---

## Secrets Management

```python
import boto3, json

# Secrets Manager — for structured secrets (DB passwords, API keys)
def get_secret(secret_name, region="us-east-1"):
    client = boto3.client("secretsmanager", region_name=region)
    response = client.get_secret_value(SecretId=secret_name)
    if "SecretString" in response:
        return json.loads(response["SecretString"])
    return response["SecretBinary"]   # binary secret

db_creds = get_secret("prod/db/postgres")
# {"host": "...", "port": 5432, "username": "...", "password": "..."}

# SSM Parameter Store — for simple strings
def get_parameter(name, with_decryption=True):
    ssm = boto3.client("ssm")
    return ssm.get_parameter(Name=name, WithDecryption=with_decryption)["Parameter"]["Value"]

api_key = get_parameter("/prod/my-pipeline/api-key")
```

---

## SQS — Message Queue Patterns

```python
sqs = boto3.client("sqs")
QUEUE_URL = "https://sqs.us-east-1.amazonaws.com/123456789/my-queue"

# Send message
sqs.send_message(
    QueueUrl=QUEUE_URL,
    MessageBody=json.dumps({"table": "orders", "date": "2024-01-01"}),
)

# Receive and process (long poll)
def consume_queue(process_fn, max_messages=10, wait_seconds=20):
    while True:
        response = sqs.receive_message(
            QueueUrl=QUEUE_URL,
            MaxNumberOfMessages=max_messages,
            WaitTimeSeconds=wait_seconds,   # long polling — reduces empty responses
        )
        messages = response.get("Messages", [])
        if not messages:
            break
        for msg in messages:
            body = json.loads(msg["Body"])
            try:
                process_fn(body)
                sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])
            except Exception as e:
                logging.error(f"Failed processing {body}: {e}")
                # don't delete — message returns to queue after visibility timeout
```

---

## requests — HTTP Client Patterns

### Session with Retry

```python
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

def build_http_session(
    total_retries=5,
    backoff_factor=1.0,                         # waits: 1, 2, 4, 8, 16 seconds
    status_forcelist=(429, 500, 502, 503, 504), # retry these HTTP status codes
    allowed_methods=("GET", "POST"),
):
    session = requests.Session()
    retry = Retry(
        total=total_retries,
        backoff_factor=backoff_factor,
        status_forcelist=status_forcelist,
        allowed_methods=allowed_methods,
        raise_on_status=True,
    )
    adapter = HTTPAdapter(max_retries=retry)
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    return session

# Attach auth header once — applies to all requests
session = build_http_session()
session.headers.update({"Authorization": f"Bearer {api_token}"})
```

### Paginated API Ingestion

```python
def paginate_api(base_url, params=None, page_param="page", page_size_param="per_page",
                 page_size=100, session=None):
    """Generic paginator for offset-based APIs."""
    session = session or build_http_session()
    page = 1
    params = dict(params or {})
    params[page_size_param] = page_size

    while True:
        params[page_param] = page
        resp = session.get(base_url, params=params, timeout=30)
        resp.raise_for_status()
        data = resp.json()

        if not data:
            break

        yield from data   # lazily yield each record
        page += 1

# Cursor-based pagination (modern APIs)
def paginate_cursor(base_url, session=None):
    session = session or build_http_session()
    cursor = None

    while True:
        params = {"cursor": cursor} if cursor else {}
        resp = session.get(base_url, params=params, timeout=30)
        resp.raise_for_status()
        body = resp.json()

        yield from body["data"]

        cursor = body.get("next_cursor")
        if not cursor:
            break
```

### Respect `Retry-After` Header

```python
import time

def get_with_retry_after(session, url, max_wait=300):
    while True:
        resp = session.get(url, timeout=30)
        if resp.status_code == 429:
            retry_after = int(resp.headers.get("Retry-After", 60))
            if retry_after > max_wait:
                raise RuntimeError(f"Retry-After {retry_after}s exceeds max {max_wait}s")
            logging.warning(f"Rate limited — waiting {retry_after}s")
            time.sleep(retry_after)
            continue
        resp.raise_for_status()
        return resp
```

### Streaming Large HTTP Responses

```python
def stream_download(url, local_path, chunk_size=65536):
    """Stream a large file download — never fully in memory."""
    with requests.get(url, stream=True, timeout=30) as resp:
        resp.raise_for_status()
        with open(local_path, "wb") as f:
            for chunk in resp.iter_content(chunk_size=chunk_size):
                f.write(chunk)

# With progress tracking
def stream_with_progress(url, local_path):
    with requests.get(url, stream=True, timeout=60) as resp:
        resp.raise_for_status()
        total = int(resp.headers.get("Content-Length", 0))
        downloaded = 0
        with open(local_path, "wb") as f:
            for chunk in resp.iter_content(chunk_size=65536):
                f.write(chunk)
                downloaded += len(chunk)
                if total:
                    pct = downloaded / total * 100
                    logging.debug(f"Download: {pct:.1f}%")
```

---

## ClientError Handling

```python
from botocore.exceptions import ClientError

def safe_s3_read(bucket, key):
    try:
        obj = s3.get_object(Bucket=bucket, Key=key)
        return obj["Body"].read()
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("NoSuchKey", "404"):
            return None         # file doesn't exist
        elif code == "AccessDenied":
            raise PermissionError(f"No access to s3://{bucket}/{key}") from e
        elif code in ("RequestTimeout", "ServiceUnavailable"):
            raise   # let retry logic handle it
        else:
            raise   # unexpected — propagate

# Always inspect the error code, not just the exception type
# ClientError covers many different HTTP errors from AWS
```

---

## Interview Questions

**Q: Why do you always use `paginator` for `list_objects_v2` in boto3?**
`list_objects_v2` returns max 1,000 keys per call. Paginators automatically handle `ContinuationToken` and make multiple calls transparently. Missing this means silently processing only the first 1,000 of potentially millions of objects.

**Q: What's `mode="adaptive"` in boto3 retry config?**
Adaptive mode uses token bucket algorithm to slow down when the service returns throttling errors. Standard mode uses fixed exponential backoff. Adaptive is better for APIs that return `429` or `503` under sustained load.

**Q: How do you build a requests session that retries on 429 and 503 but not on 400 or 404?**
Use `HTTPAdapter` + `Retry` with `status_forcelist=(429, 500, 502, 503, 504)`. 4xx client errors (except 429) indicate bad request — no point retrying.

**Q: How do you download a 5 GB file from an API without running out of memory?**
`requests.get(url, stream=True)` with `resp.iter_content(chunk_size=...)`. This streams the response in chunks without loading the whole body. Write each chunk to disk immediately.
