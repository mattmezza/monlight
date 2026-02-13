# Monlight

A self-hosted, lightweight monitoring stack built with Zig and SQLite. Four independent microservices -- error tracking, log viewing, metrics collection, and a browser relay -- each under 20MB, running on less than 50MB of RAM combined.

## Architecture

```
                    Browser JS SDK                     Python Client
                  (@monlight/browser)                    (monlight)
                         |                                  |
                         v                                  |
               +---------+----------+          +------------+------------+
               | Browser Relay      |          |            |            |
               | :5013              |          |            |            |
               | DSN auth, CORS     |          |            |            |
               | Source map support  |          |            |            |
               +---------+----------+          |            |            |
                    |          |                |            |            |
                    v          v                v            |            v
           +-------+-------+  |  +-------+--------+  +-----+------+
           | Error Tracker |  +->| Metrics        |  | Log Viewer |
           | :5010         |     | Collector :5012|  | :5011      |
           | POST /api/    |     | POST /api/     |  | Docker log |
           |   errors      |     |   metrics      |  | ingestion  |
           | Email alerts  |     | Aggregation    |  | FTS5 search|
           | Web UI        |     | Dashboard      |  | SSE tail   |
           +-------+-------+    | Web UI         |  | Web UI     |
                   |             +-------+--------+  +-----+------+
                   |                     |                  |
             [errors.db]          [metrics.db]          [logs.db]
                   SQLite (WAL mode, zero config)
```

Each service is a single static binary with an embedded web UI. No external database, no message queue, no runtime dependencies beyond SQLite.

## Quick Start

### Using pre-built images (recommended)

```bash
# 1. Clone the repo (for compose file and config templates)
git clone https://github.com/mattmezza/monlight.git
cd monlight

# 2. Configure secrets
cp deploy/secrets.env.example deploy/secrets.env
# Edit deploy/secrets.env and set your API keys

# 3. Start the stack
docker compose up -d
```

### Building from source

```bash
# Build and run all services from source
docker compose -f deploy/docker-compose.monitoring.yml up -d --build
```

The services will be available at:

| Service           | URL                     | Web UI                  |
|-------------------|-------------------------|-------------------------|
| Error Tracker     | http://localhost:5010    | http://localhost:5010/   |
| Log Viewer        | http://localhost:5011    | http://localhost:5011/   |
| Metrics Collector | http://localhost:5012    | http://localhost:5012/   |
| Browser Relay     | http://localhost:5013    | --                      |

Verify everything is running:

```bash
curl http://localhost:5010/health
curl http://localhost:5011/health
curl http://localhost:5012/health
curl http://localhost:5013/health
```

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

**Browser Relay** -- Browser-facing ingestion proxy for the JS SDK.
- DSN key authentication (no server API keys exposed to the browser)
- CORS handling with per-project origin validation
- Source map upload and stack trace deobfuscation
- Forwards errors and metrics to the backend services

**JavaScript SDK** (`@monlight/browser`) -- Lightweight browser monitoring.
- Automatic error capture (unhandled errors + promise rejections)
- Web Vitals collection (LCP, FID, CLS, INP, TTFB)
- Network request monitoring (fetch/XHR timing and errors)
- Under 5KB gzipped

**Python Client** (`monlight`) -- Instrument your Python app with a single function call.
- Async and sync error reporting with PII filtering
- Buffered metrics with background flush
- FastAPI middleware and exception handler
- `setup_monlight()` one-liner for full integration

## Client SDKs

### Python

```bash
pip install monlight[fastapi]
```

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
```

Or use the clients directly:

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
metrics = MetricsClient(base_url="http://localhost:5012", api_key="your-api-key")
metrics.start()

metrics.counter("user_signups", labels={"plan": "pro"})
metrics.histogram("payment_duration_seconds", value=0.342)
metrics.gauge("active_connections", value=42)

metrics.shutdown()  # flush remaining on app shutdown
```

### JavaScript (Browser)

```bash
npm install @monlight/browser
```

```html
<script type="module">
  import { Monlight } from '@monlight/browser';

  const monitor = new Monlight({
    dsn: 'https://your-key@your-domain.com/browser-relay',
  });
</script>
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

### Browser Relay (`:5013`)

| Method | Endpoint              | Description                          |
|--------|-----------------------|--------------------------------------|
| POST   | `/api/errors`         | Ingest browser errors (DSN auth)     |
| POST   | `/api/metrics`        | Ingest browser metrics (DSN auth)    |
| POST   | `/api/sourcemaps`     | Upload source maps (admin auth)      |
| GET    | `/api/dsn-keys`       | List DSN keys (admin auth)           |
| POST   | `/api/dsn-keys`       | Create DSN key (admin auth)          |
| GET    | `/health`             | Health check (no auth)               |

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

### Browser Relay

| Variable                  | Required | Default  | Description                                |
|---------------------------|----------|----------|--------------------------------------------|
| `ADMIN_API_KEY`           | Yes      |          | Admin API key for DSN key management       |
| `ERROR_TRACKER_URL`       | Yes      |          | Internal URL of the error tracker service  |
| `ERROR_TRACKER_API_KEY`   | Yes      |          | API key for the error tracker              |
| `METRICS_COLLECTOR_URL`   | Yes      |          | Internal URL of the metrics collector      |
| `METRICS_COLLECTOR_API_KEY`| Yes     |          | API key for the metrics collector          |
| `CORS_ORIGINS`            | No       |          | Comma-separated allowed origins            |
| `DATABASE_PATH`           | No       | `./data/browser-relay.db` | SQLite database path          |
| `LOG_LEVEL`               | No       | `INFO`   | Logging verbosity                          |

## Operations

### Backups

```bash
# SQLite .backup for WAL-safe snapshots, 7-day retention
bash deploy/backup.sh
```

### Upgrades

```bash
# Pull latest, rebuild, rolling restart with health checks
bash deploy/upgrade.sh

# Skip git pull (rebuild from local code)
bash deploy/upgrade.sh --no-pull

# Upgrade a single service
bash deploy/upgrade.sh error-tracker
```

The upgrade script tags current images as `:rollback` before rebuilding, so you can revert if something goes wrong.

### Smoke Tests

```bash
# Run end-to-end tests against all services
bash deploy/smoke-test.sh
```

## Releasing New Versions

Each component is released independently. The `Makefile` automates the entire flow: bumping version files, committing, tagging, and pushing. CI then builds, publishes, and creates a GitHub Release.

```bash
# Show current versions of all components
make versions

# Release a single service (Docker image to GHCR)
make release-error-tracker V=0.2.0
make release-log-viewer V=0.2.0
make release-metrics-collector V=0.2.0
make release-browser-relay V=0.2.0

# Release all 4 Docker services at the same version
make release-services V=0.2.0

# Release the Python client to PyPI
make release-python V=0.2.0

# Release the JS SDK to npm
make release-js V=0.2.0

# Release everything at once
make release-all V=0.2.0
```

Each target validates semver, checks for a clean working tree, updates the version in the right files, commits, tags, and pushes. CI takes over from there.

| Component | Tag | Publishes to |
|---|---|---|
| error-tracker | `error-tracker-v*` | `ghcr.io/mattmezza/monlight/error-tracker` |
| log-viewer | `log-viewer-v*` | `ghcr.io/mattmezza/monlight/log-viewer` |
| metrics-collector | `metrics-collector-v*` | `ghcr.io/mattmezza/monlight/metrics-collector` |
| browser-relay | `browser-relay-v*` | `ghcr.io/mattmezza/monlight/browser-relay` |
| Python client | `python-v*` | [PyPI](https://pypi.org/project/monlight/) |
| JS SDK | `js-v*` | [npm](https://www.npmjs.com/package/@monlight/browser) |

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

### JS SDK development

```bash
cd clients/js
npm install
npm test
npm run build
```

### Docker images

```bash
# Build a single service
docker build -t monlight/error-tracker -f error-tracker/Dockerfile .

# Build all via compose
docker compose -f deploy/docker-compose.monitoring.yml build
```

Images are multi-stage Alpine builds, each under 20MB.

## Project Structure

```
monlight/
├── error-tracker/       # Error tracking service (Zig)
├── log-viewer/          # Log aggregation service (Zig)
├── metrics-collector/   # Metrics collection service (Zig)
├── browser-relay/       # Browser ingestion proxy (Zig)
├── shared/              # Shared Zig modules (sqlite, auth, rate limiting, config)
├── clients/
│   ├── js/              # @monlight/browser - JS SDK (TypeScript)
│   └── python/          # monlight - Python client library
├── deploy/              # Docker Compose, backup, upgrade, and smoke test scripts
├── docker-compose.yml   # Pre-built images from GHCR (for users)
└── .github/workflows/   # CI/CD pipelines
```

## License

MIT. See [LICENSE](LICENSE) for details.
