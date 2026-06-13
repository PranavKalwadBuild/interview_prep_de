<!-- PySpark-patterns: Date and Time -->

# Date and Time

## Parsing Strings to Date/Timestamp

```python
from pyspark.sql import functions as F

# to_date: parses string to DateType
F.to_date(F.col("date_str"), "yyyy-MM-dd")        # "2024-01-15" -> date
F.to_date(F.col("date_str"), "MM/dd/yyyy")         # "01/15/2024" -> date
F.to_date(F.col("date_str"), "yyyyMMdd")           # "20240115" -> date (SAP format)

# to_timestamp: parses string to TimestampType
F.to_timestamp(F.col("ts_str"), "yyyy-MM-dd HH:mm:ss")
F.to_timestamp(F.col("ts_str"), "yyyy-MM-dd'T'HH:mm:ss")  # ISO 8601

# Without format: Spark tries common formats automatically (may be slow/wrong)
F.to_date(F.col("date_str"))        # tries common formats
F.to_timestamp(F.col("ts_str"))     # tries common formats
```

**Invalid date strings return NULL** — no exception is thrown.
If your date parsing returns unexpected NULLs, check the format string.

---

## SAP Date Strings (YYYYMMDD as VARCHAR)

SAP systems commonly store dates as 8-character strings like `"20240115"`.

```python
# Convert SAP date string to DateType
df.withColumn("date", F.to_date(F.col("sap_date"), "yyyyMMdd"))

# SAP uses "00000000" for missing dates — handle before converting
df.withColumn("date",
    F.when(F.col("sap_date") == "00000000", F.lit(None))
     .otherwise(F.to_date(F.col("sap_date"), "yyyyMMdd"))
)
```

---

## Date Arithmetic

```python
# Difference between two dates (in days)
F.datediff(F.col("end_date"), F.col("start_date"))   # end - start in days

# Add/subtract days
F.date_add(F.col("date"), 7)    # add 7 days
F.date_sub(F.col("date"), 7)    # subtract 7 days

# Add/subtract months
F.add_months(F.col("date"), 3)   # add 3 months
F.add_months(F.col("date"), -1)  # subtract 1 month

# Months between two dates (fractional)
F.months_between(F.col("end_date"), F.col("start_date"))

# Current date and timestamp
F.current_date()        # DateType, same for all rows in a batch
F.current_timestamp()   # TimestampType, same for all rows in a batch
F.now()                 # alias for current_timestamp()
```

---

## Truncation

```python
# date_trunc: truncates timestamp to specified unit
F.date_trunc("month", F.col("ts"))   # first moment of the month
F.date_trunc("day",   F.col("ts"))   # midnight of the day
F.date_trunc("year",  F.col("ts"))   # first moment of the year
F.date_trunc("hour",  F.col("ts"))   # beginning of the hour
F.date_trunc("week",  F.col("ts"))   # Monday of the week (ISO week)

# trunc: truncates date (not timestamp) to month or year
F.trunc(F.col("date"), "month")  # first day of the month
F.trunc(F.col("date"), "year")   # Jan 1 of the year
```

**Key difference:** `date_trunc` works on timestamps and returns a timestamp.
`trunc` works on dates and returns a date. Don't confuse them.

---

## Extracting Parts of a Date

```python
F.year(F.col("date"))          # integer year
F.month(F.col("date"))         # 1-12
F.dayofmonth(F.col("date"))    # 1-31
F.dayofweek(F.col("date"))     # 1=Sunday, 7=Saturday
F.dayofyear(F.col("date"))     # 1-366
F.weekofyear(F.col("date"))    # ISO week number
F.quarter(F.col("date"))       # 1-4
F.hour(F.col("ts"))
F.minute(F.col("ts"))
F.second(F.col("ts"))

# Using date_format for custom output
F.date_format(F.col("date"), "yyyy-MM")      # "2024-01"
F.date_format(F.col("date"), "EEEE")         # "Monday"
F.date_format(F.col("ts"), "yyyy-MM-dd HH:mm:ss")
```

---

## Epoch Timestamps

```python
# Unix timestamp (seconds since 1970-01-01 UTC) -> timestamp
F.from_unixtime(F.col("epoch_seconds"))                    # default: "yyyy-MM-dd HH:mm:ss"
F.from_unixtime(F.col("epoch_seconds"), "yyyy-MM-dd")      # custom format

# Timestamp -> Unix timestamp
F.unix_timestamp(F.col("ts"))                              # current format assumed
F.unix_timestamp(F.col("ts_str"), "yyyy-MM-dd HH:mm:ss")  # parse from string

# Millisecond epoch (common in event data)
F.from_unixtime(F.col("epoch_ms") / 1000)   # divide by 1000 first

# Or use timestamp type division
F.to_timestamp(F.col("epoch_ms") / 1000)    # Spark 3.0+: cast long/double as seconds
```

---

## Timezone Handling

Spark stores timestamps internally as UTC. Display and conversion depend on session timezone.

```python
# Get/set session timezone
spark.conf.get("spark.sql.session.timeZone")       # default: JVM default (usually UTC)
spark.conf.set("spark.sql.session.timeZone", "UTC")

# Convert from a specific timezone to UTC
F.to_utc_timestamp(F.col("ts"), "America/New_York")

# Convert from UTC to a specific timezone (for display/output)
F.from_utc_timestamp(F.col("ts_utc"), "America/Los_Angeles")
```

### The DST Trap

Daylight Saving Time (DST) transitions create ambiguous local times.
For example, "2024-03-10 02:30:00 America/New_York" doesn't exist (clocks skip forward).
Spark resolves these with platform-specific rules — the result may vary.

**Best practice:** always store and process timestamps in UTC.
Convert to local timezone only for display.

---

## NULL Behavior

- Invalid format strings in `to_date()`/`to_timestamp()` return NULL (not an exception)
- `datediff()` with a NULL input returns NULL
- `date_add()` with a NULL input returns NULL
- `current_date()` and `current_timestamp()` never return NULL

```python
# Audit for date parse failures
df.withColumn("parsed_date", F.to_date(F.col("date_str"), "yyyyMMdd")) \
  .filter(F.col("parsed_date").isNull() & F.col("date_str").isNotNull()) \
  .show()
# These are rows where the string exists but couldn't be parsed — likely wrong format
```

---

## Common Date Patterns

```python
# Age calculation (approximate, in years)
F.floor(F.datediff(F.current_date(), F.col("birth_date")) / 365.25)

# Is weekend?
F.dayofweek(F.col("date")).isin([1, 7])   # 1=Sunday, 7=Saturday

# First day of month
F.trunc(F.col("date"), "month")

# Last day of month
F.last_day(F.col("date"))

# Previous Monday (start of ISO week)
F.date_trunc("week", F.col("ts"))

# Days since last event (rolling)
# Requires window function — see 06-window-functions.md
```
