---
layout: default
title: Python SDK
parent: Client SDKs
nav_order: 2
---

# Python SDK

`monlight` -- Python client for error tracking and metrics collection. Includes a FastAPI integration.

## Installation

```bash
pip install monlight
```

For FastAPI integration:

```bash
pip install monlight[fastapi]
```

Requires Python 3.10+. Only runtime dependency is `httpx`.

## Error tracking

```python
from monlight import ErrorClient

client = ErrorClient(
    base_url="http://localhost:5010",
    api_key="<your-api-key>",
    project="my-app",
    environment="prod",
)
```

### ErrorClient parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `base_url` | str | **(required)** | Error tracker URL |
| `api_key` | str | **(required)** | API key |
| `project` | str | `"default"` | Project name |
| `environment` | str | `"prod"` | Environment name |
| `timeout` | float | `5.0` | HTTP timeout in seconds |
| `excluded_headers` | set[str] | -- | Additional header names to strip (PII) |

### Reporting errors

```python
# Async
await client.report_error(exception, request_context={
    "request_url": "/api/users",
    "request_method": "POST",
    "request_headers": {"Content-Type": "application/json"},
    "user_id": "user-42",
    "extra": {"booking_id": 123},
})

# Sync
client.report_error_sync(exception)
```

Both methods are fire-and-forget: errors during reporting are logged as warnings but never raised.

### PII filtering

These headers are always stripped before sending:

- `authorization`
- `cookie`
- `set-cookie`
- `x-api-key`

Add more via the `excluded_headers` constructor parameter.

## Metrics collection

```python
from monlight import MetricsClient

metrics = MetricsClient(
    base_url="http://localhost:5012",
    api_key="<your-api-key>",
    flush_interval=10.0,
)
metrics.start()
```

### MetricsClient parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `base_url` | str | **(required)** | Metrics collector URL |
| `api_key` | str | **(required)** | API key |
| `flush_interval` | float | `10.0` | Seconds between automatic flushes |
| `timeout` | float | `5.0` | HTTP timeout in seconds |

### Recording metrics

```python
# Counter (default value = 1)
metrics.counter("signups_total", labels={"plan": "pro"})
metrics.counter("page_views", labels={"page": "/home"}, value=5)

# Histogram
metrics.histogram("response_time_ms", 42.5, labels={"endpoint": "/api/users"})

# Gauge
metrics.gauge("active_connections", 15, labels={"service": "api"})
```

### Lifecycle

```python
metrics.start()     # Start periodic flush timer (idempotent)
metrics.flush()     # Flush buffered metrics immediately
metrics.shutdown()  # Stop timer and flush remaining metrics
```

Metrics are buffered in memory and flushed as a batch POST every `flush_interval` seconds. The flush timer runs on a daemon thread. If a flush fails, buffered metrics are dropped (not retried).

Thread-safe: multiple threads can call `counter`/`histogram`/`gauge` concurrently.

## FastAPI integration

Single-call setup for both error tracking and metrics:

```python
from fastapi import FastAPI
from monlight.integrations.fastapi import setup_monlight

app = FastAPI()

clients = setup_monlight(
    app,
    error_tracker_url="http://localhost:5010",
    metrics_collector_url="http://localhost:5012",
    api_key="<your-api-key>",
    project="my-app",
    environment="prod",
)

@app.on_event("shutdown")
def shutdown():
    if clients["metrics_client"]:
        clients["metrics_client"].shutdown()
```

### setup_monlight parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `app` | FastAPI | **(required)** | FastAPI application |
| `error_tracker_url` | str | `None` | Error tracker URL (omit to disable) |
| `metrics_collector_url` | str | `None` | Metrics collector URL (omit to disable) |
| `api_key` | str | **(required)** | Shared API key |
| `project` | str | `"default"` | Project name for error reports |
| `environment` | str | `"prod"` | Environment name |
| `flush_interval` | float | `10.0` | Metrics flush interval |

**Returns:** `{"error_client": ErrorClient | None, "metrics_client": MetricsClient | None}`

### What it does

**Error tracking** (when `error_tracker_url` is set):
- Registers an exception handler for all `Exception` types
- Captures request URL, method, and headers
- Reports errors as fire-and-forget async tasks
- Returns `500 {"detail": "Internal server error"}` to the client

**Metrics** (when `metrics_collector_url` is set):
- Adds middleware that records for every request:
  - `http_requests_total` (counter) -- labels: `method`, `endpoint`, `status`
  - `http_request_duration_seconds` (histogram) -- labels: `method`, `endpoint`, `status`
- Endpoint labels use FastAPI path templates (e.g., `/users/{id}` not `/users/42`)

### Using components separately

You can also use the middleware and exception handler individually:

```python
from monlight.integrations.fastapi import MonlightMiddleware, MonlightExceptionHandler

app.add_middleware(MonlightMiddleware, metrics_client=metrics_client)
app.add_exception_handler(Exception, MonlightExceptionHandler)
app.state.monlight_error_client = error_client
```
