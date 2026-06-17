<!-- python-patterns: Testing with pytest -->

# Testing with pytest

## Why pytest Matters for Data Engineering

Testing is how you keep pipelines trustworthy as they evolve. In DE, tests are not just about correctness of a function; they are about schema stability, data contracts, external service handling, and reproducible environments.

**Mental model:** test small behavior in isolation, then build higher-level tests that check contracts and integration points. Use fixtures to control state and mocks or moto to replace expensive external systems.

## Core pytest Syntax

```python
# test_basics.py
import pytest

def add(a, b):
    return a + b

def test_add_positive():
    assert add(2, 3) == 5

def test_add_zero():
    assert add(0, 0) == 0

def test_add_raises():
    with pytest.raises(TypeError):
        add("a", 1)   # or whatever your function raises

# Run: pytest test_basics.py -v
# Run with output: pytest -s
# Run specific test: pytest test_basics.py::test_add_positive
```

---

## Fixtures — The Core of pytest

```python
import pytest
import pandas as pd

# Basic fixture — runs before each test that requests it
@pytest.fixture
def sample_df():
    return pd.DataFrame({
        "id": [1, 2, 3],
        "amount": [100.0, 200.0, 300.0],
        "status": ["active", "inactive", "active"],
    })

def test_filter_active(sample_df):
    active = sample_df[sample_df["status"] == "active"]
    assert len(active) == 2
    assert active["amount"].sum() == 400.0

# Fixture scope — controls how often the fixture is created
@pytest.fixture(scope="session")    # once for entire test session
def db_connection():
    conn = create_test_db_connection()
    yield conn
    conn.close()

@pytest.fixture(scope="module")     # once per test module (file)
def api_client():
    return build_http_session()

@pytest.fixture(scope="function")   # default — once per test function
def clean_state():
    yield
    cleanup()

# Fixture composition — fixtures can depend on other fixtures
@pytest.fixture
def loaded_table(db_connection, sample_df):
    sample_df.to_sql("test_events", db_connection, if_exists="replace", index=False)
    yield "test_events"
    db_connection.execute("DROP TABLE IF EXISTS test_events")
```

---

## Database Testing Pattern — Rollback Isolation

```python
import pytest
import psycopg2

@pytest.fixture(scope="session")
def db_conn():
    """One real DB connection for the whole test session."""
    conn = psycopg2.connect(
        host="localhost", port=5432,
        database="test_db", user="test", password="test"
    )
    yield conn
    conn.close()

@pytest.fixture
def db_cursor(db_conn):
    """Fresh cursor per test, always rolled back — no teardown between tests."""
    cursor = db_conn.cursor()
    yield cursor
    db_conn.rollback()   # undo all changes from this test
    cursor.close()

def test_insert_event(db_cursor):
    db_cursor.execute("INSERT INTO events (id, type) VALUES (1, 'click')")
    db_cursor.execute("SELECT count(*) FROM events WHERE id = 1")
    assert db_cursor.fetchone()[0] == 1

def test_events_empty_at_start(db_cursor):
    # rollback from previous test means this starts clean
    db_cursor.execute("SELECT count(*) FROM events")
    assert db_cursor.fetchone()[0] == 0
```

---

## `@pytest.mark.parametrize` — Data-Driven Tests

```python
import pytest
import pandas as pd
from myetl import transform_sales

@pytest.mark.parametrize("amount,qty,expected_total", [
    (10.0, 5, 50.0),       # normal case
    (0.0, 5, 0.0),         # zero amount
    (10.0, 0, 0.0),        # zero qty
    (-5.0, 3, -15.0),      # negative (should be filtered downstream)
])
def test_total_calculation(amount, qty, expected_total):
    df = pd.DataFrame([{"amount": amount, "qty": qty}])
    result = transform_sales(df)
    assert result["total"].iloc[0] == expected_total

# Parametrize with ids — readable test names
@pytest.mark.parametrize("input_rows,expected_count", [
    pytest.param([{"id": 1, "amount": 100}], 1, id="single_valid"),
    pytest.param([{"id": 1, "amount": -1}], 0, id="negative_filtered"),
    pytest.param([], 0, id="empty_input"),
    pytest.param([{"id": 1, "amount": 0}], 0, id="zero_amount_filtered"),
])
def test_filter_invalid_rows(input_rows, expected_count):
    df = pd.DataFrame(input_rows) if input_rows else pd.DataFrame(columns=["id", "amount"])
    result = transform_sales(df)
    assert len(result) == expected_count
```

---

## Mocking AWS with moto

```python
import pytest
import boto3
import pandas as pd
from moto import mock_aws   # moto v4+ unified decorator

@mock_aws
def test_s3_upload():
    """Test that a function correctly uploads a file to S3."""
    # Create the mock bucket — moto intercepts boto3 calls
    s3 = boto3.client("s3", region_name="us-east-1")
    s3.create_bucket(Bucket="test-bucket")

    from myetl import upload_results
    df = pd.DataFrame({"id": [1, 2], "amount": [100, 200]})
    upload_results(df, bucket="test-bucket", key="output/results.parquet")

    # Verify the object was created
    response = s3.list_objects_v2(Bucket="test-bucket", Prefix="output/")
    assert response["KeyCount"] == 1
    assert response["Contents"][0]["Key"] == "output/results.parquet"

# Fixture-based moto (reusable)
@pytest.fixture
def mock_s3():
    with mock_aws():
        s3 = boto3.client("s3", region_name="us-east-1")
        s3.create_bucket(Bucket="test-bucket")
        yield s3

def test_key_exists(mock_s3):
    mock_s3.put_object(Bucket="test-bucket", Key="data/file.txt", Body=b"content")
    from myetl import s3_key_exists
    assert s3_key_exists("test-bucket", "data/file.txt") is True
    assert s3_key_exists("test-bucket", "data/missing.txt") is False
```

---

## `unittest.mock` — Patch External Dependencies

```python
from unittest.mock import MagicMock, patch, call
import pytest

# Patch — replace a module-level name during the test
@patch("myetl.requests.Session.get")
def test_api_pagination(mock_get):
    # Define what mock returns on successive calls
    mock_get.side_effect = [
        MagicMock(status_code=200, json=lambda: [{"id": 1}, {"id": 2}]),
        MagicMock(status_code=200, json=lambda: [{"id": 3}]),
        MagicMock(status_code=200, json=lambda: []),  # empty page signals end
    ]
    from myetl import paginate_api
    results = list(paginate_api("https://api.example.com/events"))
    assert len(results) == 3
    assert mock_get.call_count == 3

# Patch as context manager
def test_db_load():
    with patch("myetl.snowflake.connector.connect") as mock_connect:
        mock_conn = MagicMock()
        mock_cursor = MagicMock()
        mock_connect.return_value = mock_conn
        mock_conn.cursor.return_value = mock_cursor

        from myetl import load_to_snowflake
        load_to_snowflake(df, table="events")

        assert mock_cursor.executemany.called
        args = mock_cursor.executemany.call_args
        assert "INSERT" in args[0][0]   # first positional arg contains INSERT

# patch.object — patch a method on a specific object
class MyPipeline:
    def extract(self): ...

def test_pipeline_run():
    pipeline = MyPipeline()
    with patch.object(pipeline, "extract", return_value=pd.DataFrame({"id": [1]})):
        result = pipeline.run()
        assert result is not None
```

### `monkeypatch` — pytest's Built-in Patcher

```python
def test_env_config(monkeypatch):
    monkeypatch.setenv("SOURCE_BUCKET", "test-bucket")
    monkeypatch.setenv("BATCH_SIZE", "500")
    monkeypatch.delenv("DRY_RUN", raising=False)   # ensure it's not set

    config = PipelineConfig.from_env()
    assert config.source_bucket == "test-bucket"
    assert config.batch_size == 500

def test_custom_open(monkeypatch, tmp_path):
    # tmp_path — built-in pytest fixture for a temporary directory
    csv_file = tmp_path / "test.csv"
    csv_file.write_text("id,name\n1,alice\n2,bob\n")

    result = read_csv_and_count(str(csv_file))
    assert result == 2
```

---

## Data Contract Tests

```python
def test_output_schema(sample_df):
    from myetl import transform_sales
    result = transform_sales(sample_df)

    # Schema presence
    required_cols = {"id", "amount", "total", "status"}
    assert required_cols.issubset(set(result.columns)), \
        f"Missing columns: {required_cols - set(result.columns)}"

    # Type assertions
    assert pd.api.types.is_numeric_dtype(result["total"]), "total must be numeric"
    assert pd.api.types.is_string_dtype(result["status"]), "status must be string"

    # Null constraints
    assert result["id"].notnull().all(), "id has nulls"
    assert result["total"].notnull().all(), "total has nulls"

    # Value constraints
    assert (result["total"] >= 0).all(), "total has negative values"
    assert result["status"].isin(["active", "inactive"]).all(), "invalid status values"
```

---

## `conftest.py` — Shared Fixtures

```python
# tests/conftest.py — auto-loaded by pytest, shared across all test files

import pytest
import pandas as pd

@pytest.fixture(scope="session")
def base_events_df():
    return pd.DataFrame([
        {"user_id": "u1", "event": "click", "ts": "2024-01-01"},
        {"user_id": "u2", "event": "view",  "ts": "2024-01-01"},
        {"user_id": "u1", "event": "purchase", "ts": "2024-01-02"},
    ])

# Skip integration tests unless env var is set
def pytest_configure(config):
    config.addinivalue_line("markers", "integration: mark test as integration (requires real services)")

@pytest.fixture
def skip_in_ci(request):
    if not os.environ.get("INTEGRATION_TESTS"):
        pytest.skip("Set INTEGRATION_TESTS=1 to run")
```

---

## Interview Questions

**Q: What is the difference between `scope="session"` and `scope="function"` in fixtures?**
`function` (default): fixture is created and torn down for each test. `session`: created once for the entire test run. Use `session` for expensive resources (DB connections, Spark sessions). Use `function` for state that must be isolated between tests.

**Q: `moto` vs `unittest.mock.patch` — when do you use each?**
`moto` creates an in-memory AWS service — your real boto3 calls hit it, which tests the actual call structure and serialization. `mock.patch` replaces the Python object entirely — tests that the function is called but not how the AWS API is used. For S3/SQS/DynamoDB use moto; for non-AWS services use mock.patch.

**Q: How do you ensure test isolation when testing against a real database?**
Use a per-test fixture that yields a cursor and calls `rollback()` in teardown. Each test runs in a transaction that's always rolled back — no state leaks between tests, no need to truncate tables.

**Q: What does `monkeypatch.setenv` do and why is it better than `os.environ["KEY"] = val`?**
`monkeypatch.setenv` automatically reverts the env var after the test. `os.environ` mutation persists across tests, causing test order dependency and flaky tests.
