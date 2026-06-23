# Multithreading Basics in Python

## Why Multithreading Matters
In data engineering, I/O-bound operations (reading files, network calls, database queries) often spend time waiting. Threads allow concurrent execution of these waiting periods, improving throughput without the complexity of multiprocessing.

## Threading vs Multiprocessing
- **Threads**: Share memory space, lightweight, suited for I/O-bound tasks
- **Processes**: Separate memory space, heavier, suited for CPU-bound tasks (bypass GIL)

## Python's Global Interpreter Lock (GIL)
- Only one thread executes Python bytecode at a time
- Threads still provide concurrency for I/O operations (when waiting, GIL released)
- For CPU-bound tasks, use multiprocessing instead
- I/O operations (file, network, database) release GIL during wait

## Creating Threads
### Using `threading.Thread`
```python
import threading
import time

def worker(name, delay):
    print(f"Worker {name} starting")
    time.sleep(delay)
    print(f"Worker {name} finished after {delay}s")

# Create threads
t1 = threading.Thread(target=worker, args=("A", 2))
t2 = threading.Thread(target=worker, args=("B", 1))

# Start threads
t1.start()
t2.start()

# Wait for completion
t1.join()
t2.join()
print("Both workers completed")
```

### Using Lambda Functions
```python
t = threading.Thread(target=lambda: print("Hello from thread"))
t.start()
t.join()
```

### Using Class-Based Threads
```python
class WorkerThread(threading.Thread):
    def __init__(self, name, workload):
        super().__init__()
        self.name = name
        self.workload = workload
    
    def run(self):
        print(f"{self.name} processing {self.workload} units")
        # Simulate work
        result = sum(range(self.workload))
        print(f"{self.name} result: {result}")

t = WorkerThread("Worker-1", 1000000)
t.start()
t.join()
```

## Thread Synchronization
### Locks (Mutex)
```python
import threading

class Counter:
    def __init__(self):
        self.count = 0
        self._lock = threading.Lock()
    
    def increment(self):
        with self._lock:  # Automatically acquires/releases lock
            self.count += 1
    
    def get_count(self):
        with self._lock:
            return self.count

# Usage
counter = Counter()
def worker():
    for _ in range(1000):
        counter.increment()

threads = [threading.Thread(target=worker) for _ in range(5)]
for t in threads:
    t.start()
for t in threads:
    t.join()
print(f"Final count: {counter.count}")  # Should be 5000
```

### RLock (Reentrant Lock)
```python
# Use when same thread needs to acquire lock multiple times
lock = threading.RLock()
with lock:
    with lock:  # Same thread can reacquire
        print("Nested lock works")
```

### Semaphore
```python
# Limit concurrent access to resource
semaphore = threading.Semaphore(3)  # Allow 3 concurrent threads

def worker():
    with semaphore:
        print(f"{threading.current_thread().name} acquired semaphore")
        # Do work that limited to 3 concurrent threads
        time.sleep(1)
        print(f"{threading.current_thread().name} releasing semaphore")

# Start more than 3 threads - only 3 will run concurrently
threads = [threading.Thread(target=worker) for _ in range(10)]
for t in threads:
    t.start()
for t in threads:
    t.join()
```

### Event
```python
# Signal between threads
event = threading.Event()

def waiter():
    print("Waiting for signal...")
    event.wait()  # Blocks until set
    print("Received signal!")

def setter():
    time.sleep(2)
    print("Setting event!")
    event.set()

t1 = threading.Thread(target=waiter)
t2 = threading.Thread(target=setter)
t1.start()
t2.start()
t1.join()
t2.join()
```

### Timer
```python
# Execute function after delay
def delayed_task():
    print("Task executed after delay")

timer = threading.Timer(2.0, delayed_task)
timer.start()
# Can cancel before execution: timer.cancel()
```

## Thread Communication
### Queue (Thread-Safe)
```python
from queue import Queue
import threading
import time

def producer(q):
    for i in range(5):
        item = f"item-{i}"
        q.put(item)
        print(f"Produced {item}")
        time.sleep(0.5)
    q.put(None)  # Sentinel value to signal completion

def consumer(q):
    while True:
        item = q.get()
        if item is None:  # Check for sentinel
            break
        print(f"Consumed {item}")
        q.task_done()

q = Queue()
t1 = threading.Thread(target=producer, args=(q,))
t2 = threading.Thread(target=consumer, args=(q,))

t1.start()
t2.start()
t1.join()
t2.join()
print("Production and consumption complete")
```

## Thread Pools
### Using `ThreadPoolExecutor` (Preferred)
```python
from concurrent.futures import ThreadPoolExecutor, as_completed
import time
import requests

def fetch_url(url):
    try:
        response = requests.get(url, timeout=5)
        return url, len(response.text), None
    except Exception as e:
        return url, None, str(e)

urls = [
    "https://httpbin.org/delay/1",
    "https://httpbin.org/delay/2",
    "https://httpbin.org/status/200",
    "https://httpbin.org/status/404"
]

with ThreadPoolExecutor(max_workers=3) as executor:
    # Submit all tasks
    future_to_url = {executor.submit(fetch_url, url): url for url in urls}
    
    # Process completed futures
    for future in as_completed(future_to_url):
        url = future_to_url[future]
        try:
            url, length, error = future.result()
            if error:
                print(f"{url} failed: {error}")
            else:
                print(f"{url}: {length} characters")
        except Exception as e:
            print(f"{url} generated exception: {e}")
```

### Manual Thread Pool Pattern
```python
import threading
from queue import Queue

def worker(task_queue, result_queue):
    while True:
        task = task_queue.get()
        if task is None:  # Sentinel to shutdown
            task_queue.task_done()
            break
        try:
            result = process_task(task)
            result_queue.put((task, result, None))
        except Exception as e:
            result_queue.put((task, None, str(e)))
        finally:
            task_queue.task_done()

def process_task(task):
    # Simulate work
    time.sleep(0.1)
    return f"processed_{task}"

# Setup queues
task_queue = Queue()
result_queue = Queue()

# Create worker threads
num_workers = 4
workers = []
for i in range(num_workers):
    t = threading.Thread(target=worker, args=(task_queue, result_queue))
    t.start()
    workers.append(t)

# Add tasks
for i in range(10):
    task_queue.put(f"task-{i}")

# Wait for all tasks to be processed
task_queue.join()

# Stop workers
for _ in range(num_workers):
    task_queue.put(None)
for w in workers:
    w.join()

# Collect results
results = []
while not result_queue.empty():
    results.append(result_queue.get())
```

## Daemon Threads
```python
def background_task():
    while True:
        print("Background task running...")
        time.sleep(1)

# Daemon thread dies when main thread exits
daemon_thread = threading.Thread(target=background_task, daemon=True)
daemon_thread.start()

# Main thread does some work then exits
time.sleep(3)
print("Main thread exiting - daemon thread will be killed")
```
- Daemon threads are abruptly stopped when main program exits
- Use for background monitoring/cleanup tasks
- Non-daemon threads keep program alive until they complete

## Thread Local Storage
```python
import threading

# Create thread-local data
local_data = threading.local()

def worker(x):
    # Each thread gets its own storage
    local_data.value = x * 2
    print(f"Thread {threading.current_thread().name}: {local_data.value}")

t1 = threading.Thread(target=worker, args=(5,))
t2 = threading.Thread(target=worker, args=(10,))
t1.start()
t2.start()
t1.join()
t2.join()
```

## Common Patterns in Data Engineering

### Parallel File Processing
```python
from concurrent.futures import ThreadPoolExecutor
import os

def process_file(filepath):
    """Process a single file."""
    try:
        with open(filepath, 'r') as f:
            data = f.read()
        # Simulate processing
        result = len(data.split())
        return filepath, result, None
    except Exception as e:
        return filepath, None, str(e)

def process_directory(directory, max_workers=4):
    """Process all files in directory using thread pool."""
    files = [os.path.join(directory, f) 
             for f in os.listdir(directory) 
             if f.endswith('.txt')]
    
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(process_file, f): f for f in files}
        
        results = []
        for future in as_completed(futures):
            filepath, result, error = future.result()
            if error:
                print(f"Error processing {filepath}: {error}")
            else:
                print(f"{filepath}: {result} words")
                results.append((filepath, result))
    
    return results
```

### Database Connection Pooling Simulation
```python
import threading
import time
import random
from queue import Queue

class ConnectionPool:
    def __init__(self, size=5):
        self._pool = Queue(maxsize=size)
        self._lock = threading.Lock()
        # Initialize pool with dummy connections
        for i in range(size):
            self._pool.put(f"connection-{i}")
    
    def get_connection(self, timeout=10):
        """Get a connection from the pool."""
        return self._pool.get(timeout=timeout)
    
    def return_connection(self, conn):
        """Return a connection to the pool."""
        self._pool.put(conn)
    
    def __enter__(self):
        self.conn = self.get_connection()
        return self.conn
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        self.return_connection(self.conn)

def worker(worker_id, pool):
    with pool as conn:
        print(f"Worker {worker_id} using {conn}")
        # Simulate database work
        time.sleep(random.uniform(0.5, 2.0))
        print(f"Worker {worker_id} finished with {conn}")

# Usage
pool = ConnectionPool(size=3)
threads = []
for i in range(5):
    t = threading.Thread(target=worker, args=(i, pool))
    t.start()
    threads.append(t)

for t in threads:
    t.join()
```

## Best Practices
1. **Use ThreadPoolExecutor**: Prefer high-level APIs over manual thread management
2. **Keep tasks I/O-bound**: Threads excel at waiting, not CPU-intensive work
3. **Avoid shared state**: Minimize locking by using thread-local data or message passing
4. **Use proper synchronization**: Locks, semaphores, queues for coordination
5. **Handle exceptions**: Catch and log exceptions in threads
6. **Set reasonable timeouts**: Prevent indefinite blocking
7. **Consider daemon status**: Use daemon=True for background cleanup tasks
8. **Monitor resource usage**: Too many threads can cause overhead
9. **Use queues for producer-consumer**: Built-in thread-safe communication
10. **Test with mocks**: Replace I/O with mocks for deterministic testing

## Common Gotchas
1. **Deadlocks**: Circular wait for resources (always acquire locks in same order)
2. **Race conditions**: Assuming order of execution without proper synchronization
3. **Forgotten joins**: Main thread exits before workers complete
4. **GIL misconception**: Threads don't speed up CPU-bound Python code
5. **Exception swallowing**: Thread exceptions don't propagate to main thread automatically
6. **Resource leaks**: Not returning connections to pools or closing files
7. **Infinite loops**: Threads without proper exit conditions
8. **Stack overflow**: Deep recursion in threads (smaller stack size than main thread)
9. **Thread safety assumptions**: Assuming built-in types are thread-safe for all operations
10. **Over-threading**: Creating more tasks than beneficial (context switching overhead)

## When to Use Threads vs Alternatives
### Use Threads When:
- I/O-bound operations (file, network, database)
- Need concurrent waiting (multiple API calls)
- Simple parallelism for independent I/O tasks
- Integrating with blocking libraries that release GIL

### Use Multiprocessing When:
- CPU-bound computations
- Need true parallelism (bypass GIL)
- Work can be easily chunked
- Memory sharing not required

### Use Asyncio When:
- High-concurrency I/O (thousands of connections)
- Event-driven architecture
- Already using async libraries (aiohttp, asyncpg)
- Want single-threaded concurrency with event loop

## Interview Questions
**Q: What is the GIL and how does it affect threading?**
A: The Global Interpreter Lock ensures only one thread executes Python bytecode at a time. Threads still provide concurrency for I/O operations because the GIL is released during I/O waits.

**Q: When would you use a Lock vs a Semaphore?**
A: Use a Lock (mutex) for mutual exclusion - only one thread can access resource at a time. Use a Semaphore to limit concurrent access to N threads.

**Q: How do you safely terminate a thread?**
A: Use a sentinel value in a queue, or a threading.Event flag that the thread checks periodically. Avoid forceful termination.

**Q: What's the difference between ThreadPoolExecutor and manually managing threads?**
A: ThreadPoolExecutor handles thread lifecycle, provides futures for result retrieval, and manages queueing automatically.

**Q: How do you share data between threads safely?**
A: Use thread-safe data structures (Queue), synchronization primitives (Lock, Semaphore), or thread-local storage. Avoid sharing mutable state when possible.