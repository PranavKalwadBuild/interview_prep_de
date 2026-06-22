# Handling REST APIs in Python

Python provides several libraries for interacting with HTTP‑based REST APIs. The most common choice is **requests** for synchronous code; for asynchronous workloads **httpx** or **aiohttp** are preferred. This guide covers patterns for consuming REST services, handling authentication, errors, pagination, rate limits, and best practices.

## 1. Synchronous Requests with `requests`

### Basic GET
```python
import requests

response = requests.get("https://api.example.com/v1/resource", params={"limit": 10})
response.raise_for_status()          # raise HTTPError for 4xx/5xx
data = response.json()               # parse JSON body
```

### POST with JSON Payload
```python
payload = {"name": "Alice", "age": 30}
headers = {"Content-Type": "application/json"}
response = requests.post(
    "https://api.example.com/v1/users",
    json=payload,                    # automatically sets Content‑Type and encodes
    headers=headers,
    timeout=10                       # seconds
)
response.raise_for_status()
created = response.json()
```

### Sending Form‑Data or Files
```python
# multipart/form‑data
files = {"file": ("report.pdf", open("report.pdf", "rb"), "application/pdf")}
data = {"description": "Quarterly report"}
resp = requests.post("https://api.example.com/v1/upload", data=data, files=files)
```

### Custom Headers & Authentication
```python
# Bearer token (OAuth2 / JWT)
headers = {"Authorization": "Bearer <access_token>"}
resp = requests.get("https://api.example.com/v1/private", headers=headers)

# API key via query or header
resp = requests.get(
    "https://api.example.com/v1/data",
    params={"api_key": "<key>"},          # or headers={"X-Api-Key": "<key>"}
)

# Basic Auth
resp = requests.get(url, auth=("user", "pass"))
```

### Session Objects (connection pooling, cookie persistence)
```python
with requests.Session() as session:
    session.headers.update({"Authorization": "Bearer token"})
    session.mount("https://api.example.com", requests.adapters.HTTPAdapter(max_retries=3))
    r1 = session.get("https://api.example.com/v1/a")
    r2 = session.get("https://api.example.com/v1/b")
    # underlying TCP connection is reused
```

### Retry Strategy
```python
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

retry_strategy = Retry(
    total=3,
    backoff_factor=1,
    status_forcelist=[429, 500, 502, 503, 504],
    allowed_methods=["HEAD", "GET", "OPTIONS"]
)
adapter = HTTPAdapter(max_retries=retry_strategy)
session = requests.Session()
session.mount("https://", adapter)
session.mount("http://", adapter)
```

## 2. Asynchronous HTTP Clients

### httpx (supports both sync and async)
```python
import httpx
import asyncio

async def fetch():
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get("https://api.example.com/v1/data")
        resp.raise_for_status()
        return resp.json()

data = asyncio.run(fetch())
```

### aiohttp
```python
import aiohttp
import asyncio

async def fetch():
    async with aiohttp.ClientSession() as session:
        async with session.get("https://api.example.com/v1/data") as resp:
            resp.raise_for_status()
            return await resp.json()

data = asyncio.run(fetch())
```

## 3. Pagination Patterns

### Offset‑Limit (page number)
```python
def fetch_all_offset(base_url, params=None):
    if params is None: params = {}
    results = []
    limit = 100
    offset = 0
    while True:
        params.update({"limit": limit, "offset": offset})
        resp = requests.get(base_url, params=params)
        resp.raise_for_status()
        page = resp.json()
        results.extend(page["items"])
        if len(page["items"]) < limit:
            break
        offset += limit
    return results
```

### Cursor‑Based (token from response)
```python
def fetch_all_cursor(base_url):
    results = []
    cursor = None
    while True:
        params = {}
        if cursor:
            params["cursor"] = cursor
        resp = requests.get(base_url, params=params)
        resp.raise_for_status()
        data = resp.json()
        results.extend(data["items"])
        cursor = data.get("next_cursor")
        if not cursor:
            break
    return results
```

### Link‑Header (RFC 5988)
```python
def fetch_all_link_header(url):
    results = []
    while url:
        resp = requests.get(url)
        resp.raise_for_status()
        data = resp.json()
        results.extend(data["items"])
        # Parse Link: <https://api.example.com/...>; rel="next"
        link = resp.headers.get("Link", "")
        next_url = None
        for part in link.split(","):
            if 'rel="next"' in part:
                next_part = part[part.find("<")+1:part.find(">")]
                next_url = next_part
                break
        url = next_url
    return results
```

## 4. Rate Limiting & Throttling

### Respect `Retry-After` Header (429 Too Many Requests)
```python
def get_with_backoff(url, **kwargs):
    while True:
        resp = requests.get(url, **kwargs)
        if resp.status_code == 429:
            retry_after = int(resp.headers.get("Retry-After", "1"))
            time.sleep(retry_after)
            continue
        resp.raise_for_status()
        return resp
```

### Token Bucket / Leaky Bucket with `ratelimit` library
```python
from ratelimit import limits, sleep_and_retry

# 10 calls per second
@sleep_and_retry
@limits(calls=10, period=1)
def limited_get(url):
    return requests.get(url)
```

## 5. Error Handling

### Distinguish HTTP errors, connection errors, timeouts
```python
try:
    resp = requests.get(url, timeout=5)
    resp.raise_for_status()
except requests.exceptions.Timeout:
    logger.error("Request timed out")
except requests.exceptions.ConnectionError as exc:
    logger.error(f"Connection error: {exc}")
except requests.exceptions.HTTPError as exc:
    logger.error(f"HTTP {resp.status_code}: {resp.text}")
except requests.exceptions.RequestException as exc:
    logger.error(f"Unexpected error: {exc}")
```

### Raise Custom Exceptions for API‑specific error payloads
```python
class APIError(Exception):
    def __init__(self, status_code, message, payload=None):
        self.status_code = status_code
        self.message = message
        self payload = payload
        super().__init__(f"[{status_code}] {message}")

def safe_request(method, url, **kwargs):
    resp = requests.request(method, url, **kwargs)
    try:
        resp.raise_for_status()
    except requests.HTTPError:
        # try to parse JSON error body
        try:
            err = resp.json()
            msg = err.get("message", resp.text)
        except ValueError:
            msg = resp.text
        raise APIError(resp.status_code, msg, err)
    return resp.json()
```

## 6. Streaming Large Responses

### Iterate over chunks to avoid loading entire payload into memory
```python
with requests.get("https://api.example.com/v1/large-file", stream=True) as r:
    r.raise_for_status()
    with open("output.bin", "wb") as f:
        for chunk in r.iter_content(chunk_size=8192):
            if chunk:  # filter out keep‑alive chunks
                f.write(chunk)
```

### Server‑Sent Events (SSE) – simple line‑by‑line parse
```python
def listen_events(url):
    with requests.get(url, stream=True) as r:
        r.raise_for_status()
        for line in r.iter_lines():
            if line:
                decoded = line.decode("utf-8")
                if decoded.startswith("data:"):
                    yield json.loads(decoded[5:].strip())
```

## 7. Best Practices & Checklist

- [ ] Use a session/connection pool for repeated calls to the same host.
- [ ] Set sensible timeouts (connect & read) to avoid hanging threads.
- [ ] Prefer `json=` parameter over manual `json.dumps` + `data=` for JSON bodies.
- [ ] Validate status codes with `raise_for_status()` or explicit checks.
- [ ] Never log raw Authorization headers or tokens.
- [ ] Retry only idempotent methods (GET, HEAD, PUT, DELETE) unless the API guarantees safety.
- [ ] Respect `Retry-After` and back‑off exponentially to avoid thundering herd.
- [ ] Prefer asynchronous clients for high‑concurrency I/O‑bound workloads.
- [ ] When dealing with pagination, detect duplicate items and enforce a max‑pages guard.
- [ ] Use typing (`TypedDict`, `dataclasses`) to model JSON payloads for IDE support.
- [ ] Mock external services in unit tests with `responses` or `requests-mock`.
- [ ] Consider circuit‑breaker pattern (e.g., `pybreaker`) for unstable downstream services.
- [ ] For file uploads, stream the file instead of reading it fully into memory.
- [ ] Close response objects or use context managers to release connections.

## 8. Example: Minimal Wrapper Class

```python
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from typing import Any, Dict, Optional

class APIClient:
    BASE_URL = "https://api.example.com/v1"

    def __init__(self, token: str, timeout: float = 10.0, max_retries: int = 3):
        self.session = requests.Session()
        self.session.headers.update({"Authorization": f"Bearer {token}"})
        retry = Retry(
            total=max_retries,
            backoff_factor=0.5,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["frozenset", "GET", "HEAD", "OPTIONS", "POST", "PUT", "DELETE"]
        )
        adapter = HTTPAdapter(max_retries=retry)
        self.session.mount("https://", adapter)
        self.session.mount("http://", adapter)
        self.timeout = timeout

    def _request(self, method: str, path: str, **kwargs) -> Dict[str, Any]:
        url = f"{self.BASE_URL}{path}"
        kwargs.setdefault("timeout", self.timeout)
        resp = self.session.request(method, url, **kwargs)
        try:
            resp.raise_for_status()
        except requests.HTTPError as exc:
            # attempt to extract structured error
            try:
                err = resp.json()
                msg = err.get("error", resp.text)
            except ValueError:
                msg = resp.text
            raise APIError(resp.status_code, msg, err) from exc
        return resp.json()

    def get(self, path: str, params: Optional[Dict] = None) -> Dict[str, Any]:
        return self._request("GET", path, params=params)

    def post(self, path: str, json: Optional[Dict] = None, **kwargs) -> Dict[str, Any]:
        return self._request("POST", path, json=json, **kwargs)

# usage
# client = APIClient(token="my-token")
# data = client.get("/users", params={"active": "true"})
```

--- 
*This file provides a comprehensive overview of patterns for consuming REST APIs in Python, covering both synchronous and asynchronous approaches, authentication, pagination, rate limiting, error handling, and production‑ready practices.*
