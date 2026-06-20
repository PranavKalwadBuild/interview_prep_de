<!-- python-patterns: Type Annotations -->

# Type Annotations in Python for Data Engineering

## Why Type Annotations Matter in DE

Type annotations improve code quality, catch bugs early, enhance IDE support, and make data pipelines more maintainable. In DE, where data shapes and schemas are complex and frequently changing, type hints serve as living documentation and contracts between pipeline components.

**Benefits:**
- Early bug detection (mypy, IDEs)
- Better autocomplete and refactoring tools
- Explicit data contracts between functions
- Reduced need for defensive type checking
- Improved onboarding for new team members
- Foundation for data validation frameworks (pydantic, etc.)

---

## Basic Type Annotations

### Variables and Function Signatures
```python
# Basic types
count: int = 42
ratio: float = 3.14
name: str = "pipeline"
is_active: bool = True
items: list = [1, 2, 3]  # Preferred: List[int] from typing

# From typing module (Python 3.8+ also supports built-in generics)
from typing import List, Dict, Set, Tuple, Optional

items: List[int] = [1, 2, 3]
mapping: Dict[str, int] = {'a': 1, 'b': 2}
unique_ids: Set[str] = {'user1', 'user2'}
coordinates: Tuple[float, float] = (40.7128, -74.0060)

# Optional values (None allowed)
def process_user(user_id: Optional[str] = None) -> bool:
    if user_id is None:
        return False
    # process user
    return True

# Function signatures
def transform_data(
    input_data: List[Dict[str, Any]],
    schema: Dict[str, Type]
) -> List[Dict[str, Any]]:
    """Transform raw data according to schema."""
    # implementation
    return processed_data
```

### Complex Types
```python
from typing import Union, Literal, Callable, Iterable, Generator

# Union - one of several types
def parse_input(data: Union[str, bytes, Path]) -> str:
    if isinstance(data, bytes):
        return data.decode('utf-8')
    elif isinstance(data, Path):
        return data.read_text()
    return data

# Literal - specific values
def process_status(status: Literal['pending', 'processing', 'completed', 'failed']) -> str:
    return f"Status: {status}"

# Callable - function types
def apply_transform(
    data: List[float],
    transformer: Callable[[float], float]
) -> List[float]:
    return [transformer(x) for x in data]

# Iterable vs Iterator
def process_lines(source: Iterable[str]) -> Generator[str, None, None]:
    for line in source:
        yield line.strip()

# Any - opt out of type checking (use sparingly)
def legacy_handler(data: Any) -> Result:
    # Unknown structure from external system
    return process_unknown_format(data)
```

---

## Advanced Typing Features

### Type Aliases
```python
# Improve readability of complex types
from typing import Dict, List, Tuple, Optional

UserId = str
Timestamp = float
Coordinates = Tuple[float, float]
EventRecord = Dict[str, Any]
PipelineConfig = Dict[str, Union[str, int, bool, List[str]]]

def process_events(
    events: List[EventRecord],
    config: PipelineConfig
) -> Dict[UserId, List[Tuple[Timestamp, Coordinates]]]:
    # implementation
    pass
```

### NewType - Distinct Types
```python
from typing import NewType

UserId = NewType('UserId', str)
SessionId = NewType('SessionId', str)
ApiKey = NewType('ApiKey', str)

def create_session(user_id: UserId, api_key: ApiKey) -> SessionId:
    # TypeError if you accidentally swap args
    # SessionId("abc123")  # Still works but provides semantic meaning
    return SessionId(f"{user_id}:{api_key}")

# Benefits:
# - Prevents parameter mix-ups
# - Self-documenting code
# - Zero runtime overhead (erased at runtime)
```

### TypedDict - Structured Dictionaries
```python
from typing import TypedDict, NotRequired

class UserProfile(TypedDict):
    user_id: str
    email: str
    age: NotRequired[int]  # Optional field
    is_premium: bool
    tags: List[str]

def update_profile(profile: UserProfile, updates: Dict[str, Any]) -> UserProfile:
    # Type checker knows expected structure
    profile.update(updates)
    return profile

# Usage
user: UserProfile = {
    'user_id': 'u123',
    'email': 'user@example.com',
    'is_premium': True,
    'tags': ['beta', 'early-adopter']
}
```

### Protocol - Structural Typing (Duck Typing)
```python
from typing import Protocol, runtime_checkable

@runtime_checkable
class Serializable(Protocol):
    def serialize(self) -> bytes: ...
    @classmethod
    def deserialize(cls, data: bytes) -> Self: ...

def save_to_cache(item: Serializable, key: str) -> None:
    # Accepts any object with serialize/deserialize methods
    # No inheritance required - structural typing
    cache.set(key, item.serialize())

class UserModel:
    def serialize(self) -> bytes:
        return json.dumps(self.__dict__).encode()
    
    @classmethod
    def deserialize(cls, data: bytes) -> 'Self':
        return cls(**json.loads(data))

# Works with UserModel despite no inheritance from Serializable
save_to_cache(UserModel(...), "user:123")
```

### Generics - Type Variables
```python
from typing import TypeVar, Generic, List

T = TypeVar('T')  # Generic type variable
U = TypeVar('U', int, float)  # Bounded type variable

def first_element(items: List[T]) -> T:
    return items[0]

def convert_and_store(
    data: List[U],
    converter: Callable[[U], T],
    storage: List[T]
) -> None:
    storage.extend(converter(x) for x in data)

# Usage
numbers: List[int] = [1, 2, 3]
strings: List[str] = []
convert_and_store(numbers, str, strings)  # T=str, U=int

# Multiple TypeVars
K = TypeVar('K')
V = TypeVar('V')

def merge_dicts(
    dict1: Dict[K, V],
    dict2: Dict[K, V]
) -> Dict[K, V]:
    result = dict1.copy()
    result.update(dict2)
    return result
```

---

## Practical DE Examples

### 1. Pipeline Stage Definitions
```python
from typing import Protocol, Generic, TypeVar, List, Dict, Any, Callable
from dataclasses import dataclass

T = TypeVar('T')
U = TypeVar('U')

class Stage(Protocol[T, U]):
    def process(self, data: T) -> U: ...
    def validate(self, data: T) -> bool: ...

@dataclass
class BatchPipeline(Generic[T, U]):
    stages: List[Stage[T, U]]
    
    def run(self, data: T) -> U:
        current = data
        for stage in self.stages:
            if not stage.validate(current):
                raise ValidationError(f"Stage {stage.__class__.__name__} failed validation")
            current = stage.process(current)
        return current

# Usage
class JsonParser(Stage[str, Dict[str, Any]]):
    def process(self, data: str) -> Dict[str, Any]:
        return json.loads(data)
    
    def validate(self, data: str) -> bool:
        try:
            json.loads(data)
            return True
        except json.JSONDecodeError:
            return False

class DataValidator(Stage[Dict[str, Any], Dict[str, Any]]):
    def process(self, data: Dict[str, Any]) -> Dict[str, Any]:
        # validation and cleaning logic
        return {k: v for k, v in data.items() if v is not None}
    
    def validate(self, data: Dict[str, Any]) -> bool:
        return 'id' in data and 'timestamp' in data

pipeline = BatchPipeline(
    stages=[JsonParser(), DataValidator()]
)
result: Dict[str, Any] = pipeline.run(raw_json_string)
```

### 2. Configuration with Type Safety
```python
from typing import TypedDict, NotRequired, Literal
from pathlib import Path

class DatabaseConfig(TypedDict):
    host: str
    port: int
    database: str
    username: str
    password: NotRequired[str]  # May come from secrets manager
    ssl: NotRequired[bool]

class PipelineConfig(TypedDict):
    name: str
    version: str
    schedule: Literal['hourly', 'daily', 'weekly', 'monthly']
    timeout_seconds: int
    retries: int
    database: DatabaseConfig
    notification_emails: NotRequired[List[str]]
    tags: NotRequired[Dict[str, str]]

def load_config(config_path: Path) -> PipelineConfig:
    with open(config_path) as f:
        raw_config = yaml.safe_load(f)
    # Type checker validates structure matches PipelineConfig
    return raw_config  # type: ignore[return-value]  # In practice, use pydantic or similar
```

### 3. Data Validation Functions
```python
from typing import TypeGuard, List, Dict, Any, Union

def is_valid_user_record(record: Dict[str, Any]) -> TypeGuard[Dict[str, str | int | bool]]:
    """Type guard that narrows type when returns True"""
    required_fields = {'user_id': str, 'email': str, 'age': int, 'is_active': bool}
    
    if not isinstance(record, dict):
        return False
    
    for field, expected_type in required_fields.items():
        if field not in record:
            return False
        if not isinstance(record[field], expected_type):
            return False
    
    return True

def process_user_batch(records: List[Dict[str, Any]]) -> List[Dict[str, str | int | bool]]:
    valid_users = []
    for record in records:
        if is_valid_user_record(record):  # After this, record is narrowed to specific type
            # Type checker knows record has specific structure
            valid_users.append({
                'user_id': record['user_id'].strip(),
                'email': record['email'].lower(),
                'age': record['age'],
                'is_active': record['is_active']
            })
    return valid_users
```

### 4. Generator and Iterator Patterns
```python
from typing import Generator, Iterator, Iterable

def read_csv_in_chunks(
    file_path: Path,
    chunk_size: int = 1000
) -> Iterator[List[Dict[str, str]]]:
    """Lazy generator that yields chunks of CSV data"""
    with open(file_path, newline='') as csvfile:
        reader = csv.DictReader(csvfile)
        chunk = []
        for row in reader:
            chunk.append(row)
            if len(chunk) >= chunk_size:
                yield chunk
                chunk = []
        if chunk:  # Yield remaining records
            yield chunk

def process_data_pipeline(
    source: Iterable[str]
) -> Generator[Dict[str, Any], None, None]:
    """Pipeline: read → parse → validate → transform → yield"""
    for line in source:
        try:
            parsed = json.loads(line)
            if validate_record(parsed):
                yield transform_record(parsed)
        except (json.JSONDecodeError, ValidationError):
            # Log and skip invalid records
            continue
```

---

## Type Checking Tools and Configuration

### mypy Setup
```ini
# mypy.ini
[mypy]
python_version = 3.9
warn_return_any = True
warn_unused_configs = True
disallow_untyped_defs = True
disallow_incomplete_defs = True
check_untyped_defs = True
disallow_untyped_decorators = True
warn_redundant_casts = True
warn_unused_ignores = True
warn_return_none = True
no_implicit_optional = True
strict_equality = True
```

### Common mypy Flags
```bash
# Basic checking
mypy your_module.py

# Strict mode (recommended for DE)
mypy --strict your_module.py

# Follow imports (check installed packages too)
mypy --follow-imports=silent your_module.py

# Ignore missing imports (for dynamic loading)
mypy --ignore-missing-imports your_module.py

# Show error codes
mypy --show-error-codes your_module.py
```

### # type: ignore Comments
```python
# Use sparingly and with justification
def risky_operation(data: Any) -> Result:
    # type: ignore[no-untyped-def]  # Legacy function, gradual typing
    # type: ignore[attr-defined]    # Dynamic attribute access
    # type: ignore[assignment]      # Known type mismatch in legacy code
    return process_legacy_data(data)

# Better: isolate untyped code
from typing import TYPE_CHECKING
if TYPE_CHECKING:
    from legacy_module import process_legacy_data  # Only for type checking

def safe_wrapper(data: Dict[str, Any]) -> Result:
    # Implementation using properly typed interface
    return moden_processor.process(data)
```

---

## Gotchas and Best Practices

### 1. Mutable Default Arguments
```python
# BAD: Shared mutable default
def process_items(items: List[str] = []) -> List[str]:  # Same list reused!
    items.append("processed")
    return items

# GOOD: None default + initialization
def process_items(items: List[str] = None) -> List[str]:
    if items is None:
        items = []
    items.append("processed")
    return items

# EVEN BETTER: Explicit factory
def process_items(items: List[str] | None = None) -> List[str]:
    items = items or []  # Creates new list each time
    items.append("processed")
    return items
```

### 2. Inheritance and Subtyping
```python
from typing import List

# Liskov Substitution Principle violations
class Bird:
    def fly(self) -> None: ...

class Penguin(Bird):  # Penguins can't fly!
    def fly(self) -> None:
        raise CannotFlyError("Penguins cannot fly")

# Type checker may not catch this - behavioral subtyping matters
def make_it_fly(bird: Bird) -> None:
    bird.fly()  # Fails with Penguin!

# Better: Separate interfaces
from typing import Protocol

class Flyable(Protocol):
    def fly(self) -> None: ...

class Bird(Protocol):
    def lay_egg(self) -> None: ...

def make_it_fly(flyable: Flyable) -> None:
    flyable.fly()  # Only accept truly flyable things
```

### 3. Circular Imports
```python
# models.py
from typing import TYPE_CHECKING
from .database import Base  # Actual import

if TYPE_CHECKING:
    from .users import User  # Only for type checking

class Post(Base):
    # TYPE_CHECKING prevents circular import at runtime
    author_id: Column(Integer, ForeignKey('users.id'))
    author: relationship("User", back_populates="posts")  # String reference

# users.py
from typing import TYPE_CHECKING
from .database import Base
from .posts import Post  # Actual import - but we use string ref above

if TYPE_CHECKING:
    from .posts import Post  # Only for type checking

class User(Base):
    posts: relationship("Post", back_populates="author")  # String reference
```

### 4. Type Aliases vs NewType
```python
# Type Alias - just documentation, no type safety
UserId = str
def get_user(id: UserId) -> User: ...
# get_user("123")  # OK
# get_user(123)    # Also OK - no type safety!

# NewType - actual type distinction
from typing import NewType
UserId = NewType('UserId', str)
def get_user(id: UserId) -> User: ...
# get_user(UserId("123"))  # OK
# get_user("123")          # TypeError!
# get_user(123)            # TypeError!
```

### 5. Runtime Behavior
```python
import typing

# Annotations are available at runtime
def func(x: int, y: str) -> bool:
    return len(y) > x

print(func.__annotations__)
# {'x': <class 'int>, 'y': <class 'str>, 'return': <class 'bool'>}

# But they don't affect runtime behavior
def add(x: int, y: int) -> int:
    return x + y

print(add("2", "3"))  # "23" - concatenation, not addition!
# Type checkers would catch this, but Python runtime doesn't enforce
```

---

## Testing and Type Annotations

### 1. Testing Typed Functions
```python
def calculate_tax(amount: float, rate: float) -> float:
    return amount * (1 + rate)

def test_calculate_tax():
    # Test with correct types
    assert calculate_tax(100.0, 0.08) == 108.0
    
    # Test edge cases
    assert calculate_tax(0.0, 0.08) == 0.0
    assert calculate_tax(100.0, 0.0) == 100.0
    
    # Type checker would prevent these, but tests should still validate behavior
    # Though in practice, incorrect types would be caught by type checker first
```

### 2. Property-Based Testing with Types
```python
from hypothesis import given, strategies as st

@given(
    amount=st.floats(min_value=0, max_value=1000000),
    rate=st.floats(min_value=0, max_value=1)
)
def test_tax_non_negative(amount: float, rate: float) -> None:
    result = calculate_tax(amount, rate)
    assert result >= 0
    assert result >= amount  # Tax should not reduce amount
```

### 3. Testing Type Guards
```python
def test_is_valid_user():
    valid_record = {
        'user_id': 'u123',
        'email': 'test@example.com',
        'age': 25,
        'is_active': True
    }
    assert is_valid_user_record(valid_record) is True
    
    invalid_cases = [
        {},  # Missing fields
        {'user_id': 'u123'},  # Missing email, age, is_active
        {'user_id': 123, 'email': 'test@example.com', 'age': 25, 'is_active': True},  # Wrong type
        {'user_id': 'u123', 'email': 'test@example.com', 'age': 'twenty-five', 'is_active': True},  # Wrong type
    ]
    
    for record in invalid_cases:
        assert is_valid_user_record(record) is False
```

---

## Migration Strategies for Existing Code

### 1. Gradual Typing Approach
```bash
# Start with most critical modules
mypy --follow-imports=silent --disallow-untyped-defs critical_module.py

# Then expand
mypy --follow-imports=silent --disallow-untyped-defs module_a.py module_b.py

# Eventually enforce everywhere
mypy --strict .
```

### 2. Use # type: ignore Temporarily
```python
# In legacy module
def old_function(data):  # type: ignore[no-untyped-def]
    # Process data without types
    return transform_data(data)

# In new typed module
def new_function(data: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    result = old_function(data)  # type: ignore[no-untyped-call]
    return result
```

### 3. Provide Stubs for External Libraries
```python
# Create stubs/ or use typeshed
# For poorly typed libraries, create your own stub files
# legacy_lib.pyi
from typing import Any

def legacy_function(data: Any) -> Any: ...

# Now you can import and get basic type checking
```

### 4. Use Pyright or Other Tools
```bash
# Pyright (Microsoft) - often faster than mypy
pyright your_project/

# Pyre (Facebook) - for large codebases
pyre check
```

---

## Interview Angles for DE Roles

**Common Questions:**
1. "How would you add type hints to this poorly typed function?"
2. "What's the difference between `List` and `list` in type annotations?"
3. "When would you use `TypeVar` vs `Union`?"
4. "How do you handle typing for JSON data that comes from external APIs?"
5. "What are `TypedDict` and `Protocol` used for in data engineering?"
6. "How do type annotations help with testing and debugging?"
7. "What's the difference between `isinstance()` checks and type annotations?"
8. "When would you use `NewType` vs a simple type alias?"

**Key Points to Mention:**
- Type annotations are static - checked by tools like mypy, not enforced at runtime
- They serve as executable documentation and contracts
- Gradual typing allows adopting types incrementally
- Complex data structures benefit significantly from TypedDict and NewType
- Type guards (`TypeGuard`) enable powerful type narrowing
- Protocol enables structural typing (duck typing) with type safety
- Annotations improve IDE experience and reduce bugs in data pipelines
- In DE, focus on typing data structures, function signatures, and configuration

## Best Practices for Data Engineering

1. **Start with function signatures** - annotate inputs and outputs first
2. **Use TypedDict for JSON/API data** - defines expected structure
3. **Apply NewType for IDs** - prevent mixing up user_id, session_id, etc.
4. **Annotate configuration objects** - catch config errors early
5. **Use TypeGuard for validation functions** - enable type narrowing
6. **Leverage Protocol for dependency injection** - define interfaces without inheritance
7. **Annotate generators and iterators** - specify yielded types
8. **Use TypeVar for generic components** - reusable pipeline stages
9. **Run mypy in CI/CD** - catch type errors before deployment
10. **Document complex types with comments** - explain business meaning
11. **Consider runtime validation** for external data (pydantic, etc.)
12. **Be consistent** - team-wide adoption improves effectiveness
13. **Start strict, relax as needed** - easier to loosen than tighten later
14. **Use pyproject.toml or setup.cfg** for mypy configuration
15. **Remember: annotations don't replace testing** - they complement it