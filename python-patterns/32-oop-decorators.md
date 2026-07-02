<!-- python-patterns: OOP-Related Built-in Decorators in Python -->

# OOP-Related Built-in Decorators in Python

## Why Decorators Matter in OOP
Decorators modify or enhance class methods without changing their core implementation. Python provides several built-in decorators specifically designed for object-oriented programming that enable clean, readable, and maintainable code.

## @staticmethod
### Purpose
Defines a method that belongs to the class but doesn't operate on instance or class data. It's essentially a function grouped inside a class for organizational purposes.

### Characteristics
- No automatic `self` or `cls` parameter
- Cannot access or modify instance state (`self`) or class state (`cls`)
- Behaves like a regular function but is scoped within the class
- Can be called on the class or an instance

### Syntax
```python
class MathUtils:
    @staticmethod
    def factorial
    @staticmethod
    def factorial(n):
        """Calculate factorial of n."""
        if n < 0:
            raise ValueError("Factorial is not defined for negative numbers")
        if n == 0 or n == 1:
            return 1
        return n * MathUtils.factorial(n - 1)
    
    @staticmethod
    def is_prime(n):
        """Check if a number is prime."""
        if n < 2:
            return False
        for i in range(2, int(n**0.5) + 1):
            if n % i == 0:
                return False
        return True
```

### Usage
```python
# Called on class
result = MathUtils.factorial(5)  # 120

# Called on instance (though not recommended)
utils = MathUtils()
result = utils.is_prime(13)  # True
```

### When to Use
- Utility functions that don't need access to instance or class state
- Helper methods that are logically related to the class
- Factory-like functions (though `@classmethod` is often better for factories)
- When you want to group related functions under a class namespace

### Data Engineering Examples
```python
class DataUtils:
    @staticmethod
    def sanitize_column_name(name):
        """Convert column name to snake_case."""
        import re
        # Replace spaces and special characters with underscores
        name = re.sub(r'[^a-zA-Z0-9]+', '_', name)
        # Remove leading/trailing underscores
        name = name.strip('_')
        # Convert to lowercase
        return name.lower()
    
    @staticmethod
    def parse_json_safely(json_string, default=None):
        """Parse JSON string, returning default on failure."""
        import json
        try:
            return json.loads(json_string)
        except (json.JSONDecodeError, TypeError):
            return default
```

## @classmethod
### Purpose
Defines a method that receives the class (`cls`) as its first argument, allowing it to operate on the class itself rather than instances.

### Characteristics
- First parameter is conventionally named `cls`
- Can access and modify class state
- Can be overridden in subclasses (polymorphic)
- Often used for alternative constructors (factory methods)
- Can be called on the class or an instance

### Syntax
```python
class DatabaseConnection:
    def __init__(self, host, port, database):
        self.host = host
        self.port = port
        self.database = database
    
    @classmethod
    def from_url(cls, url):
        """Create connection from database URL."""
        # Parse URL and extract components
        # Simplified example
        return cls("localhost", 5432, "mydb")
    
    @classmethod
    def from_environment(cls):
        """Create connection from environment variables."""
        import os
        host = os.getenv("DB_HOST", "localhost")
        port = int(os.getenv("DB_PORT", 5432))
        database = os.getenv("DB_NAME", "default")
        return cls(host, port, database)
    
    def connect(self):
        """Establish database connection."""
        # Implementation here
        pass
```

### Usage
```python
# Alternative constructors
conn1 = DatabaseConnection.from_url("postgresql://localhost/mydb")
conn2 = DatabaseConnection.from_environment()
```

### When to Use
- Alternative constructors (different ways to create instances)
- Methods that need to modify class state
- Factory patterns
- When you need polymorphism (subclass can override and still receive its own class)
- When working with class-level data

### Data Engineering Examples
```python
class ETLConfig:
    _defaults = {
        'batch_size': 1000,
        'timeout': 300,
        'retries': 3
    }
    
    def __init__(self, **kwargs):
        self.settings = self._defaults.copy()
        self.settings.update(kwargs)
    
    @classmethod
    def from_dict(cls, config_dict):
        """Create config from dictionary."""
        return cls(**config_dict)
    
    @classmethod
    def from_file(cls, filepath):
        """Load config from JSON/YAML file."""
        import json
        with open(filepath, 'r') as f:
            config = json.load(f)
        return cls(**config)
    
    @classmethod
    def get_default(cls):
        """Get default configuration."""
        return cls()
    
    def update(self, **kwargs):
        """Update configuration settings."""
        self.settings.update(kwargs)

class DataSourceRegistry:
    _sources = {}
    
    @classmethod
    def register(cls, name, source_class):
        """Register a new data source type."""
        cls._sources[name] = source_class
    
    @classmethod
    def get_source(cls, name):
        """Retrieve a registered data source class."""
        return cls._sources.get(name)
    
    @classmethod
    def list_sources(cls):
        """List all registered data source names."""
        return list(cls._sources.keys())
```

## @property
### Purpose
Defines a method that can be accessed like an attribute (without parentheses), enabling computed attributes, validation, and encapsulation.

### Characteristics
- Appears as an attribute when accessed
- Underlying method called automatically (getter)
- Can be combined with setter and deleter
- Enables lazy computation, validation, and computed properties
- Maintains encapsulation while providing attribute-like access

### Syntax
```python
class Circle:
    def __init__(self, radius):
        self._radius = radius  # Private storage
    
    @property
    def radius(self):
        """Get the radius of the circle."""
        return self._radius
    
    @radius.setter
    def radius(self, value):
        """Set the radius with validation."""
        if not isinstance(value, (int, float)):
            raise TypeError("Radius must be a number")
        if value < 0:
            raise ValueError("Radius cannot be negative")
        self._radius = float(value)
    
    @property
    def diameter(self):
        """Compute and return the diameter."""
        return self._radius * 2
    
    @property
    def area(self):
        """Compute and return the area (read-only)."""
        return 3.14159 * self._radius ** 2
```

### Usage
```python
c = Circle(5)
print(c.radius)   # 5.0 (getter)
c.radius = 10     # setter
print(c.diameter) # 20.0 (computed)
print(c.area)     # 314.159... (computed)
# c.area = 100    # AttributeError: can't set attribute
```

### When to Use
- Computed values that depend on other attributes
- Need to validate attribute values
- Want to compute expensive values lazily
- Maintaining backward compatibility when changing implementation
- Creating read-only attributes
- Implementing properties with side effects (logging, caching)

### Data Engineering Examples
```python
class DataFrameWrapper:
    def __init__(self, df):
        self._df = df
        self._null_counts = None  # Cache for expensive computation
    
    @property
    def shape(self):
        """Get dataframe dimensions."""
        return self._df.shape
    
    @property
    def columns(self):
        """Get column names."""
        return list(self._df.columns)
    
    @property
    def dtypes(self):
        """Get column data types."""
        return self._df.dtypes.to_dict()
    
    @property
    def null_counts(self):
        """Lazy-computed null counts per column."""
        if self._null_counts is None:
            self._null_counts = self._df.isnull().sum().to_dict()
        return self._null_counts
    
    @property
    def memory_usage(self):
        """Memory usage in bytes."""
        return self._df.memory_usage(deep=True).sum()
    
    @property
    def is_empty(self):
        """Check if dataframe is empty."""
        return len(self._df) == 0

class DatabaseTable:
    def __init__(self, name, schema=None):
        self._name = name
        self._schema = schema or {}
        self._row_count = None
    
    @property
    def name(self):
        """Table name (read-only)."""
        return self._name
    
    @property
    def schema(self):
        """Table schema (read-only)."""
        return self._schema.copy()
    
    @property
    def qualified_name(self):
        """Fully qualified table name."""
        if '.' in self._name:
            return self._name
        # Assume default schema if not provided
        return f"public.{self._name}"
    
    @property
    def row_count(self):
        """Cached row count (expensive to compute)."""
        if self._row_count is None:
            # In real implementation, would query database
            self._row_count = self._fetch_row_count()
        return self._row_count
    
    def _fetch_row_count(self):
        """Simulate expensive database query."""
        # Actual implementation would execute COUNT(*) query
        return 1000000
```

## Combining Decorators
You can combine these decorators with each other and with custom decorators:

```python
class DataProcessor:
    _registry = {}
    
    @classmethod
    def register_processor(cls, name):
        """Class method decorator to register processors."""
        def decorator(func):
            cls._registry[name] = func
            return func
        return decorator
    
    @staticmethod
    def validate_data(data):
        """Static method for data validation."""
        if not isinstance(data, list):
            raise TypeError("Data must be a list")
        return True
    
    @property
    def available_processors(self):
        """Property that returns list of registered processors."""
        return list(self.__class__._registry.keys())
```

## Other Notable Decorators
While not strictly OOP-specific, these are commonly used in classes:

### `@property` with setter and deleter
```python
class Temperature:
    def __init__(self, celsius=0):
        self._celsius = celsius
    
    @property
    def celsius(self):
        return self._celsius
    
    @celsius.setter
    def celsius(self, value):
        if value < -273.15:
            raise ValueError("Temperature below absolute zero")
        self._celsius = float(value)
    
    @celsius.deleter
    def celsius(self):
        """Reset to absolute zero."""
        self._celsius = -273.15
    
    @property
    def fahrenheit(self):
        """Read-only conversion to Fahrenheit."""
        return self._celsius * 9/5 + 32
```

### `@abstractmethod` (from abc module)
```python
from abc import ABC, abstractmethod

class Extractor(ABC):
    @abstractmethod
    def extract(self, source):
        """Extract data from source. Must be implemented by subclasses."""
        pass
    
    @abstractmethod
    def validate(self, data):
        """Validate extracted data. Must be implemented by subclasses."""
        pass

class CSVExtractor(Extractor):
    def extract(self, source):
        # Implementation
        pass
    
    def validate(self, data):
        # Implementation
        pass
```

## Best Practices
1. **Use `@staticmethod` for true utility functions**: When the method doesn't need access to `self` or `cls`.
2. **Use `@classmethod` for alternative constructors**: When you need to create instances in different ways.
3. **Use `@property` for computed attributes**: When you need to compute values on access or validate assignments.
4. **Keep property getters side-effect free**: Getters should be idempotent and inexpensive.
5. **Document properties clearly**: Indicate whether they're computed, cached, or have side effects.
6. **Avoid overusing properties**: Simple attributes don't need properties.
7. **Consider performance**: Properties are called every access; cache expensive computations.
8. **Use private attributes for storage**: Conventionally prefix with `_` to indicate internal storage.

## Common Gotchas
1. **Forgetting `@property` setter**: Makes attribute read-only only.
2. **Mutating mutable objects in properties**: Return copies if mutation should be prevented.
3. **Infinite recursion in properties**: Accidentally referencing the property itself in getter/setter.
4. **Property shadowing**: Defining a property with same name as method in parent class.
5. **Thread safety**: Properties aren't inherently thread-safe; consider locks for shared state.
6. **Pickling issues**: Some properties may not pickle correctly if they rely on transient state.

## When Not to Use
- Simple data storage (use regular attributes)
- Methods that perform actions (use regular methods)
- When the computation has side effects that shouldn't happen on every access
- When you need to pass additional parameters (consider methods instead)

## Data Engineering Patterns Summary
| Purpose | Typical Use |
|----------|---------|-------|
osate
    |
    |
    |
    5a|----|------|------|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@@    |@@@|
    |@@@ |@@@  |@@@  |@@0    |@@@|

Wait, the ASCII art messed up. Let me just provide the content without the table formatting issues.

Actually, I'll rewrite the table properly:

```markdown
| Decorator | First Parameter | Access to | Typical Use Cases |
|-----------|-----------------|-----------|-------------------|
| `@staticmethod` | None | Neither instance nor class | Utility functions, helper methods |
| `@classmethod` | `cls` (the class) | Class state, can create instances | Alternative constructors, factory methods |
| `@property` | `self` (implicit) | Instance state | Computed attributes, validation, lazy computation |
```

Now I'll finish writing the file with correct<tool_call>
<function=Write>
<parameter=content>
# OOP-Related Built-in Decorators in Python

## Why Decorators Matter in OOP
Decorators modify or enhance class methods without changing their core implementation. Python provides several built-in decorators specifically designed for object-oriented programming that enable clean, readable, and maintainable code.

## @staticmethod
### Purpose
Defines a method that belongs to the class but doesn't operate on instance or class data. It's essentially a function grouped inside a class for organizational purposes.

### Characteristics
- No automatic `self` or `cls` parameter
- Cannot access or modify instance state (`self`) or class state (`cls`)
- Behaves like a regular function but is scoped within the class
- Can be called on the class or an instance

### Syntax
```python
class MathUtils:
    @staticmethod
    def factorial(n):
        """Calculate factorial of n."""
        if n < 0:
            raise ValueError("Factorial is not defined for negative numbers")
        if n == 0 or n == 1:
            return 1
        return n * MathUtils.factorial(n - 1)
    
    @staticmethod
    def is_prime(n):
        """Check if a number is prime."""
        if n < 2:
            return False
        for i in range(2, int(n**0.5) + 1):
            if n % i == 0:
                return False
        return True
```

### Usage
```python
# Called on class
result = MathUtils.factorial(5)  # 120

# Called on instance (though not recommended)
utils = MathUtils()
result = utils.is_prime(13)  # True
```

### When to Use
- Utility functions that don't need access to instance or class state
- Helper methods that are logically related to the class
- Factory-like functions (though `@classmethod` is often better for factories)
- When you want to group related functions under a class namespace

### Data Engineering Examples
```python
class DataUtils:
    @staticmethod
    def sanitize_column_name(name):
        """Convert column name to snake_case."""
        import re
        # Replace spaces and special characters with underscores
        name = re.sub(r'[^a-zA-Z0-9]+', '_', name)
        # Remove leading/trailing underscores
        name = name.strip('_')
        # Convert to lowercase
        return name.lower()
    
    @staticmethod
    def parse_json_safely(json_string, default=None):
        """Parse JSON string, returning default on failure."""
        import json
        try:
            return json.loads(json_string)
        except (json.JSONDecodeError, TypeError):
            return default
```

## @classmethod
### Purpose
Defines a method that receives the class (`cls`) as its first argument, allowing it to operate on the class itself rather than instances.

### Characteristics
- First parameter is conventionally named `cls`
- Can access and modify class state
- Can be overridden in subclasses (polymorphic)
- Often used for alternative constructors (factory methods)
- Can be called on the class or an instance

### Syntax
```python
class DatabaseConnection:
    def __init__(self, host, port, database):
        self.host = host
        self.port = port
        self.database = database
    
    @classmethod
    def from_url(cls, url):
        """Create connection from database URL."""
        # Parse URL and extract components
        # Simplified example
        return cls("localhost", 5432, "mydb")
    
    @classmethod
    def from_environment(cls):
        """Create connection from environment variables."""
        import os
        host = os.getenv("DB_HOST", "localhost")
        port = int(os.getenv("DB_PORT", 5432))
        database = os.getenv("DB_NAME", "default")
        return cls(host, port, database)
    
    def connect(self):
        """Establish database connection."""
        # Implementation here
        pass
```

### Usage
```python
# Alternative constructors
conn1 = DatabaseConnection.from_url("postgresql://localhost/mydb")
conn2 = DatabaseConnection.from_environment()
```

### When to Use
- Alternative constructors (different ways to create instances)
- Methods that need to modify class state
- Factory patterns
- When you need polymorphism (subclass can override and still receive its own class)
- When working with class-level data

### Data Engineering Examples
```python
class ETLConfig:
    _defaults = {
        'batch_size': 1000,
        'timeout': 300,
        'retries': 3
    }
    
    def __init__(self, **kwargs):
        self.settings = self._defaults.copy()
        self.settings.update(kwargs)
    
    @classmethod
    def from_dict(cls, config_dict):
        """Create config from dictionary."""
        return cls(**config_dict)
    
    @classmethod
    def from_file(cls, filepath):
        """Load config from JSON/YAML file."""
        import json
        with open(filepath, 'r') as f:
            config = json.load(f)
        return cls(**config)
    
    @classmethod
    def get_default(cls):
        """Get default configuration."""
        return cls()
    
    def update(self, **kwargs):
        """Update configuration settings."""
        self.settings.update(kwargs)

class DataSourceRegistry:
    _sources = {}
    
    @classmethod
    def register(cls, name, source_class):
        """Register a new data source type."""
        cls._sources[name] = source_class
    
    @classmethod
    def get_source(cls, name):
        """Retrieve a registered data source class."""
        return cls._sources.get(name)
    
    @classmethod
    def list_sources(cls):
        """List all registered data source names."""
        return list(cls._sources.keys())
```

## @property
### Purpose
Defines a method that can be accessed like an attribute (without parentheses), enabling computed attributes, validation, and encapsulation.

### Characteristics
- Appears as an attribute when accessed
- Underlying method called automatically (getter)
- Can be combined with setter and deleter
- Enables lazy computation, validation, and computed properties
- Maintains encapsulation while providing attribute-like access

### Syntax
```python
class Circle:
    def __init__(self, radius):
        self._radius = radius  # Private storage
    
    @property
    def radius(self):
        """Get the radius of the circle."""
        return self._radius
    
    @radius.setter
    def radius(self, value):
        """Set the radius with validation."""
        if not isinstance(value, (int, float)):
            raise TypeError("Radius must be a number")
        if value < 0:
            raise ValueError("Radius cannot be negative")
        self._radius = float(value)
    
    @property
    def diameter(self):
        """Compute and return the diameter."""
        return self._radius * 2
    
    @property
    def area(self):
        """Compute and return the area (read-only)."""
        return 3.14159 * self._radius ** 2
```

### Usage
```python
c = Circle(5)
print(c.radius)   # 5.0 (getter)
c.radius = 10     # setter
print(c.diameter) # 20.0 (computed)
print(c.area)     # 314.159... (computed)
# c.area = 100    # AttributeError: can't set attribute
```

### When to Use
- Computed values that depend on other attributes
- Need to validate attribute values
- Want to compute expensive values lazily
- Maintaining backward compatibility when changing implementation
- Creating read-only attributes
- Implementing properties with side effects (logging, caching)

### Data Engineering Examples
```python
class DataFrameWrapper:
    def __init__(self, df):
        self._df = df
        self._null_counts = None  # Cache for expensive computation
    
    @property
    def shape(self):
        """Get dataframe dimensions."""
        return self._df.shape
    
    @property
    def columns(self):
        """Get column names."""
        return list(self._df.columns)
    
    @property
    def dtypes(self):
        """Get column data types."""
        return self._df.dtypes.to_dict()
    
    @property
    def null_counts(self):
        """Lazy-computed null counts per column."""
        if self._null_counts is None:
            self._null_counts = self._df.isnull().sum().to_dict()
        return self._null_counts
    
    @property
    def memory_usage(self):
        """Memory usage in bytes."""
        return self._df.memory_usage(deep=True).sum()
    
    @property
    def is_empty(self):
        """Check if dataframe is empty."""
        return len(self._df) == 0

class DatabaseTable:
    def __init__(self, name, schema=None):
        self._name = name
        self._schema = schema or {}
        self._row_count = None
    
    @property
    def name(self):
        """Table name (read-only)."""
        return self._name
    
    @property
    def schema(self):
        """Table schema (read-only)."""
        return self._schema.copy()
    
    @property
    def qualified_name(self):
        """Fully qualified table name."""
        if '.' in self._name:
            return self._name
        # Assume default schema if not provided
        return f"public.{self._name}"
    
    @property
    def row_count(self):
        """Cached row count (expensive to compute)."""
        if self._row_count is None:
            # In real implementation, would query database
            self._row_count = self._fetch_row_count()
        return self._row_count
    
    def _fetch_row_count(self):
        """Simulate expensive database query."""
        # Actual implementation would execute COUNT(*) query
        return 1000000
```

## Combining Decorators
You can combine these decorators with each other and with custom decorators:

```python
class DataProcessor:
    _registry = {}
    
    @classmethod
    def register_processor(cls, name):
        """Class method decorator to register processors."""
        def decorator(func):
            cls._registry[name] = func
            return func
        return decorator
    
    @staticmethod
    def validate_data(data):
        """Static method for data validation."""
        if not isinstance(data, list):
            raise TypeError("Data must be a list")
        return True
    
    @property
    def available_processors(self):
        """Property that returns list of registered processors."""
        return list(self.__class__._registry.keys())
```

## Other Notable Decorators
While not strictly OOP-specific, these are commonly used in classes:

### `@property` with setter and deleter
```python
class Temperature:
    def __init__(self, celsius=0):
        self._celsius = celsius
    
    @property
    def celsius(self):
        return self._celsius
    
    @celsius.setter
    def celsius(self, value):
        if value < -273.15:
            raise ValueError("Temperature below absolute zero")
        self._celsius = float(value)
    
    @celsius.deleter
    def celsius(self):
        """Reset to absolute zero."""
        self._celsius = -273.15
    
    @property
    def fahrenheit(self):
        """Read-only conversion to Fahrenheit."""
        return self._celsius * 9/5 + 32
```

### `@abstractmethod` (from abc module)
```python
from abc import ABC, abstractmethod

class Extractor(ABC):
    @abstractmethod
    def extract(self, source):
        """Extract data from source. Must be implemented by subclasses."""
        pass
    
    @abstractmethod
    def validate(self, data):
        """Validate extracted data. Must be implemented by subclasses."""
        pass

class CSVExtractor(Extractor):
    def extract(self, source):
        # Implementation
        pass
    
    def validate(self, data):
        # Implementation
        pass
```

## Best Practices
1. **Use `@staticmethod` for true utility functions**: When the method doesn't need access to `self` or `cls`.
2. **Use `@classmethod` for alternative constructors**: When you need to create instances in different ways.
3. **Use `@property` for computed attributes**: When you need to compute values on access or validate assignments.
4. **Keep property getters side-effect free**: Getters should be idempotent and inexpensive.
5. **Document properties clearly**: Indicate whether they're computed, cached, or have side effects.
6. **Avoid overusing properties**: Simple attributes don't need properties.
7. **Consider performance**: Properties are called every access; cache expensive computations.
8. **Use private attributes for storage**: Conventionally prefix with `_` to indicate internal storage.

## Common Gotchas
1. **Forgetting `@property` setter**: Makes attribute read-only only.
2. **Mutating mutable objects in properties**: Return copies if mutation should be prevented.
3. **Infinite recursion in properties**: Accidentally referencing the property itself in getter/setter.
4. **Property shadowing**: Defining a property with same name as method in parent class.
5. **Thread safety**: Properties aren't inherently thread-safe; consider locks for shared state.
6. **Pickling issues**: Some properties may not pickle correctly if they rely on transient state.

## When Not to Use
- Simple data storage (use regular attributes)
- Methods that perform actions (use regular methods)
- When the computation has side effects that shouldn't happen on every access
- When you need to pass additional parameters (consider methods instead)

## Decorator Comparison
| Decorator | First Parameter | Access to | Typical Use Cases |
|-----------|-----------------|-----------|-------------------|
| `@staticmethod` | None | Neither instance nor class | Utility functions, helper methods |
| `@classmethod` | `cls` (the class) | Class state, can create instances | Alternative constructors, factory methods |
| `@property` | `self` (implicit) | Instance state | Computed attributes, validation, lazy computation |