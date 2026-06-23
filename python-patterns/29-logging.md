# Logging in Python

## Why Logging Matters
Logging is essential for debugging, monitoring, and auditing data pipelines. It provides insight into pipeline execution, errors, and performance without breaking the flow.

## Logging Levels
- `DEBUG`: Detailed information, typically of interest only when diagnosing problems.
- `INFO`: Confirmation that things are working as expected.
- `WARNING`: An indication that something unexpected happened, or indicative of some problem in the near future.
- `ERROR`: Due to a more serious problem, the software has not been able to perform some function.
- `CRITICAL`: A very serious error, indicating that the program itself may be unable to continue running.

## Basic Logging Setup
```python
import logging

# Basic configuration
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler("pipeline.log"),
        logging.StreamHandler()
    ]
)

logger = logging.getLogger(__name__)

logger.info("Pipeline started")
logger.warning("High memory usage detected")
logger.error("Failed to connect to database")
```

## Logger Configuration Best Practices
1. **Use `__name__`**: Creates hierarchical logger names matching module structure.
2. **Avoid basicConfig in libraries**: Only configure logging in the main application.
3. **Set appropriate levels**: Use DEBUG in development, INFO/WARNING in production.
4. **Use formatters**: Include timestamp, logger name, level, and message.
5. **Rotate logs**: Use `RotatingFileHandler` or `TimedRotatingFileHandler` for production.

## Advanced Configuration
```python
import logging
from logging.handlers import RotatingFileHandler

# Create logger
logger = logging.getLogger('pipeline')
logger.setLevel(logging.DEBUG)

# Create formatter
formatter = logging.Formatter(
    '%(asctime)s - %(name)s - %(levelname)s - %(funcName)s:%(lineno)d - %(message)s'
)

# Console handler
console_handler = logging.StreamHandler()
console_handler.setLevel(logging.INFO)
console_handler.setFormatter(formatter)

# File handler with rotation
file_handler = RotatingFileHandler(
    'pipeline.log', 
    maxBytes=10*1024*1024,  # 10 MB
    backupCount=5,
    encoding='utf-8'
)
file_handler.setLevel(logging.DEBUG)
file_handler.setFormatter(formatter)

# Add handlers
logger.addHandler(console_handler)
logger.addHandler(file_handler)

# Prevent duplicate logs
logger.propagate = False
```

## Logging in Data Engineering Contexts

### ETL Pipeline Logging
```python
def extract_data(source):
    logger.info(f"Extracting data from {source}")
    try:
        data = read_from_source(source)
        logger.info(f"Extracted {len(data)} records")
        return data
    except Exception as e:
        logger.error(f"Extraction failed: {e}", exc_info=True)
        raise

def transform_data(data):
    logger.debug(f"Starting transformation on {len(data)} records")
    # ... transformation logic
    logger.info(f"Transformation complete: {len(data)} records output")
    return transformed_data

def load_data(data, target):
    logger.info(f"Loading {len(data)} records to {target}")
    try:
        write_to_target(data, target)
        logger.info("Load successful")
    except Exception as e:
        logger.critical(f"Load failed: {e}", exc_info=True)
        raise
```

### Structured Logging
```python
import json
import logging

class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_entry = {
            'timestamp': self.formatTime(record),
            'logger': record.name,
            'level': record.levelname,
            'message': record.getMessage(),
            'module': record.module,
            'function': record.funcName,
            'line': record.lineno
        }
        if record.exc_info:
            log_entry['exception'] = self.formatException(record.exc_info)
        return json.dumps(log_entry)

# Use JSONFormatter for machine-readable logs
handler = logging.FileHandler('pipeline.json.log')
handler.setFormatter(JSONFormatter())
logger.addHandler(handler)
```

## Logging Best Practices
1. **Log at appropriate levels**: Use DEBUG for detailed tracing, INFO for milestones, WARNING for recoverable issues, ERROR for failures, CRITICAL for fatal issues.
2. **Include context**: Log relevant IDs (batch ID, run ID, record keys) for traceability.
3. **Avoid logging sensitive data**: Never log passwords, PII, or tokens.
4. **Use exception logging**: `logger.error("Message", exc_info=True)` includes stack trace.
5. **Log performance**: Time critical sections and log durations.
6. **Centralize configuration**: Configure logging once at application startup.
7. **Test logging**: Verify logs appear as expected in different environments.

## Common Gotchas
1. **Duplicate logs**: Caused by adding multiple handlers or propagating to root logger.
2. **Missing logs**: Logger level higher than message level, or handler not configured.
3. **Performance overhead**: Excessive DEBUG logging in production can impact performance.
4. **Log rotation**: Unrotated logs can fill disk space.

## Interview Questions
**Q: What's the difference between `logging.basicConfig()` and configuring handlers manually?**
A: `basicConfig()` is a quick setup for simple applications. Manual configuration gives full control over handlers, formatters, and levels.

**Q: How do you prevent duplicate log messages?**
A: Set `logger.propagate = False` and ensure handlers are not added multiple times.

**Q: What is the purpose of `exc_info=True` in logging?**
A: It includes exception stack trace in the log output.

**Q: How would you log JSON-formatted logs for ingestion by ELK stack?**
A: Use a custom formatter that outputs JSON string, or use libraries like `python-json-logger`.

**Q: When would you use a RotatingFileHandler?**
A: For production applications where log files need to be rotated based on size or time to prevent disk exhaustion.