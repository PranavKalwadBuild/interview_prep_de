# Strings in Python

## Why Strings Matter
Strings are ubiquitous in data engineering: parsing logs, handling file paths, cleaning data, API payloads, and more. Understanding string methods, encoding, and performance is crucial.

## String Basics
- Immutable sequence of Unicode characters.
- Created with single, double, or triple quotes.
- Triple quotes allow multiline strings and docstrings.

## Common String Operations

### Indexing and Slicing
```python
s = "hello world"
s[0]      # 'h'
s[-1]     # 'd'
s[0:5]    # 'hello'
s[:5]     # 'hello'
s[6:]     # 'world'
s[::-1]   # 'dlrow olleh'
```

### String Methods (Essential)
| Method               | Description                                      |
|----------------------|--------------------------------------------------|
| `upper()`            | Convert to uppercase                             |
| `lower()`            | Convert to lowercase                             |
| `strip()`            | Remove leading/trailing whitespace               |
| `lstrip()`/`rstrip()`| Remove left/right whitespace                     |
| `split(sep)`         | Split by separator (default: whitespace)         |
| `join(iterable)`     | Join list of strings with separator              |
| `replace(old, new)`  | Replace occurrences                              |
| `startswith(prefix)` | Check prefix                                     |
| `endswith(suffix)`   | Check suffix                                     |
| `find(sub)`          | Return index or -1                               |
| `count(sub)`         | Count occurrences                                |
| `isalpha()`          | Only letters                                     |
| `isdigit()`          | Only digits                                      |
| `isalnum()`          | Letters and digits                               |
| `isspace()`          | Only whitespace                                  |
| `islower()`/`isupper()`| Case check                                       |
| `title()`            | Title case                                       |
| `capitalize()`       | Capitalize first character                       |

### String Formatting
#### f-strings (Python 3.6+)
```python
name = "Alice"
age = 30
f"Hello, {name}. You are {age} years old."
# Expressions inside braces: f"{price * quantity:.2f}"
```

#### .format() Method
```python
"Hello, {name}. You are {age} years old.".format(name="Alice", age=30)
# Positional: "Hello, {0}. You are {1} years old.".format("Alice", 30)
```

#### % Formatting (Old style)
```python
"Hello, %s. You are %d years old." % ("Alice", 30)
```

## Encoding and Decoding
- Python 3 strings are Unicode by default.
- Encode to bytes: `s.encode('utf-8')`
- Decode from bytes: `b.decode('utf-8')`
- Handle encoding errors: `errors='ignore'`, `errors='replace'`

## Common Gotchas
1. **Immutability**: Strings cannot be changed in place. Operations return new strings.
2. **Performance in loops**: Avoid repeated concatenation in loops; use `str.join()`.
3. **Whitespace**: Remember `strip()` only removes spaces/tabs/newlines by default. Use `strip(chars)` for custom.
4. **Unicode normalization**: Use `unicodedata.normalize()` for consistent comparison.

## Data Engineering Patterns

### Cleaning Data
```python
# Remove extra spaces and normalize case
cleaned = raw.strip().lower()

# Split CSV-like line (simple, no quotes)
parts = line.split(',')

# Remove punctuation
import string
translator = str.maketrans('', '', string.punctuation)
cleaned = text.translate(translator)
```

### Parsing Log Lines
```python
# Example: "2024-01-01 10:00:00 INFO User logged in"
log_line = "2024-01-01 10:00:00 INFO User logged in"
timestamp, level, message = log_line.split(' ', 2)
```

### Handling File Paths
```python
import os
# Safe join
path = os.path.join('/data', 'year=2024', 'month=01', 'data.csv')
# Normalize
norm = os.path.normpath(path)
# Split
dir_name, file_name = os.path.split(path)
```

## Performance Tips
- Use `str.join()` for building strings from many parts.
- For frequent membership checks, consider sets of strings.
- Use `startswith()`/`endswith()` instead of slicing for prefix/suffix checks.
- Compile regular expressions if used repeatedly.

## Interview Questions
**Q: How do you reverse a string in Python?**
A: `s[::-1]` using slicing with step -1.

**Q: What's the difference between `strip()`, `lstrip()`, and `rstrip()`?**
A: `strip()` removes leading and trailing whitespace; `lstrip()` only leading; `rstrip()` only trailing.

**Q: How do you check if a string contains only digits?**
A: Use `s.isdigit()`.

**Q: What is the most efficient way to concatenate many strings?**
A: Use `''.join(list_of_strings)`.

**Q: How do you handle Unicode decode errors?**
A: Use `decode('utf-8', errors='replace')` or `errors='ignore'`.