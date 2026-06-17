<!-- python-patterns: OOP Advanced Patterns -->

# OOP Fundamentals & Advanced Patterns for Data Engineering

---

## Part 1: OOP Fundamentals

### Understanding Classes and Objects

A **class** is a blueprint for creating objects. It defines the structure (attributes) and behavior (methods) that instances of the class will have. An **object** (or instance) is a concrete realization of that blueprint with its own state.

Think of a class like an architectural blueprint for a building. The blueprint defines:
- What rooms the building will have (attributes)
- What activities happen in those rooms (methods)

Each actual building built from that blueprint is an object — they all follow the same blueprint but have independent state (different furniture, occupants, etc.).

```python
# Class definition — the blueprint
class DataPipeline:
    """A blueprint for data pipelines."""
    pass

# Creating objects (instances) from the class
pipeline1 = DataPipeline()  # First object
pipeline2 = DataPipeline()  # Second object — independent from pipeline1

# Each instance has its own identity
print(id(pipeline1))  # Memory address of object 1
print(id(pipeline2))  # Different memory address — different objects
print(pipeline1 is pipeline2)  # False — different objects
print(pipeline1 == pipeline2)  # False unless __eq__ is defined
```

### Instance Attributes: The State of Objects

Instance attributes store data specific to each object. They are defined in the `__init__` method (the constructor), which Python calls automatically when you create an instance.

```python
class DataPipeline:
    """Data pipeline with specific configuration per instance."""

    def __init__(self, source_db: str, target_bucket: str, batch_size: int):
        # These are instance attributes — each instance has its own copy
        self.source_db = source_db
        self.target_bucket = target_bucket
        self.batch_size = batch_size
        self.rows_processed = 0

    def describe(self) -> str:
        # Methods can access instance attributes via self
        return f"Pipeline: {self.source_db} → {self.target_bucket} (batch: {self.batch_size})"

# Create two independent instances
pipeline1 = DataPipeline("db1.users", "bucket-a", 5000)
pipeline2 = DataPipeline("db2.orders", "bucket-b", 10000)

# Each instance has independent state
print(pipeline1.source_db)      # "db1.users"
print(pipeline2.source_db)      # "db2.orders" — different value
print(pipeline1.batch_size)     # 5000
print(pipeline2.batch_size)     # 10000 — different value

# Modify one instance's state — doesn't affect the other
pipeline1.rows_processed = 100
pipeline2.rows_processed = 500
print(pipeline1.rows_processed)  # 100
print(pipeline2.rows_processed)  # 500

# Both call the same method, but work with their own data
print(pipeline1.describe())  # "Pipeline: db1.users → bucket-a (batch: 5000)"
print(pipeline2.describe())  # "Pipeline: db2.orders → bucket-b (batch: 10000)"
```

### Instance Methods: Behavior

Instance methods operate on the instance's state. They always take `self` as the first parameter, which refers to the specific instance calling the method.

```python
class DataPipeline:
    def __init__(self, source: str, target: str):
        self.source = source
        self.target = target
        self.rows_processed = 0
        self.status = "idle"

    def run(self) -> None:
        """Instance method — operates on instance's state."""
        self.status = "running"
        print(f"Running: {self.source} → {self.target}")
        self.rows_processed += 1000
        self.status = "completed"

    def get_status(self) -> dict:
        """Return current state of this specific instance."""
        return {
            "source": self.source,
            "target": self.target,
            "rows": self.rows_processed,
            "status": self.status,
        }

# Two pipelines, each maintaining independent state
pipeline1 = DataPipeline("table1", "s3://bucket1")
pipeline2 = DataPipeline("table2", "s3://bucket2")

# Call methods on each instance
pipeline1.run()
print(pipeline1.get_status())
# {'source': 'table1', 'target': 's3://bucket1', 'rows': 1000, 'status': 'completed'}

# pipeline2 hasn't run yet — still has original state
print(pipeline2.get_status())
# {'source': 'table2', 'target': 's3://bucket2', 'rows': 0, 'status': 'idle'}

pipeline2.run()
print(pipeline2.get_status())
# {'source': 'table2', 'target': 's3://bucket2', 'rows': 1000, 'status': 'completed'}
```

### Class Variables: Shared State Across Instances

Class variables are defined at the class level, outside any method. All instances of the class share the same class variable. This is useful for data that should be common to all instances.

```python
class DataPipeline:
    # Class variable — shared by all instances
    total_pipelines_created = 0
    SUPPORTED_FORMATS = ["parquet", "csv", "delta", "json"]

    def __init__(self, name: str):
        self.name = name  # Instance variable
        # Increment shared counter
        DataPipeline.total_pipelines_created += 1

    def describe(self) -> str:
        # Can access both class and instance variables
        formats = ", ".join(self.SUPPORTED_FORMATS)
        return f"{self.name} — supports: {formats}"

# Create instances
p1 = DataPipeline("pipeline_1")
p2 = DataPipeline("pipeline_2")
p3 = DataPipeline("pipeline_3")

# Class variable is shared
print(DataPipeline.total_pipelines_created)  # 3 — incremented for each instance
print(p1.total_pipelines_created)             # 3 — accessible via instance too
print(p2.total_pipelines_created)             # 3 — same value for all instances

# Instance variables are independent
print(p1.name)  # "pipeline_1"
print(p2.name)  # "pipeline_2"

# Be careful: modifying class variable affects all instances
DataPipeline.SUPPORTED_FORMATS.append("xlsx")
print(p1.SUPPORTED_FORMATS)  # Includes "xlsx" now
print(p2.SUPPORTED_FORMATS)  # Includes "xlsx" too — shared!
```

### The Three Types of Methods: Instance, Class, and Static

Python supports three types of methods, each with a specific purpose:

#### Instance Methods

Instance methods work with instance-specific data. They take `self` as the first parameter.

```python
class DataConnector:
    def __init__(self, connection_string: str):
        self.connection_string = connection_string
        self.is_connected = False

    def connect(self) -> None:
        """Instance method — operates on this instance's state."""
        self.is_connected = True
        print(f"Connected to: {self.connection_string}")

    def get_connection_info(self) -> dict:
        """Instance method — returns this instance's state."""
        return {
            "connection": self.connection_string,
            "connected": self.is_connected,
        }

connector = DataConnector("postgresql://localhost:5432/mydb")
connector.connect()
print(connector.get_connection_info())
```

#### Class Methods

Class methods work with class-level data. They take `cls` (the class itself) as the first parameter and are defined with `@classmethod`. Use them for alternative constructors or accessing/modifying class variables.

```python
class DataConnector:
    # Class variable tracking all connections
    active_connections = {}

    def __init__(self, db_type: str, connection_string: str):
        self.db_type = db_type
        self.connection_string = connection_string
        # Register this connection
        DataConnector.active_connections[connection_string] = db_type

    @classmethod
    def from_config_file(cls, filepath: str) -> "DataConnector":
        """
        Class method — alternative constructor.
        Takes cls (the class) instead of self (an instance).
        Useful for creating instances from different data sources.
        """
        import json
        with open(filepath, "r") as f:
            config = json.load(f)
        return cls(config["db_type"], config["connection_string"])

    @classmethod
    def from_env(cls, env_var: str) -> "DataConnector":
        """Another alternative constructor — from environment variable."""
        import os
        connection_string = os.environ[env_var]
        return cls("postgres", connection_string)

    @classmethod
    def list_all_connections(cls) -> list[str]:
        """Class method — access class variables."""
        return list(cls.active_connections.keys())

    @classmethod
    def connection_count(cls) -> int:
        """Class method — query class-level data."""
        return len(cls.active_connections)

# Create instances using different class methods
conn1 = DataConnector("postgres", "postgresql://localhost/db1")
conn2 = DataConnector.from_config_file("db_config.json")
conn3 = DataConnector.from_env("DATABASE_URL")

# Call class method to query all instances
print(DataConnector.connection_count())  # 3
print(DataConnector.list_all_connections())  # All connection strings
```

#### Static Methods

Static methods don't access instance or class data. They're just functions grouped into a class for organizational purposes. They take no special first parameter and are defined with `@staticmethod`.

```python
class DataUtils:
    """Utility functions organized as a class (no instance data needed)."""

    @staticmethod
    def validate_email(email: str) -> bool:
        """Static method — pure function, no self or cls needed."""
        return "@" in email and "." in email

    @staticmethod
    def parse_config(config_string: str) -> dict:
        """Static method — utility transformation."""
        pairs = config_string.split(",")
        return {pair.split("=")[0]: pair.split("=")[1] for pair in pairs}

    @staticmethod
    def get_batch_size(total_rows: int, max_batch: int = 10000) -> int:
        """Static method — computation with no state."""
        return min(total_rows, max_batch)

# Call static methods directly on the class (no instance needed)
is_valid = DataUtils.validate_email("user@example.com")  # True
config = DataUtils.parse_config("host=localhost,port=5432")  # {"host": "localhost", "port": "5432"}
batch = DataUtils.get_batch_size(50000)  # 10000

# Can call on instances too, but pointless
utils = DataUtils()
utils.validate_email("test@test.com")  # Works, but why?

# Summary: use static methods for pure utilities that belong to a class conceptually
```

### Method Resolution Order (MRO) and Inheritance

When you inherit from a class, Python searches for methods in a specific order using the **Method Resolution Order (MRO)**. This determines which class's version of a method gets called.

```python
class DataSource:
    """Base class for all data sources."""
    def __init__(self, name: str):
        self.name = name
        print(f"DataSource.__init__: {name}")

    def extract(self) -> None:
        print(f"DataSource.extract: generic extraction for {self.name}")

class DatabaseSource(DataSource):
    """Inherits from DataSource."""
    def __init__(self, name: str, db_url: str):
        super().__init__(name)  # Call parent __init__
        self.db_url = db_url
        print(f"DatabaseSource.__init__: {name} at {db_url}")

    def extract(self) -> None:
        # Override parent method
        print(f"DatabaseSource.extract: querying {self.db_url}")

class APISource(DataSource):
    """Another subclass of DataSource."""
    def __init__(self, name: str, api_key: str):
        super().__init__(name)
        self.api_key = api_key
        print(f"APISource.__init__: {name} with API key")

    def extract(self) -> None:
        print(f"APISource.extract: calling API with key {self.api_key}")

# Check the Method Resolution Order
print(DatabaseSource.__mro__)
# (<class 'DatabaseSource'>, <class 'DataSource'>, <class 'object'>)
# Order: DatabaseSource first, then DataSource, then object (built-in base)

# When you call a method, Python searches in this order
db_source = DatabaseSource("users_db", "postgresql://localhost/mydb")
db_source.extract()  # Uses DatabaseSource.extract (found first in MRO)

api_source = APISource("external_api", "sk-12345")
api_source.extract()  # Uses APISource.extract

# If a method isn't found in a class, Python looks in parent classes
print(db_source.name)  # Works — defined in DataSource.__init__ via super()
```

### Understanding `super()` and Method Chaining

`super()` calls the parent class's method, allowing you to extend functionality without duplicating code.

```python
class ETLPipeline:
    def __init__(self, name: str, batch_size: int = 1000):
        self.name = name
        self.batch_size = batch_size
        self.logs = []
        self.log(f"Pipeline initialized with batch size {batch_size}")

    def log(self, message: str) -> None:
        self.logs.append(message)
        print(f"[{self.name}] {message}")

    def run(self) -> None:
        self.log("Pipeline starting")

class SalesETLPipeline(ETLPipeline):
    def __init__(self, name: str, batch_size: int, sales_region: str):
        # super().__init__() calls parent's __init__
        super().__init__(name, batch_size)
        self.sales_region = sales_region
        self.log(f"Sales region set to {sales_region}")

    def run(self) -> None:
        # Call parent's run() method first
        super().run()
        # Then add subclass-specific logic
        self.log(f"Extracting sales data from region {self.sales_region}")
        self.log("Transform: calculating totals")
        self.log("Load: writing to warehouse")

pipeline = SalesETLPipeline("daily_sales", batch_size=5000, sales_region="APAC")
pipeline.run()
# Output shows all logs from parent and child
# [daily_sales] Pipeline initialized with batch size 5000
# [daily_sales] Sales region set to APAC
# [daily_sales] Pipeline starting
# [daily_sales] Extracting sales data from region APAC
# [daily_sales] Transform: calculating totals
# [daily_sales] Load: writing to warehouse
```

### Encapsulation: Managing Access to Attributes

Encapsulation means bundling data (attributes) and methods together, and controlling how external code accesses them. Python uses naming conventions since it doesn't have strict access modifiers like Java.

```python
class DatabaseConnection:
    def __init__(self, host: str, port: int, password: str):
        # Public attributes — can be accessed and modified freely
        self.host = host
        self.port = port

        # Private attributes — by convention, start with underscore
        # "Please don't access this directly; use the provided methods"
        self._password = password
        self._connection = None
        self._is_connected = False

    def connect(self) -> None:
        """Public method — part of intended interface."""
        self._establish_connection()  # Call private method
        self._is_connected = True

    def _establish_connection(self) -> None:
        """Private method — internal implementation detail."""
        # Complex connection logic
        print(f"Connecting to {self.host}:{self.port} with password {self._password}")
        self._connection = f"conn_to_{self.host}"

    def get_status(self) -> dict:
        """Public method — safe way to query internal state."""
        return {
            "host": self.host,
            "connected": self._is_connected,
            # Note: don't expose self._password in public method
        }

    def query(self, sql: str) -> None:
        """Public method — users call this, not internal _execute()."""
        if not self._is_connected:
            raise RuntimeError("Not connected")
        self._execute(sql)

    def _execute(self, sql: str) -> None:
        """Private method — internal implementation."""
        print(f"Executing on {self._connection}: {sql}")

# Usage
db = DatabaseConnection("localhost", 5432, "secret123")
db.connect()
db.query("SELECT * FROM users")

# Good practice:
print(db.get_status())  # Use provided method

# Technical works, but bad practice (violates encapsulation):
print(db._password)  # Accessing private attribute — don't do this!
db._is_connected = False  # Modifying private state directly — don't do this!

# The _password convention signals: "This is internal, don't rely on it"
```

### Polymorphism: Same Interface, Different Behavior

Polymorphism means "many forms." Different classes can implement the same method with different behavior. This allows code to work with any object that implements the expected interface.

```python
from abc import ABC, abstractmethod
import pandas as pd

class DataLoader(ABC):
    """Base class defining the interface."""

    @abstractmethod
    def load(self) -> pd.DataFrame:
        """All loaders must implement this."""
        pass

class CSVLoader(DataLoader):
    """Loads data from CSV — specific implementation."""
    def __init__(self, filepath: str):
        self.filepath = filepath

    def load(self) -> pd.DataFrame:
        return pd.read_csv(self.filepath)

class ParquetLoader(DataLoader):
    """Loads data from Parquet — different implementation."""
    def __init__(self, filepath: str):
        self.filepath = filepath

    def load(self) -> pd.DataFrame:
        return pd.read_parquet(self.filepath)

class S3Loader(DataLoader):
    """Loads data from S3 — yet another implementation."""
    def __init__(self, bucket: str, key: str):
        self.bucket = bucket
        self.key = key

    def load(self) -> pd.DataFrame:
        import boto3
        s3 = boto3.client("s3")
        obj = s3.get_object(Bucket=self.bucket, Key=self.key)
        return pd.read_parquet(obj["Body"])

def process_data(loader: DataLoader) -> None:
    """
    This function works with ANY DataLoader, regardless of implementation.
    Polymorphism: same interface, different behavior.
    """
    df = loader.load()
    print(f"Loaded {len(df)} rows")
    print(f"Columns: {df.columns.tolist()}")

# Create different loaders
csv_loader = CSVLoader("data.csv")
parquet_loader = ParquetLoader("data.parquet")
s3_loader = S3Loader("my-bucket", "data/output.parquet")

# Same function works with all of them
process_data(csv_loader)       # Loads from CSV
process_data(parquet_loader)   # Loads from Parquet
process_data(s3_loader)        # Loads from S3

# Add a new loader type without changing process_data()
class BigQueryLoader(DataLoader):
    def __init__(self, table_id: str):
        self.table_id = table_id

    def load(self) -> pd.DataFrame:
        from google.cloud import bigquery
        client = bigquery.Client()
        return client.query(f"SELECT * FROM {self.table_id}").to_dataframe()

bq_loader = BigQueryLoader("project.dataset.table")
process_data(bq_loader)  # Works immediately — no changes to process_data()
```

### Composition vs Inheritance

Composition (a class *has* another class) is often more flexible than inheritance (a class *is* another class).

```python
# INHERITANCE approach
class PipelineWithLogging:
    """If we inherit, we're committed to the whole hierarchy."""
    def process(self):
        self.log("Processing started")
        self.actual_work()
        self.log("Processing done")

# Tight coupling: if you want logging, you must inherit

# COMPOSITION approach (more flexible)
class Logger:
    """Separate concern — logging logic."""
    def log(self, level: str, message: str):
        print(f"[{level}] {message}")

class Pipeline:
    """Pipeline doesn't inherit logging; it *has* a logger."""
    def __init__(self, logger: Logger = None):
        self.logger = logger or Logger()

    def process(self):
        self.logger.log("INFO", "Processing started")
        self.actual_work()
        self.logger.log("INFO", "Processing done")

    def actual_work(self):
        print("Doing work...")

# Composition benefits:
logger = Logger()
pipeline = Pipeline(logger=logger)  # Can provide custom logger
pipeline.process()

# Can swap loggers easily
class FileLogger(Logger):
    def log(self, level: str, message: str):
        with open("app.log", "a") as f:
            f.write(f"[{level}] {message}\n")

pipeline = Pipeline(logger=FileLogger())  # Use different logger
pipeline.process()  # Works with new logger

# Principle: "Favor composition over inheritance"
# Inheritance creates tight hierarchies; composition is more flexible
```

---

## Part 2: OOP Advanced Patterns

## Abstract Base Classes (ABC)

### Understanding the Problem ABC Solves

When designing a class hierarchy, you often want to define a contract that all subclasses must follow. For example, you might have different types of data loaders (CSV, Parquet, S3, BigQuery), and they must all implement `load()` and `validate()` methods.

Without ABC, developers could accidentally forget to implement required methods. The code would compile fine, but crash at runtime when those methods are called. ABC moves this check to **class definition time**, catching the error immediately.

```python
# WITHOUT ABC — bad: errors caught at runtime, buried in call stack
class DataLoader:
    def load(self):
        raise NotImplementedError("Subclass must implement load()")

class CSVLoader(DataLoader):
    pass  # Forgot to implement load()!

# This works at class definition time
csv_loader = CSVLoader()

# But crashes at runtime when someone calls it
try:
    csv_loader.load()  # NotImplementedError — hard to trace if called deep in code
except NotImplementedError as e:
    print(f"Error caught too late: {e}")
```

### WITH ABC — errors caught immediately at instantiation

ABC enforces that subclasses implement required methods at **instantiation time**, not at call time. If you try to create an instance of a class that hasn't implemented all abstract methods, you get a `TypeError` immediately.

```python
from abc import ABC, abstractmethod
import pandas as pd

class DataLoader(ABC):
    """
    Abstract base class that defines the contract all loaders must follow.
    Subclasses MUST implement load() and validate().
    """

    @abstractmethod
    def load(self) -> pd.DataFrame:
        """Pull raw data. Return a DataFrame.
        
        This method has no implementation in the base class.
        Subclasses MUST override it.
        """
        ...

    @abstractmethod
    def validate(self) -> bool:
        """Check if data is valid.
        
        Subclasses MUST implement this logic.
        """
        ...

    # Concrete method — shared logic that subclasses inherit
    def load_and_validate(self) -> pd.DataFrame:
        """Template method pattern: orchestrate abstract methods."""
        df = self.load()  # Calls the subclass's load() implementation
        if not self.validate():
            raise ValueError("Data validation failed")
        return df

# This will NOT work — tries to instantiate abstract class
try:
    loader = DataLoader()  # TypeError immediately
except TypeError as e:
    print(f"Caught immediately: {e}")
    # TypeError: Can't instantiate abstract class DataLoader with abstract method load

# Missing load() implementation
class IncompleteCSVLoader(DataLoader):
    def validate(self) -> bool:
        return True
    # Missing load() !

try:
    loader = IncompleteCSVLoader()  # TypeError immediately
except TypeError as e:
    print(f"Error caught at instantiation: {e}")
    # TypeError: Can't instantiate abstract class IncompleteCSVLoader with abstract method load

# Correct implementation — has all abstract methods
class CSVLoader(DataLoader):
    def __init__(self, filepath: str):
        self.filepath = filepath

    def load(self) -> pd.DataFrame:
        return pd.read_csv(self.filepath)

    def validate(self) -> bool:
        df = pd.read_csv(self.filepath)
        return len(df) > 0 and df.isnull().sum().sum() == 0

# This works — all abstract methods implemented
csv_loader = CSVLoader("data.csv")  # OK
df = csv_loader.load_and_validate()  # Uses subclass's load(), validates

# Comparison with the old way:
# WITHOUT ABC: error at csv_loader.load() (could be deep in production)
# WITH ABC: error at CSVLoader() instantiation (immediately obvious)
```

### Why ABC Catches Errors Early

The key insight: ABC shifts error detection from **runtime call-time** to **class definition time**. This is critical in production systems where a method might not be called until hours or days after the class is instantiated.

```python
# Scenario: you have a data pipeline that runs jobs
class ETLOrchestrator:
    def __init__(self, loaders: list[DataLoader]):
        self.loaders = loaders  # All loaders should implement DataLoader contract

    def run_all_jobs(self):
        # This might be called hours after initialization
        for loader in self.loaders:
            df = loader.load()  # Crashes here if load() not implemented

# With ABC, this error happens at initialization:
# loaders = [CSVLoader(...), IncompleteCSVLoader(...)]  # TypeError immediately
# So the issue is caught before orchestrator is even created

# Without ABC, the error happens deep in production:
# orchestrator = ETLOrchestrator([...])  # Seems fine
# orchestrator.run_all_jobs()  # Crashes hours later, data pipeline down
```

### Abstract Properties

You can also enforce properties that subclasses must implement:

```python
from abc import ABC, abstractmethod

class Database(ABC):
    """Abstract database connection."""

    @property
    @abstractmethod
    def connection_string(self) -> str:
        """Subclasses must provide a connection string property."""
        ...

    @classmethod
    @abstractmethod
    def from_config(cls, config: dict) -> "Database":
        """Alternative constructor — subclasses must implement."""
        ...

    def connect(self):
        """Concrete method using abstract property."""
        print(f"Connecting to: {self.connection_string}")

class PostgresDB(Database):
    def __init__(self, host: str, user: str, password: str, database: str):
        self._host = host
        self._user = user
        self._password = password
        self._database = database

    @property
    def connection_string(self) -> str:
        """Subclass provides the property."""
        return f"postgresql://{self._user}@{self._host}/{self._database}"

    @classmethod
    def from_config(cls, config: dict) -> "PostgresDB":
        """Subclass implements alternative constructor."""
        return cls(
            host=config["host"],
            user=config["user"],
            password=config["password"],
            database=config["database"],
        )

# Usage
db = PostgresDB("localhost", "admin", "secret", "mydb")
db.connect()  # Uses the connection_string property defined by subclass
# Output: "Connecting to: postgresql://admin@localhost/mydb"
```

---

## Protocol (Structural Subtyping)

### Understanding Nominal vs Structural Typing

Python supports two approaches to type checking:

1. **Nominal Typing** (name-based): A type is considered valid if it's explicitly declared to be that type. This is what inheritance provides.

2. **Structural Typing** (shape-based): A type is considered valid if it has the required structure (methods and attributes), regardless of its declared type. This is what Protocol provides.

```python
# NOMINAL TYPING (inheritance-based)
class Loadable:
    def load(self, data):
        pass

class Exporter:
    def load(self, data):
        pass

# To be a Loadable, you must explicitly inherit
class CSVLoader(Loadable):  # Explicitly declares: "I am Loadable"
    def load(self, data):
        print(f"Loading CSV: {data}")

# But Exporter also has load() method — it IS structurally compatible
# Yet it's not considered a Loadable because it doesn't inherit from Loadable

def process(loader: Loadable):
    loader.load("file.csv")

process(CSVLoader("data"))      # OK — CSVLoader inherits from Loadable
process(Exporter())              # TypeError — Exporter doesn't inherit from Loadable
                                 # Even though it has the load() method!
```

Protocol solves this by using **structural typing**: if a class has the required methods, it's automatically compatible, even without explicit inheritance.

```python
from typing import Protocol, runtime_checkable
import pandas as pd

@runtime_checkable
class Loadable(Protocol):
    """
    A Protocol defines a structural interface.
    Any class with a compatible load() method is considered Loadable,
    even without explicitly inheriting from Loadable.
    """
    def load(self, df: pd.DataFrame) -> int: ...

# Multiple implementations — none explicitly inherit from Loadable
class SnowflakeLoader:
    def load(self, df: pd.DataFrame) -> int:
        # Snowflake-specific loading logic
        return len(df)

class BigQueryLoader:
    def load(self, df: pd.DataFrame) -> int:
        # BigQuery-specific loading logic
        return len(df)

class DeltaLakeLoader:
    def load(self, df: pd.DataFrame) -> int:
        # Delta Lake-specific loading logic
        return len(df)

def process_and_load(loader: Loadable, df: pd.DataFrame) -> None:
    """
    This function accepts ANY loader that has a compatible load() method.
    Doesn't care about inheritance — only cares about structure.
    """
    rows_written = loader.load(df)
    print(f"Loaded {rows_written} rows")

# All work automatically — no inheritance needed!
sf_loader = SnowflakeLoader()
bq_loader = BigQueryLoader()
delta_loader = DeltaLakeLoader()

df = pd.DataFrame({"id": [1, 2, 3], "value": [10, 20, 30]})

process_and_load(sf_loader, df)     # Works — structurally matches
process_and_load(bq_loader, df)     # Works — structurally matches
process_and_load(delta_loader, df)  # Works — structurally matches

# runtime_checkable enables isinstance() checks
print(isinstance(sf_loader, Loadable))      # True — has load() method
print(isinstance(bq_loader, Loadable))      # True
print(isinstance(DeltaLakeLoader(), Loadable))  # True

# Now you can add a new loader without modifying existing code
class PineconeLoader:
    def load(self, df: pd.DataFrame) -> int:
        return len(df)

process_and_load(PineconeLoader(), df)  # Works immediately!
```

### Why Protocols Are Better for External Code

The key advantage: Protocols work well when you're integrating **external libraries** or **third-party code** that you don't control.

```python
# Scenario: You're building a data framework
# Users provide their own loaders (external code)

from typing import Protocol, runtime_checkable

@runtime_checkable
class DataWriter(Protocol):
    """External users implement this Protocol."""
    def write(self, data: dict) -> None: ...

# Your framework's function
def save_pipeline_output(writer: DataWriter, results: dict) -> None:
    writer.write(results)

# External user 1 — uses your framework, but has their own loader
class UserS3Writer:
    def write(self, data: dict) -> None:
        print(f"Writing to S3: {len(data)} records")

# External user 2 — different loader, same structure
class UserDatabaseWriter:
    def write(self, data: dict) -> None:
        print(f"Writing to database: {len(data)} records")

# Both work with your framework without needing to inherit from anything!
save_pipeline_output(UserS3Writer(), {"user_id": 123, "score": 95})
save_pipeline_output(UserDatabaseWriter(), {"user_id": 123, "score": 95})

# If you used ABC, users would need to import and inherit:
# class UserS3Writer(DataWriter):  # Required extra step
#     def write(self, data: dict) -> None:
#         ...
```

### ABC vs Protocol: When to Use Each

| Scenario | Use ABC | Use Protocol |
|---|---|---|
| Building an internal framework with subclasses you control | ✅ ABC enforces contract | ❌ Overkill |
| Integrating external/third-party code | ❌ Forces external code to inherit | ✅ Protocol works with existing code |
| Validation at instantiation (catch errors early) | ✅ ABC raises TypeError | ❌ Protocol doesn't validate |
| Duck typing for flexibility | ❌ Too rigid | ✅ Perfect match |
| Library with many plugins | ❌ Burden on users | ✅ Users don't need to inherit |

```python
# DATA ENGINEERING EXAMPLE: Pluggable loaders

# Your framework (you control)
from abc import ABC, abstractmethod

class InternalETLStep(ABC):
    """For internal steps you write."""
    @abstractmethod
    def process(self, df) -> pd.DataFrame:
        ...

class InternalAggregateStep(InternalETLStep):
    def process(self, df) -> pd.DataFrame:
        return df.groupby("date").agg({"amount": "sum"}).reset_index()

# For external users (you don't control)
from typing import Protocol

@runtime_checkable
class ExternalTransformer(Protocol):
    """External users provide their custom transformers without inheriting."""
    def transform(self, df) -> pd.DataFrame: ...

# User's custom code
class UserCustomDeduplicate:
    def transform(self, df) -> pd.DataFrame:
        return df.drop_duplicates(subset=["user_id"])

# You accept both without modification
internal_step = InternalAggregateStep()
user_transformer = UserCustomDeduplicate()

# Both work
processed1 = internal_step.process(df)          # Internal ABC class
processed2 = user_transformer.transform(df)    # External Protocol class
```

---

## Dataclasses

### What Problem Does Dataclass Solve?

Writing classes that primarily hold data (not complex logic) requires a lot of boilerplate:

```python
# WITHOUT dataclass — lots of repetitive code
class PipelineConfig:
    def __init__(self, source_bucket: str, target_schema: str, batch_size: int = 10_000, dry_run: bool = False):
        self.source_bucket = source_bucket
        self.target_schema = target_schema
        self.batch_size = batch_size
        self.dry_run = dry_run

    def __repr__(self):
        return f"PipelineConfig(source_bucket={self.source_bucket!r}, target_schema={self.target_schema!r}, batch_size={self.batch_size!r}, dry_run={self.dry_run!r})"

    def __eq__(self, other):
        if not isinstance(other, PipelineConfig):
            return False
        return (self.source_bucket == other.source_bucket and
                self.target_schema == other.target_schema and
                self.batch_size == other.batch_size and
                self.dry_run == other.dry_run)
```

This is verbose and error-prone. Dataclass automates this:

```python
from dataclasses import dataclass

@dataclass
class PipelineConfig:
    """Same functionality, much less code. Auto-generates __init__, __repr__, __eq__."""
    source_bucket: str
    target_schema: str
    batch_size: int = 10_000
    dry_run: bool = False

# All auto-generated:
config = PipelineConfig("my-bucket", "prod")
print(config)  # Auto-generated __repr__: PipelineConfig(source_bucket='my-bucket', target_schema='prod', batch_size=10000, dry_run=False)

config2 = PipelineConfig("my-bucket", "prod", batch_size=10_000, dry_run=False)
print(config == config2)  # Auto-generated __eq__: True
```

### Dataclass with Validation

Dataclasses provide `__post_init__()` for validation and derived fields:

```python
from dataclasses import dataclass, field
from typing import Optional
import uuid

@dataclass
class PipelineConfig:
    source_bucket: str
    target_schema: str
    batch_size: int = 10_000
    dry_run: bool = False
    tags: list[str] = field(default_factory=list)  # Mutable default safe
    _run_id: str = field(default=None, init=False, repr=False)  # Internal field, not in __init__

    def __post_init__(self):
        """Called automatically after __init__. Use for validation and derived fields."""
        # Validation
        if self.batch_size <= 0:
            raise ValueError("batch_size must be positive")
        if not self.source_bucket.startswith("s3://"):
            raise ValueError("source_bucket must be an S3 path")

        # Derived field
        self._run_id = str(uuid.uuid4())

    @classmethod
    def from_env(cls) -> "PipelineConfig":
        """Alternative constructor — read from environment."""
        import os
        return cls(
            source_bucket=os.environ["SOURCE_BUCKET"],
            target_schema=os.environ.get("TARGET_SCHEMA", "public"),
            batch_size=int(os.environ.get("BATCH_SIZE", 10_000)),
        )

# Usage
config = PipelineConfig(source_bucket="s3://my-bucket", target_schema="prod")
print(config._run_id)  # Auto-generated UUID

# Validation runs automatically
try:
    bad = PipelineConfig("invalid", "prod", batch_size=-1)  # ValueError
except ValueError as e:
    print(f"Caught: {e}")
```

### Mutable Default Argument Trap

A critical gotcha: using mutable objects as defaults:

```python
from dataclasses import dataclass, field

# WRONG — shared list across all instances!
@dataclass
class UserBatch:
    user_ids: list[int] = []  # Shared list!

batch1 = UserBatch()
batch1.user_ids.append(1)

batch2 = UserBatch()
print(batch2.user_ids)  # [1] — shared!

# CORRECT — each instance gets its own list
@dataclass
class UserBatch:
    user_ids: list[int] = field(default_factory=list)  # New list per instance

batch1 = UserBatch()
batch1.user_ids.append(1)

batch2 = UserBatch()
print(batch2.user_ids)  # [] — independent list
```

### Frozen Dataclasses (Immutable)

A `frozen=True` dataclass is immutable and hashable (can be used as dict key or in set):

```python
from dataclasses import dataclass

@dataclass(frozen=True)  # Immutable — raises FrozenInstanceError on modification
class TableKey:
    """Represents a uniquely identifiable table."""
    schema: str
    table: str

    def __str__(self):
        return f"{self.schema}.{self.table}"

# Can be used as dict key
table_cache = {}
key1 = TableKey("public", "users")
key2 = TableKey("public", "orders")

table_cache[key1] = "user_table_schema"
table_cache[key2] = "order_table_schema"

print(table_cache[TableKey("public", "users")])  # Works — same key

# Can be in sets
unique_tables = {key1, key2}

# Cannot modify
try:
    key1.table = "different"  # FrozenInstanceError
except Exception as e:
    print(f"Cannot modify: {e}")
```

### Ordering Dataclasses

With `order=True`, dataclass generates comparison methods (`__lt__`, `__le__`, `__gt__`, `__ge__`):

```python
from dataclasses import dataclass

@dataclass(order=True)  # Generates comparison methods
class PipelineJob:
    priority: int
    name: str
    created_at: str = ""

job1 = PipelineJob(priority=1, name="high_priority")
job2 = PipelineJob(priority=3, name="low_priority")
job3 = PipelineJob(priority=2, name="medium_priority")

jobs = [job2, job1, job3]
jobs.sort()  # Sorts by priority first, then name
print(jobs)
# [PipelineJob(priority=1, name='high_priority'),
#  PipelineJob(priority=2, name='medium_priority'),
#  PipelineJob(priority=3, name='low_priority')]

# Useful for priority queues, sorting records
print(job1 < job2)  # True — lower priority is "less"
print(job1 <= job2)  # True
```

### Dataclass vs namedtuple: When to Use Each

| | `dataclass` | `namedtuple` |
|---|---|---|
| **Mutable** | Yes (unless `frozen=True`) | No — immutable |
| **Default values** | Yes — both positional and keyword | Yes (Python 3.6.1+) |
| **Methods** | Easy to add — just define them | Limited — mostly tuple operations |
| **Memory** | Higher (has `__dict__`) | Lower (just a tuple) |
| **Type hints** | Native support | Need `NamedTuple` from typing |
| **Use when** | Config objects, mutable state, need validation | Lightweight return values, performance critical |

```python
# Dataclass — good for config and stateful objects
from dataclasses import dataclass

@dataclass
class DatabaseConfig:
    host: str
    port: int = 5432
    username: str = "admin"

    def connection_string(self):
        return f"postgresql://{self.username}@{self.host}:{self.port}"

config = DatabaseConfig("localhost")
print(config.connection_string())  # Easy to add methods

# namedtuple — good for lightweight, immutable return values
from typing import NamedTuple

class QueryResult(NamedTuple):
    rows: int
    columns: list[str]
    execution_time_ms: float

# Less memory, immutable, tuple-like
result = QueryResult(1000, ["id", "name", "email"], 45.3)
print(result.rows)  # 1000
print(result[0])    # 1000 — tuple indexing works too
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

### Understanding the Problem Singleton Solves

Some resources should only exist once in the entire application:
- Database connection pools
- Configuration managers
- Logging services
- Cache managers

Without a Singleton pattern, you might accidentally create multiple instances:

```python
# WITHOUT Singleton — can create multiple instances
class Config:
    def __init__(self, env="dev"):
        self.env = env
        self.settings = {}

config1 = Config("prod")
config2 = Config("dev")
config3 = Config("staging")

# Now you have 3 different config objects with different states!
# Code might use config1 in one place, config2 in another — inconsistent state
# This causes bugs: some parts see "prod", others see "dev"
```

Singleton ensures only one instance exists:

```python
class Config:
    _instance: Optional["Config"] = None

    def __new__(cls, *args, **kwargs):
        """
        __new__ is called before __init__.
        If no instance exists, create one. Otherwise, return existing.
        """
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    def __init__(self, env="dev"):
        # Problem: __init__ is called every time
        if hasattr(self, "_initialized"):
            return  # Skip re-initialization
        self.env = env
        self.settings = {"timeout": 30, "retries": 3}
        self._initialized = True

# All references point to the same instance
config1 = Config("prod")
config2 = Config("dev")
config3 = Config("staging")

print(config1 is config2)  # True — same object
print(config1 is config3)  # True — same object
print(config1.env)         # "prod" — only the first init matters

# Modify via any reference — all see the change
config1.settings["timeout"] = 60
print(config2.settings["timeout"])  # 60 — same object
print(config3.settings["timeout"])  # 60 — same object
```

### Thread-Safe Singleton

In multi-threaded environments (databases, web servers), multiple threads might try to create the singleton simultaneously. You need a lock:

```python
import threading
from typing import Optional

class ThreadSafeConfig:
    """
    Thread-safe singleton using double-checked locking.
    Ensures only one instance even if multiple threads try to create it simultaneously.
    """
    _instance: Optional["ThreadSafeConfig"] = None
    _lock = threading.Lock()

    @classmethod
    def get_instance(cls) -> "ThreadSafeConfig":
        """
        Double-checked locking pattern:
        1. First check without lock (fast path)
        2. If instance doesn't exist, acquire lock (slow path)
        3. Check again inside lock (in case another thread created it)
        4. Create if still doesn't exist
        """
        if cls._instance is None:  # First check (fast, no lock)
            with cls._lock:        # Acquire lock
                if cls._instance is None:  # Second check (inside lock)
                    cls._instance = cls()  # Create the one and only instance
        return cls._instance

    def __init__(self):
        self.config = {}

# Multiple threads trying to get the singleton
def thread_func():
    config = ThreadSafeConfig.get_instance()
    config.config["thread_" + str(threading.current_thread().ident)] = "value"

threads = [threading.Thread(target=thread_func) for _ in range(10)]
for t in threads:
    t.start()
for t in threads:
    t.join()

# All threads got the same instance
final_config = ThreadSafeConfig.get_instance()
print(len(final_config.config))  # 10 entries, but single Config object
```

### When NOT to Use Singleton

Singleton seems convenient but has drawbacks:

```python
# PROBLEM 1: Hard to test — global state makes testing difficult
class DatabasePool:
    _instance = None
    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance
    def __init__(self):
        self.connections = []

def fetch_user(user_id):
    # Uses global DatabasePool
    db = DatabasePool()
    return db.query(f"SELECT * FROM users WHERE id={user_id}")

# To test fetch_user, you need the real DatabasePool
# Can't easily mock it or use a test database
def test_fetch_user():
    user = fetch_user(1)
    assert user is not None  # But this uses REAL database!

# PROBLEM 2: Can't have multiple instances for different scenarios
# What if you need one Config for tests and another for production?

# SOLUTION: Use dependency injection instead of Singleton
class UserService:
    def __init__(self, db_pool):  # Accept dependency
        self.db_pool = db_pool

    def fetch_user(self, user_id):
        return self.db_pool.query(f"SELECT * FROM users WHERE id={user_id}")

# Testing: inject test database
def test_with_injection():
    mock_db = MockDatabasePool()
    service = UserService(mock_db)
    user = service.fetch_user(1)
    assert user is not None  # Uses mock, not real database

# Production: inject real database
def production():
    real_db = DatabasePool()
    service = UserService(real_db)
    return service.fetch_user(1)
```

### Better Alternatives to Singleton

#### Module-Level Singletons (Pythonic)

Python modules are singletons by nature — they're imported once and shared:

```python
# config.py — module-level singleton
class _Config:
    def __init__(self):
        self.env = "dev"
        self.settings = {}

# Module-level instance — import this, not the class
_instance = _Config()

def get_config():
    return _instance

# main.py
from config import get_config

config = get_config()
config.env = "prod"

# other_module.py
from config import get_config

config = get_config()
print(config.env)  # "prod" — same instance
```

#### Factory Pattern with Caching

More flexible than Singleton — allows multiple instances if needed:

```python
class ConnectionFactory:
    _cache = {}

    @classmethod
    def get_connection(cls, db_type: str, **kwargs):
        # Cache key based on db_type and options
        cache_key = (db_type, tuple(sorted(kwargs.items())))

        if cache_key not in cls._cache:
            cls._cache[cache_key] = cls._create_connection(db_type, **kwargs)

        return cls._cache[cache_key]

    @staticmethod
    def _create_connection(db_type: str, **kwargs):
        if db_type == "postgres":
            return PostgresConnection(**kwargs)
        elif db_type == "mysql":
            return MySQLConnection(**kwargs)
        # etc.

# Use: can have multiple connections, but reuses same instance for same config
prod_db = ConnectionFactory.get_connection("postgres", host="prod-server")
test_db = ConnectionFactory.get_connection("postgres", host="test-server")
prod_db_again = ConnectionFactory.get_connection("postgres", host="prod-server")

print(prod_db is prod_db_again)  # True — same instance (cached)
print(prod_db is test_db)        # False — different instances (different configs)
```

---

## Interview Questions

### OOP Fundamentals

**Q: What's the difference between a class and an object?**
A class is a blueprint that defines structure and behavior. An object is a concrete instance of that class. You define a class once (e.g., `class Pipeline`), but you can create many objects from it (`p1 = Pipeline()`, `p2 = Pipeline()`).

**Q: What are instance variables vs class variables? Why does it matter?**
Instance variables are specific to each object (defined in `__init__`). Class variables are shared by all instances (defined at class level). Modifying a class variable affects all instances. This matters for shared state like counters, configuration, or connection pools.

**Q: Explain the three types of methods: instance, class, and static. When do you use each?**
- **Instance methods**: Operate on individual object state. Use for normal operations. (`self` parameter)
- **Class methods**: Operate on shared class state or create alternative constructors. Use for factory methods or modifying class-level data. (`@classmethod`, `cls` parameter)
- **Static methods**: Pure utility functions with no state. Use for helper functions that logically belong to the class but don't access instance or class data. (`@staticmethod`, no special parameter)

**Q: What does `super()` do and why is it important?**
`super()` calls a parent class's method from a child class. It's important for extending behavior without duplicating code. Example: `super().__init__()` in a subclass's `__init__` runs the parent's initialization first, then the child's.

**Q: What is Method Resolution Order (MRO)?**
MRO is the order Python searches for methods in an inheritance hierarchy. You can view it with `ClassName.__mro__`. Python searches: subclass first, then parent classes (left-to-right in multiple inheritance), then built-in `object`. Important for multiple inheritance and understanding which method gets called.

**Q: What is encapsulation? How does Python implement it?**
Encapsulation bundles data and methods together and controls external access. Python uses naming conventions: single underscore `_private` means "internal, don't use" (soft restriction), double underscore `__private` causes name mangling (harder to access accidentally). But Python trusts developers — there's no true access control like `private` in Java.

**Q: What's polymorphism? Give a data engineering example.**
Polymorphism means "many forms" — different classes implement the same method differently. Example: different loaders (CSV, Parquet, S3) all implement `load()` method, but each works differently. Code can call `loader.load()` without knowing which loader type it is.

**Q: When should you use inheritance vs composition?**
**Inheritance** (`class Child(Parent)`): "Child IS-A Parent". Use when the relationship is fundamental. Example: `SalesETL IS-A ETLPipeline`.
**Composition** (`self.logger = Logger()`): "Child HAS-A component". More flexible, easier to test. Example: `Pipeline HAS-A logger`. **Prefer composition** — it's more flexible and avoids tight coupling.

**Q: What's the purpose of `__init__`? What happens if you don't define it?**
`__init__` is the constructor — called automatically when you create an instance. It initializes instance attributes. If you don't define it, Python uses the default (which does nothing). Parent class's `__init__` is NOT called automatically — you must call it with `super().__init__()`.

---

### OOP Advanced Patterns

**Q: Why use ABC instead of just raising `NotImplementedError` in the base class?**
ABC raises `TypeError` when you try to **instantiate** a class with missing abstract methods. `NotImplementedError` only fires when the method is **called**. ABC catches missing implementations immediately at class instantiation, not buried in a runtime call path hours later.

**Q: What is a dataclass and what does it auto-generate?**
A class decorated with `@dataclass` auto-generates `__init__`, `__repr__`, and `__eq__` from type-annotated class attributes. With `order=True` it adds comparison methods; with `frozen=True` it makes the instance immutable and hashable. Saves lots of boilerplate for data-holding classes.

**Q: What's the difference between `field(default_factory=list)` and `default=[]`?**
`default=[]` shares the same list object across all instances (mutable default argument bug). `field(default_factory=list)` calls `list()` for each new instance, so each instance gets its own list. **Always use `field(default_factory=...)` for mutable defaults in dataclasses.**

**Q: What is a Protocol vs an ABC?**
ABC requires explicit inheritance and validates at instantiation time. Protocol uses structural typing — any class with the required methods satisfies the protocol without inheriting. Protocol is more flexible for external/pluggable code; ABC is better for internal class hierarchies you control.

**Q: Why use Protocol for external integrations?**
External code (plugins, third-party libraries) doesn't need to know about or import your Protocol. If their class happens to have compatible methods, it works automatically. With ABC, they'd need to explicitly inherit, adding unnecessary coupling.

**Q: What is the Singleton pattern and when should you use it?**
Singleton ensures only one instance of a class exists. Useful for shared resources like config managers or connection pools. However, Singleton makes testing hard and creates global state. **Better alternatives**: dependency injection, module-level singletons, or factory pattern with caching.

**Q: What's the difference between named and nominal typing?**
**Nominal typing** (ABC, inheritance): A type is valid only if explicitly declared. `class X(BaseClass)` says "X IS-A BaseClass".
**Structural typing** (Protocol): A type is valid if it has the right structure, regardless of declaration. Any class with the required methods is compatible.

**Q: How does the template method pattern work in ETL pipelines?**
Define the algorithm skeleton (e.g., `run()` calling `extract()`, `transform()`, `load()`) in the base class, with abstract methods that subclasses fill in. The base class controls flow, logging, and error handling; subclasses provide only the data-source-specific logic.

**Q: What's the mutable default argument bug? How do you avoid it?**
In regular classes, mutable defaults (like `def __init__(self, tags=[])`) are created once and shared across all instances. Fix: use `None` as default, then check in `__init__`. In dataclasses, use `field(default_factory=list)`.

**Q: When would you use a frozen dataclass?**
Frozen dataclasses are immutable and hashable. Use them as dict keys or set members. Example: `TableKey(schema="public", table="users")` as a cache key. Also signals intent: "this config won't change after creation."

---
