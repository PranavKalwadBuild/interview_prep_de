<!-- python-patterns: Pythonic Way of Writing Code -->

# Writing Pythonic Code for Data Engineering

## What Does "Pythonic" Mean?

Pythonic code follows the idioms, conventions, and best practices of the Python language. It's code that feels natural to experienced Python developers - readable, efficient, and leveraging Python's unique features.

**The Zen of Python** (access via `import this`) summarizes Pythonic principles:
- Beautiful is better than ugly
- Explicit is better than implicit  
- Simple is better than complex
- Readability counts
- Special cases aren't special enough to break the rules
- Although practicality beats purity
- Errors should never pass silently
- In the face of ambiguity, refuse the temptation to guess
- There should be one-- and preferably only one --obvious way to do it
- If the implementation is hard to explain, it's a bad idea
- Namespaces are one honking great idea -- let's do more of those!

In DE, Pythonic code leads to more maintainable pipelines, fewer bugs, and easier collaboration.

---

## Core Pythonic Idioms

### 1. Truth Value Testing
```python
# NOT Pythonic
if len(items) > 0:
    process(items)

if items != []:
    process(items)

# Pythonic - rely on truthiness
if items:
    process(items)

# For checking emptiness
if not items:
    handle_empty()

# For None checks (explicit is better than implicit)
if value is None:
    handle_none()
if value is not None:
    process_value()
```

### 2. EAFP vs LBYL
```python
# EAFP: Easier to Ask for Forgiveness than Permission (Pythonic)
try:
    value = mapping[key]
except KeyError:
    value = default

# vs LBYL: Look Before You Leap (less Pythonic)
if key in mapping:
    value = mapping[key]
else:
    value = default

# EAFP works better with duck typing and avoids race conditions
try:
    file = open(path)
    process(file)
finally:
    file.close()

# Better yet: use context managers
with open(path) as file:
    process(file)  # auto-closed
```

### 3. Context Managers (with statement)
```python
# Resources that need cleanup
with open('data.json') as f:
    data = json.load(f)

with database.connect() as conn:
    with conn.cursor() as cursor:
        cursor.execute(query)
        results = cursor.fetchall()

# Custom context manager
from contextlib import contextmanager

@contextmanager
def timer():
    start = time.time()
    try:
        yield
    finally:
        end = time.time()
        print(f"Elapsed: {end - start:.2f}s")

# Usage
with timer():
    process_large_dataset()
```

### 4. List, Dict, Set Comprehensions
```python
# NOT Pythonic - verbose loop
squared = []
for x in range(10):
    squared.append(x**2)

# Pythonic - comprehensions
squared = [x**2 for x in range(10)]

# With condition
evens = [x for x in range(20) if x % 2 == 0]

# Nested comprehensions
matrix = [[0 for _ in range(3)] for _ in range(3)]

# Dict comprehension
word_lengths = {word: len(word) for word in words}

# Set comprehension
unique_chars = {char for char in text if char.isalpha()}
```

### 5. Generator Expressions
```python
# Memory efficient for large datasets
# List comprehension - creates full list in memory
squares_list = [x**2 for x in range(1000000)]

# Generator expression - lazy evaluation
squares_gen = (x**2 for x in range(1000000))

# Use with functions that accept iterables
total = sum(x**2 for x in range(1000000))  # No intermediate list
max_val = max(x**2 for x in range(1000000))
any_negative = any(x < 0 for x in numbers)

# Chaining generators
processed = (
    strip_whitespace(line)
    for line in read_lines(file)
    if not line.startswith('#')
)
```

### 6. enumerate() and zip()
```python
# NOT Pythonic - manual indexing
for i in range(len(items)):
    print(f"Item {i}: {items[i]}")

# Pythonic - enumerate
for index, item in enumerate(items):
    print(f"Item {index}: {item}")

# Custom start index
for index, item in enumerate(items, start=1):
    print(f"Item {index}: {item}")

# zip() for parallel iteration
names = ['Alice', 'Bob', 'Charlie']
scores = [85, 92, 78]
for name, score in zip(names, scores):
    print(f"{name}: {score}")

# Unequal iterables - zip stops at shortest
# Use itertools.zip_longest for fill values
from itertools import zip_longest
for name, score in zip_longest(names, scores, fillvalue=0):
    print(f"{name}: {score}")
```

### 7. Unpacking (Tuple/Dict Unpacking)
```python
# Multiple assignment
x, y = 1, 2
a, b, c = [10, 20, 30]

# Swapping variables
a, b = b, a  # No temp variable needed

# Function returning multiple values
def get_range():
    return 0, 100

min_val, max_val = get_range()

# Ignoring values with underscore
filename, _, extension = "report.pdf".rpartition('.')
# filename='report', _='.', extension='pdf'

first, *middle, last = [1, 2, 3, 4, 5]
# first=1, middle=[2, 3, 4], last=5

# Dictionary unpacking
def connect_db(host, port, database, user, password):
    # connection logic
    pass

config = {
    'host': 'localhost',
    'port': 5432,
    'database': 'analytics',
    'user': 'etl_user',
    'password': 'secret'
}
connect_db(**config)  # Unpacks dict as keyword args

# Partial unpacking
base_config = {'host': 'localhost', 'port': 5432}
dev_config = {**base_config, 'database': 'dev_db', 'user': 'dev'}
```

### 8. args and kwargs
```python
# Flexible function signatures
def log_message(level, *args, **kwargs):
    message = args[0] if args else ""
    timestamp = kwargs.get('timestamp', datetime.now())
    user = kwargs.get('user', 'system')
    print(f"[{timestamp}] [{level}] [{user}] {message}")

# Usage
log_message("INFO", "Pipeline started")
log_message("ERROR", "Failed to connect", user="etl_job", timestamp=now())

# args = tuple of positional arguments beyond named ones
# kwargs = dict of keyword arguments beyond named ones
```

### 9. String Formatting
```python
# NOT Pythonic - old % formatting
log_entry = "%s - %s - %s" % (timestamp, level, message)

# NOT Pythonic - .format() (still okay but f-strings preferred)
log_entry = "{timestamp} - {level} - {message}".format(
    timestamp=timestamp, level=level, message=message
)

# Pythonic - f-strings (Python 3.6+)
log_entry = f"{timestamp} - {level} - {message}"

# With expressions
log_entry = f"Processed {len(items)} items at {datetime.now():%Y-%m-%d %H:%M:%S}"

# Multi-line f-strings
query = f"""
    SELECT *
    FROM {table}
    WHERE date >= '{start_date}'
      AND date < '{end_date}'
    ORDER BY timestamp
"""

# Template strings for safety (avoid injection)
from string import Template
sql_template = Template("SELECT $columns FROM $table WHERE $condition")
safe_query = sql_template.substitute(
    columns="*", 
    table="users", 
    condition="active = 1"
)
```

### 10. elif Chains
```python
# NOT Pythonic - nested ifs
if score >= 90:
    grade = 'A'
else:
    if score >= 80:
        grade = 'B'
    else:
        if score >= 70:
            grade = 'C'
        else:
            grade = 'F'

# Pythonic - flat elif chain
if score >= 90:
    grade = 'A'
elif score >= 80:
    grade = 'B'
elif score >= 70:
    grade = 'C'
else:
    grade = 'F'
```

### 11. Default Dict and Counter
```python
from collections import defaultdict, Counter

# NOT Pythonic - manual key checking
counts = {}
for word in words:
    if word in counts:
        counts[word] += 1
    else:
        counts[word] = 1

# Pythonic - defaultdict
counts = defaultdict(int)
for word in words:
    counts[word] += 1

# Even better - Counter
counts = Counter(words)  # One-liner!

# Default dict with complex defaults
def default_user():
    return {'name': '', 'active': False, 'permissions': []}

users_by_id = defaultdict(default_user)
users_by_id['new_user']['name'] = 'John'
```

### 12. Named Tuples and Dataclasses
```python
# NOT Pythonic - index-based access
record = ('user123', 'john@example.com', 25, True)
user_id = record[0]  # What does index 0 mean?
email = record[1]

# Pythonic - namedtuple
from collections import namedtuple
User = namedtuple('User', ['user_id', 'email', 'age', 'is_active'])
user = User('user123', 'john@example.com', 25, True)
print(user.user_id)  # Clear and self-documenting
print(user.email)

# Even better - dataclass (Python 3.7+)
from dataclasses import dataclass
from typing import List

@dataclass
class User:
    user_id: str
    email: str
    age: int
    is_active: bool
    tags: List[str] = None  # Default factory for mutable defaults
    
    def __post_init__(self):
        if self.tags is None:
            self.tags = []

# Usage
user = User('user123', 'john@example.com', 25, True, ['premium'])
# Auto-generated __init__, __repr__, __eq__, etc.
```

### 13. Properties vs Getters/Setters
```python
# NOT Pythonic - Java-style getters/setters
class Temperature:
    def __init__(self, celsius):
        self._celsius = celsius
    
    def get_celsius(self):
        return self._celsius
    
    def set_celsius(self, value):
        if value < -273.15:
            raise ValueError("Below absolute zero")
        self._celsius = value
    
    def get_fahrenheit(self):
        return self._celsius * 9/5 + 32
    
    def set_fahrenheit(self, value):
        self.set_celsius((value - 32) * 5/9)

# Usage
temp = Temperature(25)
temp.set_fahrenheit(77)
print(temp.get_celsius())

# Pythonic - properties
class Temperature:
    def __init__(self, celsius):
        self.celsius = celsius  # Uses setter
    
    @property
    def celsius(self):
        return self._celsius
    
    @celsius.setter
    def celsius(self, value):
        if value < -273.15:
            raise ValueError("Below absolute zero")
        self._celsius = value
    
    @property
    def fahrenheit(self):
        return self._celsius * 9/5 + 32
    
    @fahrenheit.setter
    def fahrenheit(self, value):
        self.celsius = (value - 32) * 5/9

# Usage - looks like attribute access
temp = Temperature(25)
temp.fahrenheit = 77
print(temp.celsius)  # 25.0
```

### 14. Function Arguments Best Practices
```python
# NOT Pythonic - too many positional arguments
def create_pipeline(name, source, destination, schedule, retries, timeout, 
                   alert_on_failure, alert_email, max_parallel, buffer_size):
    # Hard to remember order
    pass

# Pythonic - use keyword-only arguments or config object
def create_pipeline(
    name: str,
    source: str,
    destination: str,
    *,
    schedule: str = 'daily',
    retries: int = 3,
    timeout: int = 300,
    alert_on_failure: bool = True,
    alert_email: Optional[str] = None,
    max_parallel: int = 4,
    buffer_size: int = 1024
):
    # Clear calling convention
    create_pipeline(
        "etl_job",
        "s3://raw/",
        "s3://processed/",
        schedule="hourly",
        retries=5,
        alert_email="ops@example.com"
    )

# Or use dataclass for config
@dataclass
class PipelineConfig:
    name: str
    source: str
    destination: str
    schedule: str = 'daily'
    retries: int = 3
    timeout: int = 300
    alert_on_failure: bool = True
    alert_email: Optional[str] = None
    max_parallel: int = 4
    buffer_size: int = 1024

def create_pipeline(config: PipelineConfig):
    # Implementation
    pass
```

### 15. Returning Multiple Values
```python
# NOT Pythonic - modifying args or using globals
def get_stats(numbers):
    global min_val, max_val, avg_val
    min_val = min(numbers)
    max_val = max(numbers)
    avg_val = sum(numbers) / len(numbers)

# Pythonic - return tuple
def get_stats(numbers):
    return min(numbers), max(numbers), sum(numbers) / len(numbers)

min_val, max_val, avg_val = get_stats([1, 2, 3, 4, 5])

# Even better - return named tuple or dataclass
from collections import namedtuple
Stats = namedtuple('Stats', ['min', 'max', 'avg'])

def get_stats(numbers):
    return Stats(min(numbers), max(numbers), sum(numbers) / len(numbers))

stats = get_stats([1, 2, 3, 4, 5])
print(stats.avg)  # Clear attribute access
```

---

## Pythonic Data Engineering Patterns

### 1. Pipeline Construction
```python
# NOT Pythonic - tight coupling, hard to test
class DataPipeline:
    def __init__(self):
        self.db = DatabaseConnection()
        self.api = ExternalAPI()
    
    def run(self):
        raw = self.db.fetch_raw()
        processed = []
        for record in raw:
            validated = self.api.validate(record)
            if validated:
                transformed = self.transform(validated)
                self.db.save(transformed)

# Pythonic - dependency injection, single responsibility
from typing import Protocol, List, Dict, Any

class DataSource(Protocol):
    def fetch(self) -> List[Dict[str, Any]]: ...

class Validator(Protocol):
    def validate(self, record: Dict[str, Any]) -> bool: ...

class Transformer(Protocol):
    def transform(self, record: Dict[str, Any]) -> Dict[str, Any]: ...

class DataSink(Protocol):
    def save(self, record: Dict[str, Any]) -> None: ...

@dataclass
class ETLStage:
    source: DataSource
    validator: Validator
    transformer: Transformer
    sink: DataSink
    
    def process(self) -> None:
        for record in self.source.fetch():
            if self.validator.validate(record):
                transformed = self.transformer.transform(record)
                self.sink.save(transformed)

# Usage - easy to test with mocks
class MockSource:
    def fetch(self) -> List[Dict[str, Any]]:
        return [{'id': 1, 'value': 'test'}]

class MockValidator:
    def validate(self, record: Dict[str, Any]) -> bool:
        return True

class MockTransformer:
    def transform(self, record: Dict[str, Any]) -> Dict[str, Any]:
        record['processed'] = True
        return record

class MockSink:
    def save(self, record: Dict[str, Any]) -> None:
        print(f"Saved: {record}")

pipeline = ETLStage(
    source=MockSource(),
    validator=MockValidator(),
    transformer=MockTransformer(),
    sink=MockSink()
)
pipeline.process()
```

### 2. Configuration Management
```python
# NOT Pythonic - hardcoded values, scattered config
def run_pipeline():
    source_path = "/data/raw/"
    dest_path = "/data/processed/"
    retry_count = 3
    timeout_seconds = 300
    # ... many more hardcoded values

# Pythonic - centralized, typed configuration
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

@dataclass
class PipelineConfig:
    name: str
    source_path: Path
    dest_path: Path
    schedule: Literal['hourly', 'daily', 'weekly', 'monthly']
    max_retries: int = 3
    timeout_seconds: int = 300
    enable_monitoring: bool = True
    alert_channels: List[str] = None
    
    def __post_init__(self):
        if self.alert_channels is None:
            self.alert_channels = ['email', 'slack']

# Load from file/environment
def load_config() -> PipelineConfig:
    # Read from YAML, JSON, env vars, etc.
    # Return typed config object
    pass

config = load_config()
# IDE autocomplete, type checking, clear structure
```

### 3. Error Handling and Logging
```python
# NOT Pythonic - bare except, print statements
def process_file(filepath):
    try:
        data = open(filepath).read()
        result = process_data(data)
        save_result(result)
    except:
        print("Something went wrong")

# Pythonic - specific exceptions, proper logging
import logging

logger = logging.getLogger(__name__)

def process_file(filepath: Path) -> None:
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            data = f.read()
        result = process_data(data)
        save_result(result)
    except FileNotFoundError:
        logger.error(f"File not found: {filepath}")
        raise  # Re-raise if caller should handle
    except PermissionError:
        logger.error(f"Permission denied: {filepath}")
        raise
    except UnicodeDecodeError as e:
        logger.error(f"Encoding error in {filepath}: {e}")
        # Try fallback encoding or skip
    except ValueError as e:  # From process_data
        logger.warning(f"Invalid data in {filepath}: {e}")
        # Skip file or use default
    except Exception as e:
        logger.exception(f"Unexpected error processing {filepath}")
        raise  # Re-raise unexpected errors

# Context manager for transaction-like behavior
from contextlib import contextmanager

@contextmanager
def database_transaction(conn):
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise

# Usage
with database_transaction(db_connection):
    insert_records(records)
    update_summary(stats)
    # Either both commit or both rollback
```

### 4. Testing Pythonic Code
```python
# NOT Pythonic - testing implementation details
def test_process_data():
    # Tests private methods, specific internal steps
    processor = DataProcessor()
    assert processor._validate_input.__doc__ == "..."  # Testing implementation
    # ...

# Pythonic - test behavior, not implementation
def test_process_data():
    processor = DataProcessor()
    
    # Test normal case
    result = processor.process(valid_input)
    assert result == expected_output
    
    # Test edge cases
    with pytest.raises(ValueError):
        processor.process(invalid_input)
    
    # Test empty input
    assert processor.process([]) == []
    
    # Test with mocks
    with patch('external_service.call') as mock_call:
        mock_call.return_value = mocked_response
        result = processor.process(needs_service_input)
        assert result == expected
        mock_call.assert_called_once_with(expected_params)
```

---

## DE-Specific Pythonic Considerations

### 1. Working with Large Datasets
```python
# NOT Pythonic - loads everything into memory
def process_large_file(filepath):
    with open(filepath) as f:
        lines = f.readlines()  # ALL lines in memory
    processed = [process_line(line) for line in lines]
    return processed

# Pythonic - stream processing
def process_large_file(filepath):
    with open(filepath) as f:
        for line in f:  # One line at a time
            yield process_line(line)  # Generator - memory efficient

# Or using itertools for chunking
def process_in_chunks(filepath, chunk_size=1000):
    with open(filepath) as f:
        while True:
            chunk = list(itertools.islice(f, chunk_size))
            if not chunk:
                break
            yield [process_line(line) for line in chunk]
```

### 2. Functional Approaches in DE
```python
# Pythonic functional pipeline
def etl_pipeline(raw_data):
    return (
        map(parse_line, raw_data)                    # Extract
        .__mul__(filter(is_valid, _))               # Transform
        .__mul__(enrich_with_lookup, _)             # Load
        .__mul__(aggregate_by_key, _)               # Aggregate
    )

# Better yet - use toolz or functional.seq for cleaner syntax
# from functional import seq
# seq(raw_data).map(parse_line).filter(is_valid)....
```

### 3. Working with External APIs/Services
```python
# NOT Pythonic - tight coupling, hard to test
def fetch_from_api():
    response = requests.get("https://api.example.com/data")
    if response.status_code == 200:
        return response.json()
    else:
        raise Exception("API failed")

# Pythonic - dependency injection, retries, timeouts
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

def create_retry_session(
    retries=3,
    backoff_factor=0.3,
    status_forcelist=(500, 502, 504),
):
    session = requests.Session()
    retry = Retry(
        total=retries,
        read=retries,
        connect=retries,
        backoff_factor=backoff_factor,
        status_forcelist=status_forcelist,
    )
    adapter = HTTPAdapter(max_retries=retry)
    session.mount('http://', adapter)
    session.mount('https://', adapter)
    return session

def fetch_from_api(session: requests.Session, url: str) -> dict:
    try:
        response = session.get(url, timeout=30)
        response.raise_for_status()  # Raises HTTPError for bad responses
        return response.json()
    except requests.RequestException as e:
        logger.error(f"API request failed: {e}")
        raise  # or return default/empty based on business logic

# Usage
session = create_retry_session()
data = fetch_from_api(session, "https://api.example.com/data")
```

### 4. Data Validation Pythonically
```python
# NOT Pythonic - repetitive validation
def validate_user(user_data):
    if 'user_id' not in user_data:
        raise ValidationError("Missing user_id")
    if not isinstance(user_data['user_id'], str):
        raise ValidationError("user_id must be string")
    if len(user_data['user_id']) < 3:
        raise ValidationError("user_id too short")
    
    if 'email' not in user_data:
        raise ValidationError("Missing email")
    if not isinstance(user_data['email'], str):
        raise ValidationError("email must be string")
    if '@' not in user_data['email']:
        raise ValidationError("Invalid email format")
    
    # ... more validation

# Pythonic - declarative validation (using pydantic or similar)
from pydantic import BaseModel, Field, validator
from typing import Optional

class UserModel(BaseModel):
    user_id: str = Field(..., min_length=3)
    email: str
    age: Optional[int] = Field(None, ge=0, le=150)
    is_active: bool = True
    
    @validator('email')
    def validate_email_format(cls, v):
        if '@' not in v:
            raise ValueError('Invalid email format')
        return v

# Usage
try:
    user = UserModel(**user_data)
    # user is validated and typed
except ValidationError as e:
    logger.error(f"Validation failed: {e}")
    # Handle invalid data
```

### 5. Working with Dates and Time
```python
# NOT Pythonic - naive datetime, timezone issues
def process_timestamp(ts_string):
    dt = datetime.strptime(ts_string, "%Y-%m-%d %H:%M:%S")
    # ... processing without timezone awareness

# Pythonic - timezone aware, use dateutil or pendulum
from datetime import datetime
import pytz
# or: from dateutil import parser
# or: import pendulum

def process_timestamp(ts_string: str, timezone: str = 'UTC') -> datetime:
    # Parse with timezone awareness
    utc = pytz.UTC
    try:
        dt = datetime.strptime(ts_string, "%Y-%m-%d %H:%M:%S")
        # Assume UTC if no timezone specified
        dt = utc.localize(dt)
    except ValueError:
        # Try ISO format with timezone
        dt = parser.isoparse(ts_string)
    
    # Convert to target timezone
    target_tz = pytz.timezone(timezone)
    return dt.astimezone(target_tz)

# Even better - use pendulum for cleaner API
# import pendulum
# dt = pendulum.parse(ts_string).in_timezone(timezone)

# Working with date ranges
def date_range(start: datetime, end: datetime) -> Generator[datetime, None, None]:
    current = start
    while current <= end:
        yield current
        current += timedelta(days=1)

# Usage - memory efficient iterator
for date in date_range(start_date, end_date):
    process_daily_data(date)
```

### 6. Working with Files and Paths
```python
# NOT Pythonic - string manipulation, platform issues
def get_file_path(base_dir, filename):
    return base_dir + "/" + filename  # Breaks on Windows

def read_file_lines(filepath):
    f = open(filepath)
    lines = f.readlines()
    f.close()  # Forget to close on exception!
    return lines

# Pythonic - pathlib for cross-platform paths
from pathlib import Path

def get_file_path(base_dir: Path, filename: str) -> Path:
    return base_dir / filename  # Works on all platforms

def read_file_lines(filepath: Path) -> List[str]:
    with open(filepath, 'r', encoding='utf-8') as f:
        return f.readlines()  # Auto-closed

# Even better - iterate directly
def process_file_lines(filepath: Path) -> Generator[str, None, None]:
    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            yield line.rstrip('\\n')

# glob patterns
def find_json_files(directory: Path) -> List[Path]:
    return list(directory.glob("**/*.json"))

# rglob for recursive
def find_all_logs(directory: Path) -> List[Path]:
    return list(directory.rglob("*.log"))
```

---

## Anti-Patterns to Avoid

### 1. Over-Commenting Obvious Code
```python
# AVOID: Comments that repeat the code
x = x + 1  # Increment x by 1
if x > 10:  # If x is greater than 10
    y = 0   # Set y to zero

# PREFER: Clear variable names, comments for why not what
attempt_count = attempt_count + 1
if attempt_count > max_attempts:
    failure_count = 0  # Reset on max attempts exceeded
```

### 2. Magic Numbers and Strings
```python
# AVOID: Unexplained literals
if status == 4:
    retry_after(300)
    alert_team("ops")

# PREFER: Named constants
STATUS_PROCESSING_COMPLETE = 4
RETRY_DELAY_SECONDS = 300
ALERT_TEAM_OPS = "ops"

if status == STATUS_PROCESSING_COMPLETE:
    retry_after(RETRY_DELAY_SECONDS)
    alert_team(ALERT_TEAM_OPS)

# Or enums for related constants
from enum import IntEnum

class PipelineStatus(IntEnum):
    PENDING = 1
    RUNNING = 2
    COMPLETE = 3
    FAILED = 4
    RETRYING = 5

if status == PipelineStatus.COMPLETE:
    retry_after(5 * 60)  # 5 minutes
    alert_team("ops")
```

### 3. Overly Complex One-Liners
```python
# AVOID: Clever but unreadable
result = [(lambda x: x**2 if x%2==0 else x//2)(i) for i in data if i>0 and i<100 and i not in exclude_list]

# PREFER: Clear, step-by-step processing
def transform_value(x):
    if x % 2 == 0:
        return x**2
    else:
        return x//2

filtered = [x for x in data if 0 < x < 100 and x not in exclude_list]
result = [transform_value(x) for x in filtered]
```

### 4. Misusing Private Conventions
```python
# AVOID: Overusing underscores for "privacy" (Python doesn't have true privacy)
class DataProcessor:
    def __init__(self):
        self.__data = []  # Name mangling - rarely needed
        self._cache = {}  # Internal use convention
        
    def __process_item(self, item):  # Name mangling
        return item * 2
    
    def _validate_item(self, item):  # Convention: internal use
        return item is not None

# PREFER: Clear interface, document intent
class DataProcessor:
    def __init__(self):
        self.data = []      # Public attribute
        self._cache = {}    # Internal - treat as private
        
    def process_item(self, item):  # Public method
        """Process a single data item.
        
        Args:
            item: Input data item
            
        Returns:
            Processed item
            
        Note:
            Returns None for invalid items
        """
        if not self._validate_item(item):
            return None
        return item * 2
    
    def _validate_item(self, item):  # Internal helper
        """Validate item meets requirements.
        
        This is internal implementation detail.
        Do not call from outside this class.
        """
        return item is not None
```

### 5. Inheritance Overuse
```python
# AVOID: Deep inheritance hierarchies
class BaseETL:
    def run(self): pass

class DatabaseETL(BaseETL):
    def run(self): pass

class SalesDatabaseETL(DatabaseETL):
    def run(self): pass

class HourlySalesDatabaseETL(SalesDatabaseETL):
    def run(self): pass

# PREFER: Composition over inheritance
@dataclass
class ETLConfig:
    source_type: str
    schedule: str
    retry_policy: dict

class ETLProcessor:
    def __init__(self, config: ETLConfig, source, transformer, sink):
        self.config = config
        self.source = source
        self.transformer = transformer
        self.sink = sink
    
    def run(self):
        # Delegation instead of inheritance
        data = self.source.fetch()
        transformed = [self.transformer.transform(d) for d in data]
        self.sink.save(transformed)
```

### 6. Ignoring Python's Ecosystem
```python
# AVOID: Reinventing the wheel
def parse_csv(filepath):
    # Manual CSV parsing - error prone
    lines = open(filepath).readlines()
    header = lines[0].strip().split(',')
    data = []
    for line in lines[1:]:
        values = line.strip().split(',')
        row = dict(zip(header, values))
        data.append(row)
    return data

# PREFER: Use standard library and quality third-party packages
import csv
# or: import pandas as pd

def parse_csv(filepath):
    with open(filepath) as f:
        reader = csv.DictReader(f)
        return list(reader)

# Even better for analysis
def parse_csv_for_analysis(filepath):
    return pd.read_csv(filepath)  # Powerful DataFrame API
```

---

## Interview Angles for DE Roles

**Common Questions:**
1. "What makes code 'Pythonic' and why does it matter in data engineering?"
2. "Show me the difference between Pythonic and non-Pythonic ways to handle this common DE task."
3. "How do you decide between using a list comprehension vs map/filter?"
4. "What are some Python-specific features you leverage in DE pipelines?"
5. "How does EAFP differ from LBYL, and when do you use each?"
6. "What's wrong with this code from a Pythonic perspective?" (show anti-pattern)
7. "How do you make your DE code more testable and maintainable?"
8. "What Python tools or libraries do you consider essential for DE work?"

**Key Points to Mention:**
- Pythonic code improves readability, maintainability, and reduces bugs
- Leverages Python's unique features (context managers, comprehensions, unpacking, etc.)
- Follows community conventions (PEP 8, PEP 257 - docstrings)
- Emphasizes explicit over implicit, simple over complex
- Uses the right tool for the job (standard library, quality third-party packages)
- Considers performance but prioritizes clarity unless profiling shows bottleneck
- Makes effective use of Python's data model (protocols, properties, descriptors when appropriate)
- Values testability and dependency injection
- Respects the principle that "there should be one-- and preferably only one --obvious way to do it"

## Best Practices Summary

1. **Readability first** - Optimize for human understanding
2. **Follow PEP 8** - Use automated formatters (black, autopep8)
3. **Write clear docstrings** - Explain why, not what
4. **Use type hints** - Improve IDE support and catch errors
5. **Leverage standard library** - collections, itertools, functools, pathlib
6. **Prefer EAFP over LBYL** - More Pythonic and avoids race conditions
7. **Use context managers** - For reliable resource cleanup
8. **Favor composition over inheritance** - More flexible and testable
9. **Write small, focused functions** - Single responsibility principle
10. **Use generators for large datasets** - Memory efficiency
11. **Apply functional principles** - Pure functions, immutability where helpful
12. **Handle errors specifically** - Catch exact exceptions you can handle
13. **Log appropriately** - Use logging module, not print statements
14. **Test your code** - Unit tests for critical pipeline components
15. **Consider performance** - Profile before optimizing, use built-ins
16. **Stay current** - Python evolves, learn new features (match statement, etc.)
17. **Be consistent** - Team agreement on style improves collaboration
18. **Remember the Zen** - Let Python's principles guide your decisions