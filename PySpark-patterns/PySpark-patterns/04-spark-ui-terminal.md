# Spark UI via Terminal (REST API)

> Get all Spark UI data as JSON from the terminal using curl + jq.
> No browser required. Every tab in the UI has a corresponding REST endpoint.

---

## Base URLs

| Deployment | Base URL |
|------------|----------|
| Running app (any) | `http://driver-host:4040/api/v1` |
| Spark History Server | `http://history-server:18080/api/v1` |
| YARN cluster mode | `http://namenode:8088/proxy/application_<id>/api/v1` |
| Databricks (from notebook) | See section below |

```bash
# Quick test — is the API available?
curl -s http://localhost:4040/api/v1/applications | jq '.[].id'
```

---

## Databricks Access

Databricks exposes the Spark REST API via a driver proxy URL. Access from a notebook:

```python
# From a Databricks notebook cell — get your token and cluster info
from dbruntime.databricks_repl_context import get_context
import requests

ctx = get_context()
HOST = ctx.browserHostName        # e.g., "myworkspace.azuredatabricks.net"
CLUSTER_ID = ctx.clusterId        # e.g., "0101-123456-abcde123"
TOKEN = ctx.apiToken

BASE = f"https://{HOST}/driver-proxy-api/o/0/{CLUSTER_ID}/40001/api/v1"
HEADERS = {"Authorization": f"Bearer {TOKEN}"}

# Get app ID
apps = requests.get(f"{BASE}/applications", headers=HEADERS).json()
APP_ID = apps[0]["id"]

# Now call any endpoint
stages = requests.get(f"{BASE}/applications/{APP_ID}/stages", headers=HEADERS).json()
```

**From terminal (outside Databricks)**:
```bash
HOST="myworkspace.azuredatabricks.net"
CLUSTER_ID="0101-123456-abcde123"
TOKEN="dapi..."
BASE="https://${HOST}/driver-proxy-api/o/0/${CLUSTER_ID}/40001/api/v1"

APP_ID=$(curl -s "${BASE}/applications" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id')
echo "App ID: ${APP_ID}"
```

---

## Complete Endpoint Reference

### Applications

```bash
# List all apps (history server)
GET /api/v1/applications
  ?status=completed|running
  ?minDate=2024-01-01T00:00:00.000GMT
  ?maxDate=2024-01-02T00:00:00.000GMT
  ?limit=10

# Single app
GET /api/v1/applications/{app-id}
```

### Jobs

```bash
GET /api/v1/applications/{app-id}/jobs
  ?status=running|succeeded|failed|unknown

GET /api/v1/applications/{app-id}/jobs/{job-id}
```

### Stages

```bash
GET /api/v1/applications/{app-id}/stages
  ?status=active|complete|pending|failed
  ?details=true                           # include all task data inline
  ?withSummaries=true                     # include metric quantile distributions
  ?quantiles=0.0,0.25,0.5,0.75,1.0       # requires withSummaries=true
  ?taskStatus=RUNNING|SUCCESS|FAILED|KILLED|PENDING   # requires details=true

GET /api/v1/applications/{app-id}/stages/{stage-id}
GET /api/v1/applications/{app-id}/stages/{stage-id}/{attempt-id}
```

### Task Summary (percentiles for all tasks in a stage)

```bash
GET /api/v1/applications/{app-id}/stages/{stage-id}/{attempt-id}/taskSummary
  ?quantiles=0.01,0.25,0.5,0.75,0.99
```

Returns distributions for: executorRunTime, jvmGcTime, gettingResultTime,
schedulerDelay, peakExecutionMemory, inputMetrics, shuffleReadMetrics, shuffleWriteMetrics.

### Task List (individual task records)

```bash
GET /api/v1/applications/{app-id}/stages/{stage-id}/{attempt-id}/taskList
  ?offset=0&length=100
  ?sortBy=runtime|-runtime|inputSize|-inputSize|shuffleRead|-shuffleRead
  ?status=running|success|killed|failed|unknown
```

### Executors

```bash
GET /api/v1/applications/{app-id}/executors        # active executors only
GET /api/v1/applications/{app-id}/allexecutors     # active + dead executors
GET /api/v1/applications/{app-id}/executors/{executor-id}/threads  # thread dumps (live only)
```

### Storage (RDD cache)

```bash
GET /api/v1/applications/{app-id}/storage/rdd
GET /api/v1/applications/{app-id}/storage/rdd/{rdd-id}
```

### SQL / DataFrame Queries

```bash
GET /api/v1/applications/{app-id}/sql
  ?details=true|false          # include plan node metrics (default true)
  ?planDescription=true        # include physical plan text (default true)
  ?offset=0&length=20

GET /api/v1/applications/{app-id}/sql/{execution-id}
  ?details=true|false
```

### Environment

```bash
GET /api/v1/applications/{app-id}/environment
# Returns: sparkProperties, jvmInformation, systemProperties, classpathEntries
```

### Logs

```bash
GET /api/v1/applications/{app-id}/logs                    # all attempt logs (zip)
GET /api/v1/applications/{app-id}/{attempt-id}/logs       # specific attempt (zip)
```

### Streaming

```bash
GET /api/v1/applications/{app-id}/streaming/statistics
GET /api/v1/applications/{app-id}/streaming/batches
GET /api/v1/applications/{app-id}/streaming/batches/{batch-id}
GET /api/v1/applications/{app-id}/streaming/batches/{batch-id}/operations
```

### Version & Prometheus

```bash
GET /api/v1/version                                # Spark version
GET /metrics/executors/prometheus                  # Prometheus format (requires spark.ui.prometheus.enabled=true)
```

---

## curl / jq Recipes

Set these once at the top of your session:

```bash
BASE="http://localhost:4040/api/v1"
APP_ID=$(curl -s "${BASE}/applications" | jq -r '.[0].id')
# For history server:
# APP_ID="application_1234567890123_0001"
```

---

### Jobs Tab equivalent — list all jobs with status

```bash
curl -s "${BASE}/applications/${APP_ID}/jobs" \
  | jq '.[] | {jobId, name: .name, status, numTasks, duration: (.submissionTime | todate)}'
```

---

### Stages Tab equivalent — all stages with spill and skew indicators

```bash
curl -s "${BASE}/applications/${APP_ID}/stages" \
  | jq '.[] | {
      stageId,
      name,
      status,
      numTasks,
      duration_ms: (if .completionTime and .submissionTime
                    then (.completionTime - .submissionTime) else null end),
      inputBytes,
      shuffleReadBytes,
      shuffleWriteBytes,
      memoryBytesSpilled,
      diskBytesSpilled,
      numFailedTasks
    }'
```

---

### Find stages with any disk spill

```bash
curl -s "${BASE}/applications/${APP_ID}/stages" \
  | jq '[.[] | select(.diskBytesSpilled > 0)] | sort_by(-.diskBytesSpilled) | .[] | {
      stageId,
      name,
      diskBytesSpilled,
      memoryBytesSpilled,
      shuffleReadBytes
    }'
```

---

### Find slow stages (> 5 minutes)

```bash
curl -s "${BASE}/applications/${APP_ID}/stages" \
  | jq '[.[] | select(.submissionTime != null and .completionTime != null)] |
    map(. + {duration_ms: (.completionTime - .submissionTime)}) |
    [.[] | select(.duration_ms > 300000)] |
    sort_by(-.duration_ms) | .[] |
    {stageId, name, duration_ms, numTasks, shuffleReadBytes, diskBytesSpilled}'
```

---

### Task Summary — detect skew in a specific stage

```bash
STAGE_ID=5
ATTEMPT=0

curl -s "${BASE}/applications/${APP_ID}/stages/${STAGE_ID}/${ATTEMPT}/taskSummary?quantiles=0.25,0.5,0.75,0.99,1.0" \
  | jq '{
      duration_ms: {
        p25:    .executorRunTime.quantiles[0],
        median: .executorRunTime.quantiles[1],
        p75:    .executorRunTime.quantiles[2],
        p99:    .executorRunTime.quantiles[3],
        max:    .executorRunTime.quantiles[4]
      },
      shuffle_read_bytes: {
        median: .shuffleReadBytes.quantiles[1],
        p99:    .shuffleReadBytes.quantiles[3],
        max:    .shuffleReadBytes.quantiles[4]
      },
      gc_time_ms: {
        median: .jvmGcTime.quantiles[1],
        max:    .jvmGcTime.quantiles[4]
      },
      peak_exec_mem_bytes: {
        median: .peakExecutionMemory.quantiles[1],
        max:    .peakExecutionMemory.quantiles[4]
      }
    }'
```

**Skew indicator**: `max / median > 5` for duration or shuffle_read_bytes.

---

### Task List — top 10 tasks by shuffle read (find the hot-key task)

```bash
STAGE_ID=5
ATTEMPT=0

curl -s "${BASE}/applications/${APP_ID}/stages/${STAGE_ID}/${ATTEMPT}/taskList?length=1000&sortBy=-shuffleRead" \
  | jq '.[0:10] | .[] | {
      taskId,
      host,
      status,
      duration_ms: .duration,
      shuffleReadBytes: .taskMetrics.shuffleReadMetrics.remoteBytesRead,
      shuffleWriteBytes: .taskMetrics.shuffleWriteMetrics.bytesWritten,
      diskSpilledBytes: .taskMetrics.diskBytesSpilled,
      memSpilledBytes: .taskMetrics.memoryBytesSpilled,
      gcTime_ms: .taskMetrics.jvmGcTime,
      peakExecMem: .taskMetrics.peakExecutionMemory
    }'
```

---

### Task List — find all failed tasks

```bash
STAGE_ID=5
ATTEMPT=0

curl -s "${BASE}/applications/${APP_ID}/stages/${STAGE_ID}/${ATTEMPT}/taskList?length=1000&status=failed" \
  | jq '.[] | {
      taskId,
      host,
      errorMessage,
      duration_ms: .duration,
      speculative
    }'
```

---

### Executors Tab — GC pressure check

```bash
curl -s "${BASE}/applications/${APP_ID}/executors" \
  | jq '.[] | {
      id,
      host: .hostPort,
      state: (if .isActive then "ACTIVE" else "DEAD" end),
      totalGCTime_ms: .totalGCTime,
      totalTaskTime_ms: .totalDuration,
      gc_pct: (if .totalDuration > 0
               then (.totalGCTime / .totalDuration * 100 | round)
               else 0 end),
      failed_tasks: .failedTasks,
      memUsed_bytes: .memoryUsed,
      memMax_bytes: .maxMemory,
      diskUsed_bytes: .diskUsed
    } | select(.gc_pct > 10)'
```

Output only executors with GC > 10%.

---

### Executors Tab — find dead executors

```bash
curl -s "${BASE}/applications/${APP_ID}/allexecutors" \
  | jq '[.[] | select(.isActive == false)] | .[] | {
      id,
      host: .hostPort,
      failed_tasks: .failedTasks,
      totalGCTime_ms: .totalGCTime,
      totalDuration_ms: .totalDuration
    }'
```

---

### SQL Tab — find longest-running queries

```bash
curl -s "${BASE}/applications/${APP_ID}/sql?details=false&length=100" \
  | jq 'sort_by(-.duration) | .[0:5] | .[] | {
      id,
      description,
      duration_ms: .duration,
      status,
      numJobs: (.successJobIds | length)
    }'
```

---

### SQL Tab — get plan for a specific query

```bash
SQL_ID=3

curl -s "${BASE}/applications/${APP_ID}/sql/${SQL_ID}?details=true" \
  | jq '{
      description,
      duration_ms: .duration,
      physicalPlanDescription,
      nodes: [.nodes[] | {
        nodeName,
        metrics: [.metrics[] | {name, value}]
      }]
    }'
```

---

### Storage Tab — cached dataset status

```bash
curl -s "${BASE}/applications/${APP_ID}/storage/rdd" \
  | jq '.[] | {
      name,
      storageLevel,
      numCachedPartitions,
      numPartitions,
      fractionCached: (.numCachedPartitions / .numPartitions * 100 | round | tostring + "%"),
      memoryUsed_bytes: .memoryUsed,
      diskUsed_bytes: .diskUsed
    }'
```

---

### Environment Tab — check specific config

```bash
curl -s "${BASE}/applications/${APP_ID}/environment" \
  | jq '.sparkProperties | map(select(.[0] | startswith("spark.sql.adaptive"))) | .[] | {key: .[0], value: .[1]}'
```

Check all shuffle-related configs:
```bash
curl -s "${BASE}/applications/${APP_ID}/environment" \
  | jq '.sparkProperties | map(select(.[0] | test("shuffle|broadcast|adaptive|partition"))) | .[]'
```

---

## Python Wrapper for Databricks

Use this in a Databricks notebook for interactive investigation:

```python
import requests
import json
from dbruntime.databricks_repl_context import get_context

class SparkUIClient:
    def __init__(self):
        ctx = get_context()
        host = ctx.browserHostName
        cluster_id = ctx.clusterId
        token = ctx.apiToken
        self.base = f"https://{host}/driver-proxy-api/o/0/{cluster_id}/40001/api/v1"
        self.headers = {"Authorization": f"Bearer {token}"}
        apps = self._get("applications")
        self.app_id = apps[0]["id"]

    def _get(self, path, **params):
        url = f"{self.base}/{path}"
        r = requests.get(url, headers=self.headers, params=params)
        r.raise_for_status()
        return r.json()

    def jobs(self, status=None):
        params = {"status": status} if status else {}
        return self._get(f"applications/{self.app_id}/jobs", **params)

    def stages(self, status=None, with_summaries=False):
        params = {}
        if status: params["status"] = status
        if with_summaries:
            params["withSummaries"] = "true"
            params["quantiles"] = "0.25,0.5,0.75,0.99,1.0"
        return self._get(f"applications/{self.app_id}/stages", **params)

    def task_summary(self, stage_id, attempt=0):
        return self._get(
            f"applications/{self.app_id}/stages/{stage_id}/{attempt}/taskSummary",
            quantiles="0.01,0.25,0.5,0.75,0.99,1.0"
        )

    def task_list(self, stage_id, attempt=0, length=200, sort_by="-runtime"):
        return self._get(
            f"applications/{self.app_id}/stages/{stage_id}/{attempt}/taskList",
            length=length, sortBy=sort_by
        )

    def executors(self, include_dead=False):
        endpoint = "allexecutors" if include_dead else "executors"
        return self._get(f"applications/{self.app_id}/{endpoint}")

    def sql_queries(self, length=50):
        return self._get(f"applications/{self.app_id}/sql", details="false", length=length)

    def sql_plan(self, execution_id):
        return self._get(f"applications/{self.app_id}/sql/{execution_id}", details="true")

    def storage(self):
        return self._get(f"applications/{self.app_id}/storage/rdd")

    def environment(self):
        return self._get(f"applications/{self.app_id}/environment")

    def spill_report(self):
        stages = self.stages()
        return [s for s in stages if s.get("diskBytesSpilled", 0) > 0]

    def skew_report(self, stage_id, attempt=0):
        summary = self.task_summary(stage_id, attempt)
        q = summary.get("executorRunTime", {}).get("quantiles", [0]*6)
        median, p99, maximum = q[2], q[4], q[5]
        ratio = maximum / median if median > 0 else 0
        return {
            "stage_id": stage_id,
            "duration_median_ms": median,
            "duration_p99_ms": p99,
            "duration_max_ms": maximum,
            "skew_ratio_max_to_median": round(ratio, 1),
            "is_skewed": ratio > 5
        }

    def gc_pressure_report(self):
        executors = self.executors()
        result = []
        for e in executors:
            total = e.get("totalDuration", 0)
            gc = e.get("totalGCTime", 0)
            gc_pct = (gc / total * 100) if total > 0 else 0
            result.append({
                "id": e["id"],
                "host": e.get("hostPort"),
                "gc_pct": round(gc_pct, 1),
                "failed_tasks": e.get("failedTasks", 0),
                "is_problematic": gc_pct > 10
            })
        return sorted(result, key=lambda x: -x["gc_pct"])


# Usage:
ui = SparkUIClient()

# Spill report
print(json.dumps(ui.spill_report(), indent=2))

# Skew check for stage 5
print(json.dumps(ui.skew_report(5), indent=2))

# GC pressure
print(json.dumps(ui.gc_pressure_report(), indent=2))

# Slowest queries
queries = sorted(ui.sql_queries(100), key=lambda x: -(x.get("duration") or 0))
for q in queries[:5]:
    print(f"[{q['duration']}ms] {q['description'][:80]}")
```

---

## Standalone Spark (local port 4040)

```bash
# No auth needed for local spark-submit or pyspark shell
BASE="http://localhost:4040/api/v1"
APP_ID=$(curl -s "${BASE}/applications" | jq -r '.[0].id')

# Full pipeline: spill check → skew check on slowest stage → executor GC
curl -s "${BASE}/applications/${APP_ID}/stages" \
  | jq 'sort_by(-.diskBytesSpilled) | .[0:3] | .[] | {stageId, diskBytesSpilled, name}'
```

Multiple Spark UIs run simultaneously on ports 4040, 4041, 4042... when multiple apps run on the same machine.

---

## JSON Field Reference

### Stage object fields (relevant ones)

```json
{
  "stageId": 5,
  "attemptId": 0,
  "name": "collect at ...",
  "status": "COMPLETE",
  "numTasks": 200,
  "numActiveTasks": 0,
  "numCompleteTasks": 200,
  "numFailedTasks": 0,
  "submissionTime": 1704067200000,
  "completionTime": 1704067260000,
  "inputBytes": 1073741824,
  "inputRecords": 10000000,
  "outputBytes": 0,
  "outputRecords": 0,
  "shuffleReadBytes": 2147483648,
  "shuffleReadRecords": 20000000,
  "shuffleWriteBytes": 2147483648,
  "shuffleWriteRecords": 20000000,
  "memoryBytesSpilled": 0,
  "diskBytesSpilled": 0
}
```

### Task object fields (taskList)

```json
{
  "taskId": 42,
  "index": 42,
  "attempt": 0,
  "partitionId": 42,
  "launchTime": 1704067200000,
  "duration": 45000,
  "executorId": "2",
  "host": "10.0.0.5",
  "status": "SUCCESS",
  "taskLocality": "PROCESS_LOCAL",
  "speculative": false,
  "taskMetrics": {
    "executorDeserializeTime": 50,
    "executorDeserializeCpuTime": 40000000,
    "executorRunTime": 44500,
    "executorCpuTime": 40000000000,
    "resultSize": 1024,
    "jvmGcTime": 500,
    "resultSerializationTime": 10,
    "memoryBytesSpilled": 0,
    "diskBytesSpilled": 0,
    "peakExecutionMemory": 104857600,
    "inputMetrics": {
      "bytesRead": 134217728,
      "recordsRead": 1000000
    },
    "shuffleReadMetrics": {
      "remoteBlocksFetched": 10,
      "localBlocksFetched": 5,
      "fetchWaitTime": 100,
      "remoteBytesRead": 104857600,
      "localBytesRead": 52428800,
      "recordsRead": 1500000,
      "totalBytesRead": 157286400
    },
    "shuffleWriteMetrics": {
      "bytesWritten": 209715200,
      "writeTime": 5000000000,
      "recordsWritten": 2000000
    }
  }
}
```
