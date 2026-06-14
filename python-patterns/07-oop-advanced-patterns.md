<!-- python-patterns: OOP Advanced Patterns -->

# OOP Advanced Patterns

## Abstract Base Classes (ABC)

### How It Works

ABC enforces that subclasses implement required methods — at **instantiation time**, not at call time. Any attempt to instantiate a class with unimplemented abstract methods raises `TypeError` immediately.

```python
from abc import ABC, abstractmethod
import pandas as pd

class ETLStep(ABC):
    """Abstract base for a pipeline step. All three methods required."""

    @abstractmethod
    def extract(self) -> pd.DataFrame:
        """Pull raw data. Return a DataFrame."""
        ...

    @abstractmethod
    def transform(self, df: pd.DataFrame) -> pd.DataFrame:
        """Apply business logic."""
        ...

    @abstractmethod
    def load(self, df: pd.DataFrame) -> int:
        """Write to destination. Return row count written."""
        ...

    # Concrete method — shared logic all subclasses inherit
    def run(self) -> int:
        df = self.extract()
        df = self.transform(df)
        return self.load(df)

class SalesETL(ETLStep):
    def extract(self) -> pd.DataFrame:
        return pd.read_parquet("s3://bucket/sales/")

    def transform(self, df: pd.DataFrame) -> pd.DataFrame:
        df["total"] = df["qty"] * df["unit_price"]
        return df[df["total"] > 0]

    def load(self, df: pd.DataFrame) -> int:
        df.to_parquet("s3://bucket/output/", index=False)
        return len(df)

# ETLStep()       # TypeError: Can't instantiate abstract class
# SalesETL()      # works — all abstract methods implemented

# ABC vs manual NotImplementedError:
# ABC: TypeError at instantiation — caught immediately
# NotImplementedError: raised only when the method is called — caught late
```

### Abstract Properties

```python
from abc import ABC, abstractmethod

class BaseConnector(ABC):

    @property
    @abstractmethod
    def connection_string(self) -> str:
        """Subclasses must implement this property."""
        ...

    @classmethod
    @abstractmethod
    def from_config(cls, config: dict) -> "BaseConnector":
        """Alternative constructor — must be implemented."""
        ...

class SnowflakeConnector(BaseConnector):

    def __init__(self, account, user, password, database):
        self._account = account
        self._user = user
        self._password = password
        self._database = database

    @property
    def connection_string(self) -> str:
        return f"snowflake://{self._user}@{self._account}/{self._database}"

    @classmethod
    def from_config(cls, config: dict) -> "SnowflakeConnector":
        return cls(
            account=config["account"],
            user=config["user"],
            password=config["password"],
            database=config["database"],
        )
```

---

## Protocol (Structural Subtyping)

Protocol defines an interface without requiring explicit inheritance — "duck typing with type checking".

```python
from typing import Protocol, runtime_checkable
import pandas as pd

@runtime_checkable
class Loadable(Protocol):
    def load(self, df: pd.DataFrame) -> int: ...

# Any class with a compatible load() method satisfies the Protocol
# No explicit inheritance from Loadable required

class SnowflakeLoader:
    def load(self, df: pd.DataFrame) -> int:
        # snowflake load logic
        return len(df)

class BigQueryLoader:
    def load(self, df: pd.DataFrame) -> int:
        # bigquery load logic
        return len(df)

def run_load(loader: Loadable, df: pd.DataFrame):
    return loader.load(df)

run_load(SnowflakeLoader(), df)   # works — SnowflakeLoader structurally matches
run_load(BigQueryLoader(), df)    # works — BigQueryLoader structurally matches

# runtime_checkable enables isinstance() checks
isinstance(SnowflakeLoader(), Loadable)  # True
```

**ABC vs Protocol:**
- `ABC`: explicit inheritance required, enforces at instantiation, good for internal hierarchies
- `Protocol`: structural, no inheritance required, good for external/pluggable components

---

## Dataclasses

```python
from dataclasses import dataclass, field
from typing import Optional

@dataclass
class PipelineConfig:
    source_bucket: str
    target_schema: str
    batch_size: int = 10_000
    dry_run: bool = False
    tags: list[str] = field(default_factory=list)  # mutable default — NEVER use []
    _run_id: str = field(default=None, init=False, repr=False)  # not in __init__

    def __post_init__(self):
        """Validation and derived fields after __init__."""
        if self.batch_size <= 0:
            raise ValueError("batch_size must be positive")
        import uuid
        self._run_id = str(uuid.uuid4())

    @classmethod
    def from_env(cls) -> "PipelineConfig":
        import os
        return cls(
            source_bucket=os.environ["SOURCE_BUCKET"],
            target_schema=os.environ.get("TARGET_SCHEMA", "public"),
            batch_size=int(os.environ.get("BATCH_SIZE", 10_000)),
        )

# Auto-generated: __init__, __repr__, __eq__
config = PipelineConfig(source_bucket="my-bucket", target_schema="prod")
config  # PipelineConfig(source_bucket='my-bucket', target_schema='prod', batch_size=10000, ...)
```

### Frozen Dataclasses

```python
@dataclass(frozen=True)   # immutable — raises FrozenInstanceError on mutation
class TableKey:
    schema: str
    table: str

    def __str__(self):
        return f"{self.schema}.{self.table}"

# Can be used as dict key or set member (hashable)
table_cache = {}
key = TableKey("public", "orders")
table_cache[key] = fetch_schema(key)

# Ordering
@dataclass(order=True)   # generates __lt__, __le__, __gt__, __ge__
class SortableRecord:
    priority: int
    name: str
```

### Dataclass vs namedtuple

| | `dataclass` | `namedtuple` |
|---|---|---|
| Mutable | Yes (unless frozen) | No |
| Default values | Yes | Yes (Python 3.6.1+) |
| Methods | Yes | Limited |
| Memory | Higher (has `__dict__`) | Lower (tuple) |
| Isinstance | Class | Also a tuple |
| Type hints | Yes | Yes (typing.NamedTuple) |
| Use when | Config, stateful objects | Lightweight records, return values |

```python
from typing import NamedTuple

class TableStats(NamedTuple):
    table: str
    row_count: int
    size_mb: float

stats = TableStats("orders", 1_000_000, 2048.5)
stats.row_count    # 1000000
stats[1]           # 1000000 — tuple indexing works too
```

---

## Full ETL Pipeline Class Pattern

```python
from abc import ABC, abstractmethod
from dataclasses import dataclass
from contextlib import contextmanager
import logging

@dataclass
class StepResult:
    step: str
    rows_in: int
    rows_out: int
    success: bool
    error: Optional[str] = None

class PipelineStep(ABC):
    """Template method pattern — run() orchestrates, subclasses fill in logic."""

    def __init__(self, config: PipelineConfig):
        self.config = config
        self.logger = logging.getLogger(self.__class__.__name__)

    @abstractmethod
    def extract(self) -> pd.DataFrame:
        ...

    @abstractmethod
    def transform(self, df: pd.DataFrame) -> pd.DataFrame:
        ...

    @abstractmethod
    def load(self, df: pd.DataFrame) -> int:
        ...

    def run(self) -> StepResult:
        step_name = self.__class__.__name__
        self.logger.info(f"Starting {step_name}")
        try:
            raw = self.extract()
            self.logger.info(f"Extracted {len(raw)} rows")

            cleaned = self.transform(raw)
            self.logger.info(f"Transformed: {len(raw)} → {len(cleaned)} rows")

            if not self.config.dry_run:
                written = self.load(cleaned)
            else:
                written = 0
                self.logger.info("Dry run — skipping load")

            return StepResult(step_name, len(raw), written, success=True)

        except Exception as e:
            self.logger.error(f"{step_name} failed: {e}", exc_info=True)
            return StepResult(step_name, 0, 0, success=False, error=str(e))


class SalesETL(PipelineStep):
    def extract(self) -> pd.DataFrame:
        return pd.read_parquet(f"s3://{self.config.source_bucket}/sales/")

    def transform(self, df: pd.DataFrame) -> pd.DataFrame:
        df = df.copy()
        df["total"] = df["qty"] * df["unit_price"]
        return df[df["total"] > 0].reset_index(drop=True)

    def load(self, df: pd.DataFrame) -> int:
        df.to_parquet(f"s3://output/{self.config.target_schema}/sales/", index=False)
        return len(df)
```

---

## Singleton Pattern

```python
class Config:
    _instance: Optional["Config"] = None

    def __new__(cls, *args, **kwargs):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __init__(self, env="dev"):
        if hasattr(self, "_initialized"):
            return
        self.env = env
        self._initialized = True

# Thread-safe singleton using a lock
import threading

class ThreadSafeConfig:
    _instance = None
    _lock = threading.Lock()

    @classmethod
    def get_instance(cls) -> "ThreadSafeConfig":
        if cls._instance is None:
            with cls._lock:
                if cls._instance is None:  # double-checked locking
                    cls._instance = cls()
        return cls._instance
```

---

## Interview Questions

**Q: Why use ABC instead of just raising `NotImplementedError` in the base class?**
ABC raises `TypeError` when you try to **instantiate** a class with missing abstract methods. `NotImplementedError` only fires when the method is **called**. ABC catches the missing implementation at class definition time, not buried in a runtime call path.

**Q: What is a dataclass and what does it auto-generate?**
A class decorated with `@dataclass` auto-generates `__init__`, `__repr__`, and `__eq__` from type-annotated class attributes. With `order=True` adds comparison methods; with `frozen=True` makes the instance immutable and hashable.

**Q: What's the difference between `field(default_factory=list)` and `default=[]`?**
`default=[]` shares the same list object across all instances (mutable default argument bug). `field(default_factory=list)` calls `list()` for each new instance, so each instance gets its own list.

**Q: What is a Protocol vs an ABC?**
ABC requires explicit inheritance. Protocol uses structural typing — any class with the required methods satisfies the protocol without inheriting from it. Protocol is more flexible for external/pluggable code; ABC is better for internal class hierarchies where you control all subclasses.

**Q: How does the template method pattern apply to ETL pipelines?**
Define the algorithm skeleton (`run()` calling `extract()`, `transform()`, `load()`) in the base class, with abstract methods that subclasses fill in. The base class controls flow, logging, and error handling; subclasses provide only the data-source-specific logic.
