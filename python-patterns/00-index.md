<!-- python-patterns: Index -->

# Python Patterns for Data Engineering — Navigation Index

Reference library for Python as used in DE roles: pipelines, scripting, testing, and system design.
Each file covers: how it works, how it breaks, how to fix it, and interview angles.

This index is the entry point. Start with the conceptual files for your weak spots, then use the quick reference page when you want fast recall before an interview.

## Standard Import Block

```python
import os, sys, json, logging, time, copy
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional, Iterator, Generator, Protocol
from abc import ABC, abstractmethod
from contextlib import contextmanager
from functools import wraps, partial
from concurrent.futures import ThreadPoolExecutor, ProcessPoolExecutor, as_completed
import itertools
import pandas as pd
import numpy as np
import boto3
import requests
```

## File Index

| File | Title | What's Covered |
|------|-------|----------------|
| 01-data-structures-core.md | Data Structures Deep Dive | list/tuple/set/dict internals, time complexity, mutability traps, when to use which |
| 02-comprehensions-and-generators.md | Comprehensions and Generators | list/dict/set/generator expressions, yield, yield from, generator pipelines |
| 03-decorators.md | Decorators | function/class decorators, decorator factories, functools.wraps, real DE examples |
| 04-context-managers.md | Context Managers | with/__enter__/__exit__, contextlib, connection/file management patterns |
| 05-iterators-and-itertools.md | Iterators and itertools | iterator protocol, __iter__/__next__, itertools patterns for DE |
| 06-oop-fundamentals.md | OOP Fundamentals | classes, inheritance, MRO, dunder methods, super() |
| 07-oop-advanced-patterns.md | OOP Advanced Patterns | dataclasses, ABC, Protocol, properties, classmethod/staticmethod, ETL class design |
| 08-error-handling-pipelines.md | Error Handling in Pipelines | try/except/finally, custom exceptions, exception chaining, pipeline-safe patterns |
| 09-file-and-io-patterns.md | File and IO Patterns | pathlib, CSV/JSON/YAML, chunked file reads, streaming, binary formats |
| 10-concurrency-patterns.md | Concurrency Patterns | GIL, ThreadPoolExecutor, ProcessPoolExecutor, as_completed, rate limiting |
| 11-de-scripting-boto3-requests.md | DE Scripting: boto3 and requests | S3 pagination, multipart upload, retry sessions, paginated API ingestion |
| 12-config-and-logging.md | Config and Logging | dataclass/pydantic config, env vars, structured logging, Airflow-safe logger setup |
| 13-pandas-for-de.md | Pandas for Data Engineering | groupby traps, merge vs join, apply vs vectorization, chunked reads, memory optimization |
| 14-testing-with-pytest.md | Testing with pytest | fixtures, parametrize, mocking AWS (moto), monkeypatching, DB rollback pattern |
| 15-performance-patterns.md | Performance Patterns | profiling, slots, memory, vectorization over loops, when Python is the bottleneck |
| 16-quick-reference.md | Quick Reference | cheat sheets, gotcha table, decision matrices |

## Reading Order

**New to advanced Python:** 01 → 02 → 03 → 04 → 06

**Interview prep — conceptual:** 03 → 04 → 02 → 07 → 05

**DE scripting focus:** 08 → 09 → 11 → 12 → 10

**OOP / pipeline design:** 06 → 07 → 08 → 04

**Testing focus:** 14 → 08 → 13

**Pandas focus:** 13 → 15 → 02

**Quick lookup:** 16
