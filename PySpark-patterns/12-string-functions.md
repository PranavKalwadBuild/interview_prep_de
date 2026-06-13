<!-- PySpark-patterns: String Functions -->

# String Functions

## Pattern Matching and Replacement

```python
from pyspark.sql import functions as F

# Extract a group from a regex pattern
# regexp_extract(col, pattern, group_index)
F.regexp_extract(F.col("email"), r"@([^.]+)\.", 1)   # extract domain name

# Replace matches with a string
F.regexp_replace(F.col("phone"), r"[^\d]", "")        # keep only digits
F.regexp_replace(F.col("text"), r"\s+", " ")          # collapse whitespace

# Check if column matches pattern (returns boolean column)
F.col("email").rlike(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$")

# Simple contains/startsWith/endsWith
F.col("name").contains("John")
F.col("code").startswith("US")
F.col("code").endswith("_v2")
F.col("name").like("John%")      # SQL LIKE — % for wildcard, _ for single char
F.col("name").ilike("john%")     # case-insensitive LIKE (Spark 3.3+)
```

---

## Splitting and Joining

```python
# Split string into array
F.split(F.col("tags_str"), ",")              # "a,b,c" -> ["a", "b", "c"]
F.split(F.col("text"), r"\s+")               # split on whitespace

# Join array elements into string
F.concat_ws(",", F.col("tags_array"))        # ["a", "b"] -> "a,b"
F.concat_ws(" ", F.col("first"), F.col("last"))  # "John" + "Doe" -> "John Doe"

# Concatenate strings (NULL propagates — one NULL input = NULL output)
F.concat(F.col("first"), F.lit(" "), F.col("last"))

# concat_ws ignores NULLs — safe for concatenation with possible NULLs
F.concat_ws(" ", F.col("first"), F.col("middle"), F.col("last"))
# If middle is NULL: "John Doe" (not "John  Doe")
```

---

## Case and Trimming

```python
F.upper(F.col("name"))    # "john" -> "JOHN"
F.lower(F.col("name"))    # "JOHN" -> "john"
F.initcap(F.col("name"))  # "john doe" -> "John Doe"

F.trim(F.col("name"))     # remove leading and trailing spaces
F.ltrim(F.col("name"))    # remove leading spaces only
F.rtrim(F.col("name"))    # remove trailing spaces only
```

### The Whitespace Trap in Joins

Invisible leading/trailing spaces cause join failures:

```python
# "John " != "John" — these rows will NOT match
customers.join(orders, customers["name"] == orders["customer_name"])

# Fix: trim both sides before joining
customers = customers.withColumn("name", F.trim(F.col("name")))
orders = orders.withColumn("customer_name", F.trim(F.col("customer_name")))
```

### Case Sensitivity in Joins

```python
# "ACME" != "acme" — case mismatch causes join failure
# Fix: normalize case before joining
df1 = df1.withColumn("company", F.lower(F.trim(F.col("company"))))
df2 = df2.withColumn("company", F.lower(F.trim(F.col("company"))))
df1.join(df2, on="company")
```

---

## Substring and Position

```python
F.substring(F.col("str"), 1, 3)    # start (1-based), length: "hello" -> "hel"
F.left(F.col("str"), 3)            # first N chars (Spark 3.3+)
F.right(F.col("str"), 3)           # last N chars (Spark 3.3+)
F.length(F.col("str"))             # string length (NULL if input is NULL)
F.char_length(F.col("str"))        # alias for length

F.instr(F.col("str"), "lo")        # 1-based position of substring; 0 if not found
F.locate("lo", F.col("str"))       # same as instr with args swapped
F.locate("lo", F.col("str"), 3)    # start search from position 3

F.lpad(F.col("code"), 10, "0")     # left-pad with zeros to length 10
F.rpad(F.col("code"), 10, " ")     # right-pad with spaces to length 10

F.repeat(F.col("char"), 3)         # "a" -> "aaa"
F.reverse(F.col("str"))            # "hello" -> "olleh"
F.translate(F.col("str"), "abc", "xyz")  # character-by-character replacement
```

---

## Hashing for Row Fingerprinting

```python
# SHA2 — cryptographic, low collision risk, consistent across platforms
F.sha2(F.col("email"), 256)    # 256-bit SHA-2 (SHA-256)
F.sha2(F.col("email"), 512)    # 512-bit SHA-2

# SHA2 on multiple columns — concatenate first
F.sha2(F.concat_ws("|", F.col("id"), F.col("email"), F.col("name")), 256)

# MD5 — faster, but higher collision risk than SHA-2; not suitable for security
F.md5(F.col("email"))

# hash() — MurmurHash3, non-cryptographic, fast, platform-dependent output
# DO NOT use for cross-system comparisons or long-term storage
F.hash(F.col("id"), F.col("name"))         # integer output
F.xxhash64(F.col("id"), F.col("name"))    # 64-bit XxHash (Spark 3.0+), faster than hash()
```

### Choosing a Hash Function

| Function | Use Case | Collision Risk |
|----------|----------|---------------|
| `sha2(col, 256)` | Row fingerprinting, change detection, dedup across systems | Very low |
| `md5(col)` | Checksums, non-security use | Low |
| `hash(col)` | Partitioning, bucketing, local operations only | Higher; do not use across systems |
| `xxhash64(col)` | Fast hashing, partitioning | Moderate |

---

## NULL Propagation in String Functions

All string functions return NULL if any input is NULL.

```python
F.concat(F.col("a"), F.col("b"))         # NULL if a or b is NULL
F.concat_ws(",", F.col("a"), F.col("b"))  # ignores NULLs — safe
F.upper(F.col("name"))                    # NULL if name is NULL
F.length(F.col("str"))                    # NULL if str is NULL
F.substring(F.col("str"), 1, 3)          # NULL if str is NULL
```

Pattern to handle NULLs in string operations:
```python
F.upper(F.coalesce(F.col("name"), F.lit("")))
# or
F.when(F.col("name").isNotNull(), F.upper(F.col("name")))
```

---

## Other Useful String Functions

```python
F.ascii(F.col("char"))              # ASCII code of first character
F.chr(F.col("code"))                # character from ASCII code
F.encode(F.col("str"), "utf-8")    # encode string to binary
F.decode(F.col("bytes"), "utf-8")  # decode binary to string
F.base64(F.col("bytes"))            # base64 encode
F.unbase64(F.col("str"))            # base64 decode to binary
F.format_string("%s has %d items", F.col("name"), F.col("count"))  # printf-style formatting
F.levenshtein(F.col("a"), F.col("b"))  # edit distance between two strings
F.soundex(F.col("name"))           # phonetic encoding
```
