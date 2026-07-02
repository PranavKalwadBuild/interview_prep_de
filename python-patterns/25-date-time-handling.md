<!-- python-patterns: Date and Time Handling in Python (for Data Engineering) -->

# Date and Time Handling in Python (for Data Engineering)

## Overview

Python’s built‑in `datetime` module provides the core types for working with calendar dates, times, timestamps, and time‑zone‑aware values. In data‑engineering pipelines you frequently need to:

- Ingest timestamps from logs, APIs, or files.
- Convert between epochs, ISO‑8601 strings, and human‑readable formats.
- Perform date arithmetic (e.g., “add 7 days”, “compute age”).
- Handle time zones correctly, store timestamps in UTC, and convert to local time only for presentation.
- Avoid common pitfalls such as mixing naive and aware objects, silent overflow, or DST ambiguities.

This document covers the essential concepts, best‑practice patterns, and example code snippets you can copy‑paste into a reusable utilities module.

---

## Core Types

| Class | What it represents | Naive vs. aware | Key attributes |
|-------|-------------------|-----------------|----------------|
| `date` | Calendar date (year‑month‑day) | Always naive (no time‑of‑day or tzinfo) | `year`, `month`, `day` |
| `time` | Wall‑clock time (hour:minute:second:microsecond) | May be naive (`tzinfo=None`) or aware (`tzinfo` set) | `hour`, `minute`, `second`, `microsecond`, `tzinfo`, `fold` |
| `datetime` | Combination of `date` + `time` | Naive or aware (via `tzinfo`) | All date and time fields plus `tzinfo` and `fold` |
| `timedelta` | Duration or difference between two date/time objects | — | `days`, `seconds`, `microseconds` (access via `total_seconds()`) |
| `tzinfo` (abstract) | Base class for time‑zone information | — | Subclasses must implement `utcoffset(dt)`, `dst(dt)`, `tzname(dt)` |
| `timezone` (concrete `tzinfo`) | Fixed‑offset from UTC (e.g., UTC, EST) | — | `datetime.timezone.utc` is UTC offset 0 |

*Never compare or combine a naive object with an aware one – it raises `TypeError` (except for equality where they are simply unequal).*

---

## Creating Objects

### From components
```python
import datetime as dt

d = dt.date(2025, 9, 24)
t = dt.time(14, 30, 15, 123456)   # hour, minute, second, microsecond
dt_obj = dt.datetime(2025, 9, 24, 14, 30, 15, 123456)
```

### From timestamp (seconds since epoch)
```python
ts = 1_730_000_000  # example POSIX timestamp
# Naive local time (based on system timezone)
naive = dt.datetime.fromtimestamp(ts)
# Aware UTC
aware_utc = dt.datetime.fromtimestamp(ts, tz=dt.timezone.utc)
# Aware in a specific fixed offset (e.g., UTC‑5)
aware_eastern = dt.datetime.fromtimestamp(ts, tz=dt.timezone(dt.timedelta(hours=-5)))
```

### From ISO‑8601 string (recommended)
```python
# datetime with offset
dt_obj = dt.datetime.fromisoformat('2025-09-24T14:30:15+02:00')
# date only
d = dt.date.fromisoformat('2025-09-24')
# time only (Python 3.11+)
t = dt.time.fromisoformat('14:30:15.123456')
```

### Current moment
```python
now_utc = dt.datetime.now(tz=dt.timezone.utc)        # preferred
now_local = dt.datetime.now()                        # naive local time (use with care)
today = dt.date.today()
```

---

## Formatting & Parsing

### `isoformat()` / `fromisoformat()`
- `isoformat()` produces an ISO‑8601 string that includes the offset if the object is aware.
- `fromisoformat()` is the inverse and is tolerant of variations (e.g., missing seconds, microseconds).
- Use these for reliable interchange; they are locale‑independent.

```python
iso_str = dt_obj.isoformat()          # '2025-09-24T14:30:15+02:00'
dt_obj   = dt.datetime.fromisoformat(iso_str)
```

### `strftime()` / `strptime()`
- Use when you need a custom layout (e.g., for reports or legacy systems).
- Be aware of platform‑specific format codes and locale dependence.
- For month‑day‑only formats, always supply a year (preferably a leap year) to avoid deprecation warnings.

```python
# Formatting
fmt = dt_obj.strftime('%Y-%m-%d %H:%M:%S %Z%z')  # e.g., '2025-09-24 14:30:15 CEST+0200'

# Parsing (exact format match)
parsed = dt.datetime.strptime('2025-09-24 14:30:15', '%Y-%m-%d %H:%M:%S')
```

### Common format codes (subset)

| Code | Meaning          | Example |
|------|------------------|---------|
| `%Y` | 4‑digit year     | 2025 |
| `%y` | 2‑digit year     | 25 |
| `%m` | month 01‑12      | 09 |
| `%d` | day of month 01‑31 | 24 |
| `%H` | hour 00‑23       | 14 |
| `%I` | hour 01‑12       | 02 |
| `%p` | AM/PM            | PM |
| `%M` | minute 00‑59     | 30 |
| `%S` | second 00‑59     | 15 |
| `%f` | microsecond 000000‑999999 | 123456 |
| `%a` | Abbrev weekday   | Wed |
| `%A` | Full weekday     | Wednesday |
| `%b` | Abbrev month     | Sep |
| `%B` | Full month       | September |
| `%Z` | Time zone name   | CEST, UTC, EST |
| `%z` | UTC offset as +HHMM or -HHMM | +0200, -0500 |

---

## Time Zones & UTC

### Why UTC?
- Storing timestamps in UTC removes ambiguity caused by daylight‑saving changes and regional offsets.
- All arithmetic on aware `datetime` objects is performed in UTC internally, guaranteeing correct results.

### Creating aware datetimes
```python
from datetime import timezone, timedelta

# UTC (preferred)
utc_dt = dt.datetime.now(tz=timezone.utc)

# Fixed‑offset zones (no DST)
est = timezone(timedelta(hours=-5))        # EST (always UTC‑5)
est_dt = dt.datetime.now(tz=est)

# Using zoneinfo (Python 3.9+) for IANA tz database (handles DST)
try:
    from zoneinfo import ZoneInfo   # stdlib in 3.9+
except ImportError:
    from backports.zoneinfo import ZoneInfo  # pip install backports.zoneinfo

europe_berlin = ZoneInfo("Europe/Berlin")
berlin_dt = dt.datetime.now(tz=europe_berlin)
```

### Converting zones (preserves the instant)
```python
berlin_dt = utc_dt.astimezone(europe_berlin)   # same moment, Berlin wall‑time
utc_again  = berlin_dt.astimezone(timezone.utc) # back to UTC
```

### Attaching / detaching a zone without shifting the clock
```python
# Suppose you have a naive datetime that *actually* represents UTC time.
naive_utc = dt.datetime(2025, 9, 24, 12, 0, 0)
# Attach UTC zone (no shift):
aware_utc = naive_utc.replace(tzinfo=timezone.utc)
# Detach zone (keep same wall‑clock values, become naive):
naive_again = aware_utc.replace(tzinfo=None)
```
> **Never** use `replace(tzinfo=…)` to “convert” zones – it does **not** adjust the wall‑clock time. Use `astimezone()` for true conversion.

---

## Arithmetic & Duration

### `timedelta` basics
```python
delta = dt.timedelta(days=3, hours=5, minutes=30)  # 3 days, 5h30m
total_sec = delta.total_seconds()                  # 297000.0
```

### Adding/subtracting to date/datetime
```python
today = dt.date.today()
next_week = today + dt.timedelta(weeks=1)   # date
yesterday = today - dt.timedelta(days=1)

now = dt.datetime.now(tz=dt.timezone.utc)
later = now + dt.timedelta(hours=2)        # aware datetime, tz preserved
```
- Adding a `timedelta` to a **date** ignores the time‑of‑day and tzinfo (there is none).
- Adding to a **datetime** preserves `tzinfo`; the result represents the same absolute instant shifted by the duration.

### Difference between two datetimes → `timedelta`
```python
delta = later - now   # always a timedelta, tzinfo removed
print(delta.total_seconds())   # >0
```
- If both operands are aware, they are first converted to UTC for the subtraction, so the result is correct regardless of zones.
- Mixing naive and aware raises `TypeError`.

---

## Common Pitfalls & How to Avoid Them

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| **Comparing naive & aware** | `TypeError: can't compare offset-naive and offset-aware datetimes` | Ensure both sides are either naive or aware; convert with `astimezone()` or `replace(tzinfo=None)` as appropriate. |
| **Using `utcnow()` / `utcfromtimestamp()`** | Deprecation warnings (Python 3.12) | Replace with `datetime.now(tz=timezone.utc)` and `datetime.fromtimestamp(ts, tz=timezone.utc)`. |
| **Assuming `timedelta.seconds` gives total seconds** | Underestimates duration when `days > 0` | Use `total_seconds()` instead. |
| **Ignoring DST fold (ambiguous hour)** | Unexpected double‑count or missing hour during fall‑back | When parsing or creating times around a DST transition, set the `fold` attribute (0 for first occurrence, 1 for second) or use a zoneinfo library that handles it automatically. |
| **Using `date` objects for UTC timestamps** | Comparing a `date` with a `datetime` raises `TypeError` | Convert `date` to `datetime` at midnight in the desired zone (`datetime.combine(date, time.min, tzinfo=…)`) before mixing with datetimes. |
| **Parsing month‑day‑only strings without year** | `DeprecationWarning: Converting a two‑digit year …` | Always supply a year (use a leap year like 2020 if the exact year is irrelevant). |
| **Storing timestamps as strings without offset** | Loss of zone information when read later | Serialize with `isoformat()` (includes offset if aware) or store as epoch seconds (UTC) plus a separate zone column if needed. |

---

## Best Practices for Data‑Engineering Pipelines

1. **Always work with aware UTC datetimes internally.**  
   Convert to local time only at the API/UI boundary for display.
2. **Store timestamps as epoch seconds (UTC) or ISO‑8601 strings with offset.**  
   Both are unambiguous and sortable.
3. **Prefer `timedelta` for interval arithmetic**; avoid manual second‑level math.
4. **When reading external data, parse into aware datetimes immediately** (use `fromisoformat` if the string includes offset, or attach a known `tzinfo` afterward).  
   Example:
   ```python
   def parse_ts(ts_str: str) -> dt.datetime:
       # If string ends with Z or +hh:mm, fromisoformat gives aware
       dt_obj = dt.datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
       if dt_obj.tzinfo is None:
           # assume UTC if no offset provided
           dt_obj = dt_obj.replace(tzinfo=dt.timezone.utc)
       return dt_obj
   ```
5. **Use `zoneinfo` (or `dateutil.tz` for older Python) for named time zones**; avoid hand‑crafted `tzinfo` subclasses unless you need a fixed offset.
6. **Make datetime objects immutable** – they are hashable and safe to use as dict keys or in sets.
7. **Leverage vectorized operations only when necessary**; for huge streams, keep the pipeline generator‑based and apply `timedelta` arithmetic per record.
8. **Unit‑test time‑zone logic** with known edge cases (e.g., spring‑forward, fall‑back, leap seconds if relevant).

---

## Example: Minimal Reusable Helpers

```python
# datetime_helpers.py
import datetime as dt
from datetime import timezone, timedelta
try:
    from zoneinfo import ZoneInfo
except ImportError:
    from backports.zoneinfo import ZoneInfo  # pip install backports.zoneinfo

def utc_now() -> dt.datetime:
    """Current moment as an aware UTC datetime."""
    return dt.datetime.now(tz=timezone.utc)

def parse_iso_to_utc(iso_str: str) -> dt.datetime:
    """
    Parse an ISO‑8601 string (with or without offset) and return an aware UTC datetime.
    If the string lacks offset, assume UTC.
    """
    # Replace Z with +00:00 for fromisoformat compatibility
    iso_str = iso_str.replace('Z', '+00:00')
    dt_obj = dt.datetime.fromisoformat(iso_str)
    if dt_obj.tzinfo is None:
        dt_obj = dt_obj.replace(tzinfo=timezone.utc)
    return dt_obj.astimezone(timezone.utc)

def format_iso(dt_obj: dt.datetime) -> str:
    """Return ISO‑8601 string with offset (always includes offset if aware)."""
    return dt_obj.isoformat()

def add_duration(base: dt.datetime | dt.date, delta: dt.timedelta):
    """Add a timedelta, preserving tzinfo for datetime, returning same type."""
    return base + delta

def elapsed_seconds(start: dt.datetime, end: dt.datetime) -> float:
    """Return floating‑point seconds between two aware datetimes (must be same tz or both UTC)."""
    if start.tzinfo is None or end.tzinfo is None:
        raise ValueError("Both datetimes must be aware for elapsed calculation.")
    return (end - start).total_seconds()
```

Use these helpers throughout your ETL jobs to keep time‑handling consistent and avoid repetitive boilerplate.

---

## References

- Python 3 Documentation – `datetime` module: https://docs.python.org/3/library/datetime.html  
- Programiz – Python datetime tutorial: https://www.programiz.com/python-programming/datetime  
- Real Python (cached) – Working with Dates and Times in Python: https://realpython.com/python-datetime/  
- Dataquest – Python Datetime Tutorial: https://www.dataquest.io/blog/python-datetime-tutorial/  
- W3Schools – Python DateTime: https://www.w3schools.com/python/python_datetime.asp  
- GeeksforGeeks – Python Datetime Module: https://www.geeksforgeeks.org/python/python-datetime-module/  

---  

*End of document.*  