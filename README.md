# Monlight

A self-hosted, lightweight monitoring stack built with Zig and SQLite. Three independent microservices -- error tracking, log viewing, and metrics collection -- each under 20MB, running on less than 50MB of RAM combined.

## Architecture

```
                        +-----------------+
                        |  Your App       |
                        |  (Python/other) |
                        +--------+--------+
                                 |
                    monlight client
                                 |
              +------------------+------------------+
              |                  |                  |
     +--------v-------+ +-------v--------+ +-------v--------+
     | Error Tracker   | | Log Viewer     | | Metrics        |
     | :5010           | | :5011          | | Collector :5012|
     | POST /api/errors| | Docker log     | | POST /api/     |
     | Web UI          | | ingestion      | |   metrics      |
     | Email alerts    | | FTS5 search    | | Aggregation    |
     +--------+--------+ | SSE live tail  | | Dashboard      |
              |           | Web UI         | | Web UI         |
              |           +-------+--------+ +-------+--------+
              |                   |                  |
        [errors.db]         [logs.db]          [metrics.db]
              SQLite (WAL mode, zero config)
```

Each service is a single static binary with an embedded web UI. No external database, no message queue, no runtime dependencies beyond SQLite.

## Features

**Error Tracker** -- Capture, deduplicate, and alert on application errors.
- Error fingerprinting and deduplication (reopen on recurrence)
- Stores last 5 occurrences per error with full request context
- Postmark email alerts on new errors
- Automatic retention cleanup for resolved errors
- Web UI with filtering by project, environment, and resolution status

**Log Viewer** -- Aggregate and search Docker container logs.
- Docker JSON log file ingestion with cursor tracking (no duplicates on restart)
- Multiline log reassembly (Python tracebacks become single entries)
- FTS5 full-text search across all log messages
- SSE live tail with container and level filtering
- Ring buffer cleanup to cap storage at a configurable limit

**Metrics Collector** -- Ingest, aggregate, and visualize application metrics.
- Batch metric ingestion (counter, histogram, gauge types)
- Automatic minute and hourly aggregation with percentile computation (p50/p95/p99)
- Tiered retention (raw: 1h, minute: 24h, hourly: 30d)
- Dashboard endpoint with request rate, latency, and error rate timeseries
- Web UI with uPlot charts

**Python Client** -- Instrument your Python app with a single function call.
- Async and sync error reporting with PII filtering
- Buffered metrics with background flush
- FastAPI middleware and exception handler
- `setup_monlight()` one-liner for full integration

## Getting Started

### Prerequisites

- Docker and Docker Compose
- (Optional) Python >= 3.10 for the client library

### 1. Clone the repository

```bash
git clone https://github.com/mattmezza/monlight.git
cd monlight
```

### 2. Configure secrets

```bash
cp deploy/secrets.env.example deploy/secrets.env
```

Edit `deploy/secrets.env` and set your API keys:

```env
ERROR_TRACKER_API_KEY=your-error-tracker-key
LOG_VIEWER_API_KEY=your-log-viewer-key
METRICS_COLLECTOR_API_KEY=your-metrics-key

# Optional: email alerting via Postmark
POSTMARK_API_TOKEN=
POSTMARK_FROM_EMAIL=
ALERT_EMAILS=

LOG_LEVEL=INFO
```

### 3. Start the stack

```bash
docker compose -f deploy/docker-compose.monitoring.yml up -d
```

The services will be available at:

| Service           | URL                     | Web UI                  |
|-------------------|-------------------------|-------------------------|
| Error Tracker     | http://localhost:5010    | http://localhost:5010/   |
| Log Viewer        | http://localhost:5011    | http://localhost:5011/   |
| Metrics Collector | http://localhost:5012    | http://localhost:5012/   |

Verify everything is running:

```bash
curl http://localhost:5010/health
curl http://localhost:5011/health
curl http://localhost:5012/health
```

### 4. Instrument your application

Install the Python client:

```bash
pip install monlight[fastapi]
```

Add monitoring to a FastAPI app:

```python
from fastapi import FastAPI
from monlight.integrations.fastapi import setup_monlight

app = FastAPI()

setup_monlight(
    app,
    error_tracker_url="http://localhost:5010",
    metrics_collector_url="http://localhost:5012",
    api_key="your-api-key",
    project="my-app",
    environment="production",
)

@app.get("/")
def index():
    return {"status": "ok"}
```

This automatically captures unhandled exceptions and emits `http_requests_total` and `http_request_duration_seconds` metrics for every request.

### 5. Use the clients directly (optional)

```python
from monlight import ErrorClient, MetricsClient

# Error reporting
error_client = ErrorClient(
    base_url="http://localhost:5010",
    api_key="your-api-key",
    project="my-app",
    environment="production",
)

try:
    risky_operation()
except Exception as e:
    error_client.report_error_sync(e)

# Metrics
metrics = MetricsClient(
    base_url="http://localhost:5012",
    api_key="your-api-key",
)
metrics.start()  # begins background flush every 10s

metrics.counter("user_signups", labels={"plan": "pro"})
metrics.histogram("payment_duration_seconds", value=0.342)
metrics.gauge("active_connections", value=42)

# On shutdown:
metrics.shutdown()
```

## API Reference

All endpoints require an `X-API-Key` header unless noted otherwise.

### Error Tracker (`:5010`)

| Method | Endpoint                     | Description                |
|--------|------------------------------|----------------------------|
| POST   | `/api/errors`                | Report an error            |
| GET    | `/api/errors`                | List errors                |
| GET    | `/api/errors/{id}`           | Get error details          |
| POST   | `/api/errors/{id}/resolve`   | Mark error as resolved     |
| GET    | `/api/projects`              | List known projects        |
| GET    | `/health`                    | Health check (no auth)     |

### Log Viewer (`:5011`)

| Method | Endpoint              | Description                          |
|--------|-----------------------|--------------------------------------|
| GET    | `/api/logs`           | Query logs (filter, search, paginate)|
| GET    | `/api/logs/tail`      | SSE live tail stream                 |
| GET    | `/api/containers`     | List containers with log counts      |
| GET    | `/api/stats`          | Log statistics                       |
| GET    | `/health`             | Health check (no auth)               |

**Query parameters for `/api/logs`:** `container`, `level`, `search` (FTS5), `since`, `until`, `limit` (default 100, max 500), `offset`

### Metrics Collector (`:5012`)

| Method | Endpoint              | Description                          |
|--------|-----------------------|--------------------------------------|
| POST   | `/api/metrics`        | Ingest a batch of metrics            |
| GET    | `/api/metrics`        | Query metric timeseries              |
| GET    | `/api/metrics/names`  | List known metric names and types    |
| GET    | `/api/dashboard`      | Pre-computed dashboard data          |
| GET    | `/health`             | Health check (no auth)               |

**Query parameters for `/api/metrics`:** `name` (required), `period` (1h/24h/7d/30d), `resolution` (minute/hour/auto), `labels` (format: `key:value,key2:value2`)

## Environment Variables

### Error Tracker

| Variable             | Required | Default              | Description                          |
|----------------------|----------|----------------------|--------------------------------------|
| `API_KEY`            | Yes      |                      | API key for authentication           |
| `DATABASE_PATH`      | No       | `./data/errors.db`   | SQLite database path                 |
| `POSTMARK_API_TOKEN` | No       |                      | Postmark API token for email alerts  |
| `POSTMARK_FROM_EMAIL`| No       |                      | Sender address for alert emails      |
| `ALERT_EMAILS`       | No       |                      | Comma-separated recipient addresses  |
| `RETENTION_DAYS`     | No       | `90`                 | Days to keep resolved errors         |
| `BASE_URL`           | No       | `http://localhost:5010` | Base URL for links in alert emails|
| `LOG_LEVEL`          | No       | `INFO`               | Logging verbosity                    |

### Log Viewer

| Variable         | Required | Default                         | Description                          |
|------------------|----------|---------------------------------|--------------------------------------|
| `API_KEY`        | Yes      |                                 | API key for authentication           |
| `CONTAINERS`     | Yes      |                                 | Comma-separated container names      |
| `DATABASE_PATH`  | No       | `./data/logs.db`                | SQLite database path                 |
| `LOG_SOURCES`    | No       | `/var/lib/docker/containers`    | Docker log directory                 |
| `MAX_ENTRIES`    | No       | `100000`                        | Max log entries to retain            |
| `POLL_INTERVAL`  | No       | `2`                             | Seconds between log file polls       |
| `TAIL_BUFFER`    | No       | `65536`                         | SSE tail buffer size                 |
| `LOG_LEVEL`      | No       | `INFO`                          | Logging verbosity                    |

### Metrics Collector

| Variable              | Required | Default            | Description                            |
|-----------------------|----------|--------------------|----------------------------------------|
| `API_KEY`             | Yes      |                    | API key for authentication             |
| `DATABASE_PATH`       | No       | `./data/metrics.db`| SQLite database path                   |
| `RETENTION_RAW`       | No       | `3600`             | Seconds to keep raw metrics            |
| `RETENTION_MINUTE`    | No       | `86400`            | Seconds to keep minute aggregates      |
| `RETENTION_HOURLY`    | No       | `2592000`          | Seconds to keep hourly aggregates      |
| `AGGREGATION_INTERVAL`| No       | `60`               | Seconds between aggregation runs       |
| `LOG_LEVEL`           | No       | `INFO`             | Logging verbosity                      |

## Operations

### Backups

```bash
# Run a backup (SQLite .backup for WAL-safe snapshots, 7-day retention)
bash deploy/backup.sh
```

### Upgrades

```bash
# Pull latest, rebuild, rolling restart with health checks
bash deploy/upgrade.sh

# Skip git pull (rebuild from local code)
bash deploy/upgrade.sh --no-pull

# Skip pre-upgrade backup
bash deploy/upgrade.sh --no-backup
```

The upgrade script tags current images as `:rollback` before rebuilding, so you can revert if something goes wrong.

### Smoke Tests

```bash
# Run end-to-end tests against all services
bash deploy/smoke-test.sh
```

## Development

### Building from source

Each Zig service can be built independently. Requires [Zig 0.13.0](https://ziglang.org/download/).

```bash
# Build and run a service
cd error-tracker
zig build
./zig-out/bin/error-tracker

# Run tests
zig build test
```

### Python client development

```bash
cd clients/python
pip install -e ".[dev]"
pytest
```

### Docker images

```bash
# Build a single service
docker build -t monlight/error-tracker error-tracker/

# Build all via compose
docker compose -f deploy/docker-compose.monitoring.yml build
```

Images are multi-stage Alpine builds, each under 20MB.

## CI/CD

- **Zig Services** -- Tests all three services, builds Docker images, verifies size < 20MB, pushes to `ghcr.io` on `main`
- **Python Client** -- Tests on Python 3.10/3.11/3.12, publishes to PyPI on `python-v*` tags

## Project Structure

```
monlight/
├── error-tracker/       # Error tracking service (Zig)
├── log-viewer/          # Log aggregation service (Zig)
├── metrics-collector/   # Metrics collection service (Zig)
├── shared/              # Shared Zig modules (sqlite, auth, rate limiting, config)
├── clients/python/      # Python client library
├── deploy/              # Docker Compose, backup, upgrade, and smoke test scripts
└── .github/workflows/   # CI/CD pipelines
```

## License

See [LICENSE](LICENSE) for details.
