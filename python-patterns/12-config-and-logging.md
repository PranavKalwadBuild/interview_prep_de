<!-- python-patterns: Config and Logging -->

# Config and Logging

## Understanding Configuration and Logging in Data Engineering

Configuration tells a pipeline what to do; logging tells you what it did. Both need to be structured, explicit, and easy to override per environment.

**Mental model:**
- Config should be loaded once at startup and validated immediately
- Secrets should come from the environment or a secret store, not hardcoded
- Logs should answer three questions: what ran, what happened, and what failed

This matters because many pipeline bugs are not logic bugs; they are observability bugs. If a run fails without enough context, you end up debugging blind.

Good defaults:
- Static, non-secret settings in YAML or dataclasses
- Secrets in environment variables or a secret manager
- Structured logs in JSON for cloud observability tools
- Logger names per module or task for traceability

## Config Patterns

### Environment Variables — The Baseline

```python
import os

# Direct access — raises KeyError if missing
bucket = os.environ["SOURCE_BUCKET"]

# With default
schema = os.environ.get("TARGET_SCHEMA", "public")
batch_size = int(os.environ.get("BATCH_SIZE", "10000"))
dry_run = os.environ.get("DRY_RUN", "false").lower() == "true"

# Required vars — validate at startup, not deep in the code
REQUIRED_VARS = ["SOURCE_BUCKET", "TARGET_SCHEMA", "DB_PASSWORD"]

def validate_env():
    missing = [v for v in REQUIRED_VARS if v not in os.environ]
    if missing:
        raise EnvironmentError(f"Missing required env vars: {', '.join(missing)}")

validate_env()   # fail fast at startup, not 2 hours into a run
```

### Dataclass Config — Clean and Typed

```python
from dataclasses import dataclass, field
from typing import Optional
import os

@dataclass
class PipelineConfig:
    source_bucket: str
    target_schema: str
    batch_size: int = 10_000
    dry_run: bool = False
    tags: list[str] = field(default_factory=list)

    def __post_init__(self):
        if self.batch_size <= 0:
            raise ValueError(f"batch_size must be positive, got {self.batch_size}")
        if self.batch_size > 500_000:
            raise ValueError(f"batch_size {self.batch_size} exceeds max 500,000")

    @classmethod
    def from_env(cls) -> "PipelineConfig":
        return cls(
            source_bucket=os.environ["SOURCE_BUCKET"],
            target_schema=os.environ.get("TARGET_SCHEMA", "public"),
            batch_size=int(os.environ.get("BATCH_SIZE", 10_000)),
            dry_run=os.environ.get("DRY_RUN", "false").lower() == "true",
            tags=os.environ.get("TAGS", "").split(",") if os.environ.get("TAGS") else [],
        )

    @classmethod
    def from_dict(cls, d: dict) -> "PipelineConfig":
        return cls(**{k: v for k, v in d.items() if k in cls.__dataclass_fields__})
```

### Pydantic Config — Validation-First

```python
from pydantic import BaseModel, Field, field_validator, model_validator
from typing import Optional
import os

class DBConfig(BaseModel):
    host: str
    port: int = Field(default=5432, ge=1, le=65535)
    database: str
    user: str
    password: str

    @property
    def dsn(self) -> str:
        return f"postgresql://{self.user}:{self.password}@{self.host}:{self.port}/{self.database}"

class PipelineConfig(BaseModel):
    source_bucket: str
    target_schema: str = "public"
    batch_size: int = Field(default=10_000, gt=0, le=500_000)
    dry_run: bool = False
    db: DBConfig

    @field_validator("source_bucket")
    @classmethod
    def bucket_not_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("source_bucket cannot be empty")
        return v.strip()

    @model_validator(mode="after")
    def validate_cross_fields(self) -> "PipelineConfig":
        if self.dry_run and self.batch_size > 100_000:
            raise ValueError("dry_run with batch_size > 100k is suspicious")
        return self

    @classmethod
    def from_env(cls) -> "PipelineConfig":
        return cls(
            source_bucket=os.environ["SOURCE_BUCKET"],
            target_schema=os.environ.get("TARGET_SCHEMA", "public"),
            batch_size=int(os.environ.get("BATCH_SIZE", 10_000)),
            dry_run=os.environ.get("DRY_RUN", "false").lower() == "true",
            db=DBConfig(
                host=os.environ["DB_HOST"],
                port=int(os.environ.get("DB_PORT", 5432)),
                database=os.environ["DB_NAME"],
                user=os.environ["DB_USER"],
                password=os.environ["DB_PASSWORD"],
            ),
        )
```

### YAML Config File + Env Override Pattern

```python
import yaml, os
from pathlib import Path

def load_config(config_path="config.yml") -> dict:
    """Load YAML config, override specific keys with env vars."""
    with open(config_path) as f:
        config = yaml.safe_load(f)

    # Env overrides — useful for secrets that shouldn't live in YAML
    env_overrides = {
        "db_password": os.environ.get("DB_PASSWORD"),
        "api_key": os.environ.get("API_KEY"),
    }
    for key, val in env_overrides.items():
        if val is not None:
            config[key] = val

    return config

# Layered config: defaults → file → env (each layer overrides the previous)
from collections import ChainMap

def layered_config():
    defaults = {"batch_size": 10_000, "timeout": 30, "retries": 3}
    file_config = yaml.safe_load(open("config.yml"))
    env_config = {k.lower(): v for k, v in os.environ.items() if k.startswith("PIPELINE_")}
    return ChainMap(env_config, file_config, defaults)
```

---

## Logging Patterns

### Basic Logger Setup

```python
import logging, sys

def get_logger(name: str, level=logging.INFO) -> logging.Logger:
    logger = logging.getLogger(name)
    if logger.handlers:        # prevent duplicate handlers — critical in Airflow
        return logger
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter(
        fmt="%(asctime)s | %(name)s | %(levelname)s | %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    ))
    logger.addHandler(handler)
    logger.setLevel(level)
    logger.propagate = False   # don't propagate to root logger — avoid duplicates
    return logger

# Use at module level
logger = get_logger(__name__)

# Usage
logger.debug("detailed debug info")
logger.info("Row count: %d", row_count)          # use % formatting — not f-strings
logger.warning("Missing %d rows", missing)       # lazy evaluation — no format cost if filtered
logger.error("Load failed: %s", err)
logger.exception("Unexpected error", exc_info=True)  # includes full traceback
logger.critical("Pipeline dead")
```

**Why `%` formatting not f-strings in logging:**
`logger.info(f"Value: {expensive_computation()}")` computes the string even if INFO is filtered. `logger.info("Value: %s", val)` skips formatting entirely when the log level is filtered.

### Structured / JSON Logging (Cloud-Ready)

```python
import logging, json
from datetime import datetime, timezone

class JSONFormatter(logging.Formatter):
    """Emit log records as single-line JSON — parseable by CloudWatch, Datadog, ELK."""

    def format(self, record: logging.LogRecord) -> str:
        log_record = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "module": record.module,
            "line": record.lineno,
        }
        # Include exception info if present
        if record.exc_info:
            log_record["exception"] = self.formatException(record.exc_info)
        # Include any extra fields passed via `extra=`
        for key in ("pipeline", "run_id", "table", "batch"):
            if hasattr(record, key):
                log_record[key] = getattr(record, key)
        return json.dumps(log_record)

def get_json_logger(name: str) -> logging.Logger:
    logger = logging.getLogger(name)
    if logger.handlers:
        return logger
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JSONFormatter())
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    return logger

logger = get_json_logger("my.pipeline")
logger.info("Loaded rows", extra={"pipeline": "sales_etl", "table": "orders", "batch": 42})
# Output: {"ts":"...","level":"INFO","logger":"my.pipeline","message":"Loaded rows","pipeline":"sales_etl","table":"orders","batch":42}
```

### Logging Context — LoggerAdapter

```python
import logging

class PipelineLogger(logging.LoggerAdapter):
    """Injects run_id and pipeline into every log message."""

    def process(self, msg, kwargs):
        kwargs.setdefault("extra", {}).update(self.extra)
        return msg, kwargs

base_logger = logging.getLogger("pipeline")
logger = PipelineLogger(base_logger, extra={"run_id": run_id, "pipeline": "sales_etl"})

logger.info("Starting extraction")  # includes run_id and pipeline automatically
```

### Logging to Multiple Destinations

```python
import logging

def configure_logging(log_file=None, level=logging.INFO):
    logger = logging.getLogger()   # root logger
    logger.setLevel(level)

    fmt = logging.Formatter("%(asctime)s | %(levelname)s | %(name)s | %(message)s")

    # Console
    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(fmt)
    logger.addHandler(console)

    # File (optional)
    if log_file:
        from logging.handlers import RotatingFileHandler
        file_handler = RotatingFileHandler(
            log_file, maxBytes=50 * 1024 * 1024, backupCount=5   # 50MB per file, keep 5
        )
        file_handler.setFormatter(fmt)
        logger.addHandler(file_handler)
```

---

## Airflow-Specific Logging

```python
# Airflow creates its own logging config — don't configure root logger in Airflow tasks
# Use per-module loggers with if logger.handlers guard

def run_task(**context):
    logger = logging.getLogger(__name__)
    # logger.handlers may already be set by Airflow — adding again causes duplicates
    logger.info("Task started")
    ...

# Access Airflow task context for correlation
def run_task(**context):
    run_id = context["run_id"]
    task_id = context["task_instance"].task_id
    logger = logging.getLogger(f"pipeline.{task_id}")
    logger.info(f"run_id={run_id}")
```

---

## Interview Questions

**Q: Why use `%s` formatting in logging instead of f-strings?**
Logging uses lazy evaluation — `logger.info("Val: %s", val)` skips string formatting if the INFO level is filtered out. `f"Val: {val}"` always evaluates the f-string, even if the log is never emitted. For expensive computations this is a real performance difference, and it can be the difference between a cheap debug log and unnecessary overhead in a hot loop.

**Q: Why check `if logger.handlers` before adding a handler?**
In Airflow or any multi-process/multi-import context, the module may be imported multiple times. Each import without the guard adds another handler, causing each log message to appear N times. That makes logs noisy and hard to trust.

**Q: What's the difference between `logger.error(msg, exc_info=True)` and `logger.exception(msg)`?**
`logger.exception(msg)` is equivalent to `logger.error(msg, exc_info=True)` — both include the current exception traceback. `exception` is shorthand and is usually the clearer choice inside `except` blocks.

**Q: How do you handle config in a production pipeline — env vars, YAML, or both?**
Both: YAML for static config (table lists, schema mappings, batch sizes), env vars for environment-specific and secret values (passwords, bucket names, API keys). Secrets should not live in version-controlled YAML. Load YAML at startup, override with env vars, validate once, and fail fast if required values are missing.

**Q: Why prefer structured JSON logs in cloud environments?**
Because systems like CloudWatch, Datadog, and ELK can index fields from JSON logs directly. Plain text is fine for local debugging, but JSON logs make filtering, aggregation, and alerting much more reliable at scale.

**Q: What is the risk of reading config deep inside the code instead of at startup?**
Late config reads make failures appear far from their root cause. If a required env var is missing, it is better to fail at startup than two hours into a run. Startup validation gives faster feedback and reduces wasted compute.

**Q: When would you use a `LoggerAdapter`?**
Use it when you want to inject shared contextual fields like `run_id`, `pipeline`, or `table` into every log record without repeating them in every log call. It is a clean way to keep logs correlated across a pipeline run.
