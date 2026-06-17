<!-- python-patterns: OOP Fundamentals -->

# OOP Fundamentals

## Why OOP Fundamentals Matter

This file covers the core mechanics of object-oriented programming before the advanced patterns in [07-oop-advanced-patterns.md](07-oop-advanced-patterns.md). The goal is not just to memorize syntax; it is to understand how Python objects model state, behavior, and reuse in real pipeline code.

**Mental model:** classes are blueprints, instances are concrete objects, and methods are behavior attached to those objects. In DE code, that usually means loaders, extractors, config objects, and pipeline steps.

## Classes and Instances

```python
class Pipeline:
    # Class variable — shared across ALL instances
    default_batch_size = 1000

    def __init__(self, name, source, target):
        # Instance variables — unique per instance
        self.name = name
        self.source = source
        self.target = target
        self._row_count = 0          # convention: _ = internal/protected
        self.__secret = "hidden"     # __ = name-mangled (harder to access from outside)

    def run(self):
        data = self._extract()
        data = self._transform(data)
        self._load(data)

    def _extract(self):
        raise NotImplementedError

    def __repr__(self):
        return f"Pipeline(name={self.name!r}, source={self.source!r})"

p = Pipeline("sales_etl", "s3://raw/", "snowflake://prod/")
repr(p)           # "Pipeline(name='sales_etl', source='s3://raw/')"
p._row_count      # accessible (just a convention)
p.__secret        # AttributeError — name-mangled to _Pipeline__secret
p._Pipeline__secret  # accessible if you really need it
```

---

## Dunder Methods (Magic Methods)

These make your class behave like a built-in type.

```python
class DataBatch:
    def __init__(self, records):
        self.records = list(records)

    # Representation
    def __repr__(self):
        return f"DataBatch({len(self.records)} records)"

    def __str__(self):
        return f"Batch with {len(self.records)} rows"

    # Container protocol
    def __len__(self):
        return len(self.records)

    def __getitem__(self, index):
        return self.records[index]

    def __iter__(self):
        return iter(self.records)

    def __contains__(self, item):
        return item in self.records

    # Comparison
    def __eq__(self, other):
        if not isinstance(other, DataBatch):
            return NotImplemented
        return self.records == other.records

    def __lt__(self, other):
        return len(self) < len(other)

    # Arithmetic
    def __add__(self, other):
        return DataBatch(self.records + other.records)

    def __bool__(self):
        return len(self.records) > 0   # empty batch is falsy

batch = DataBatch([{"id": 1}, {"id": 2}])
len(batch)          # 2
batch[0]            # {"id": 1}
for row in batch:   # iterates records
    ...
if batch:           # True (non-empty)
    ...
```

### Key Dunder Methods for DE

| Method | Trigger | Use case |
|---|---|---|
| `__init__` | `ClassName()` | Initialize instance |
| `__repr__` | `repr(obj)`, debugging | Unambiguous representation |
| `__str__` | `str(obj)`, `print()` | Human-readable output |
| `__len__` | `len(obj)` | Row count, batch size |
| `__iter__` | `for x in obj` | Iterable collections |
| `__getitem__` | `obj[key]` | Index/key access |
| `__contains__` | `x in obj` | Membership test |
| `__eq__` | `obj == other` | Value equality |
| `__bool__` | `if obj:` | Truthiness |
| `__enter__`/`__exit__` | `with obj:` | Context manager |
| `__call__` | `obj()` | Callable instances |

---

## Inheritance

```python
class BaseLoader:
    def __init__(self, target_table):
        self.target_table = target_table

    def validate(self, df):
        if df.empty:
            raise ValueError("Empty DataFrame — nothing to load")
        return True

    def load(self, df):
        raise NotImplementedError("Subclasses must implement load()")

class SnowflakeLoader(BaseLoader):
    def __init__(self, target_table, warehouse):
        super().__init__(target_table)   # call parent __init__
        self.warehouse = warehouse

    def load(self, df):
        self.validate(df)   # inherited method
        # snowflake-specific logic
        conn = get_snowflake_connection(self.warehouse)
        df.to_sql(self.target_table, conn, if_exists="append", index=False)
        return len(df)

class RedshiftLoader(BaseLoader):
    def load(self, df):
        self.validate(df)
        # redshift-specific logic
        ...
```

### `super()` — Always Use It

```python
class A:
    def setup(self):
        print("A setup")

class B(A):
    def setup(self):
        super().setup()   # calls A.setup()
        print("B setup")

class C(B):
    def setup(self):
        super().setup()   # calls B.setup() (which calls A.setup())
        print("C setup")

C().setup()
# A setup
# B setup
# C setup
```

---

## Method Resolution Order (MRO)

Python uses C3 linearization for multiple inheritance. `ClassName.__mro__` shows the lookup order.

```python
class A:
    def method(self): return "A"

class B(A):
    def method(self): return "B"

class C(A):
    def method(self): return "C"

class D(B, C):
    pass

D.__mro__
# (<class 'D'>, <class 'B'>, <class 'C'>, <class 'A'>, <class 'object'>)
D().method()  # "B" — leftmost parent wins
```

### Mixins — The Practical Multiple Inheritance Pattern

```python
class LogMixin:
    """Add structured logging to any class."""

    def log_info(self, msg):
        logging.info(f"[{self.__class__.__name__}] {msg}")

    def log_error(self, msg):
        logging.error(f"[{self.__class__.__name__}] {msg}")

class RetryMixin:
    """Add retry capability to any class method."""

    def with_retry(self, func, max_attempts=3):
        for attempt in range(max_attempts):
            try:
                return func()
            except Exception as e:
                if attempt == max_attempts - 1:
                    raise
                time.sleep(2 ** attempt)

class S3Extractor(LogMixin, RetryMixin, BaseExtractor):
    def extract(self):
        self.log_info(f"Extracting from {self.path}")
        return self.with_retry(lambda: self._do_extract())
```

---

## `@classmethod` vs `@staticmethod` vs Instance Method

```python
class Config:
    _instance = None

    def __init__(self, env, region):
        self.env = env
        self.region = region

    # Instance method — has access to self (instance)
    def is_production(self):
        return self.env == "prod"

    # classmethod — has access to cls (the class), not the instance
    # Common use: alternative constructors
    @classmethod
    def from_env(cls):
        return cls(
            env=os.environ.get("ENV", "dev"),
            region=os.environ.get("REGION", "us-east-1")
        )

    @classmethod
    def from_dict(cls, d):
        return cls(env=d["env"], region=d["region"])

    # Singleton pattern using classmethod
    @classmethod
    def get_instance(cls):
        if cls._instance is None:
            cls._instance = cls.from_env()
        return cls._instance

    # staticmethod — no access to self or cls
    # Use for utility functions that logically belong in the class
    @staticmethod
    def valid_regions():
        return {"us-east-1", "eu-west-1", "ap-southeast-1"}

    @staticmethod
    def validate_env(env):
        if env not in ("dev", "staging", "prod"):
            raise ValueError(f"Invalid env: {env}")

# Usage
config = Config.from_env()             # classmethod
config.is_production()                 # instance method
Config.valid_regions()                 # staticmethod
Config.from_dict({"env": "prod", "region": "us-east-1"})  # classmethod
```

---

## Properties

```python
class DataConnection:
    def __init__(self, host, port):
        self._host = host
        self._port = port
        self._conn = None

    @property
    def connection_string(self):
        """Computed attribute — no ()  needed when accessing."""
        return f"postgres://{self._host}:{self._port}"

    @property
    def is_connected(self):
        return self._conn is not None

    @property
    def port(self):
        return self._port

    @port.setter
    def port(self, value):
        if not isinstance(value, int) or not (1 <= value <= 65535):
            raise ValueError(f"Invalid port: {value}")
        self._port = value

    @port.deleter
    def port(self):
        self._port = 5432   # reset to default

conn = DataConnection("localhost", 5432)
conn.connection_string        # "postgres://localhost:5432" — no ()
conn.port = 5433              # calls setter with validation
del conn.port                 # calls deleter
```

---

## `__slots__` — Memory Optimization

```python
class Row:
    __slots__ = ("id", "name", "amount", "ts")   # no __dict__, fixed attributes

    def __init__(self, id, name, amount, ts):
        self.id = id
        self.name = name
        self.amount = amount
        self.ts = ts

# slots reduce per-instance memory by ~40-50% — significant for 1M+ rows
# tradeoff: cannot add arbitrary attributes, no __dict__, harder to pickle
```

---

## Interview Questions

**Q: What's the difference between `__str__` and `__repr__`?**
`__repr__` is for developers — should be unambiguous and ideally `eval`-able to recreate the object. `__str__` is for end users — human-readable. `print()` and f-strings use `__str__`; the REPL and `repr()` use `__repr__`.

**Q: What is MRO and how does Python resolve it?**
Method Resolution Order — the order Python searches base classes for a method. Uses C3 linearization (left to right, depth-first, with constraint that parents appear before children). View with `ClassName.__mro__`.

**Q: When do you use `@classmethod` vs `@staticmethod`?**
`@classmethod` when you need the class itself (alternative constructors, factory methods, singletons). `@staticmethod` when the function logically belongs in the class but doesn't need `self` or `cls` — essentially a namespaced utility function.

**Q: What does `super()` do in multiple inheritance?**
Calls the next class in the MRO, not necessarily the direct parent. This allows cooperative multiple inheritance — each class calls `super()` and the chain propagates correctly through the MRO.

**Q: What are `__slots__` and when would you use them?**
Replace the per-instance `__dict__` with a fixed set of slots. Reduces memory by 40-50% and speeds up attribute access. Use when creating millions of small instances (e.g., one object per CSV row). Tradeoff: can't add arbitrary attributes.
