---
layout: default
title: Getting Started
nav_order: 2
---

# Getting Started

## Prerequisites

- Docker and Docker Compose
- 50MB available RAM (total for all four services)

## 1. Clone and configure

```bash
git clone https://github.com/mattmezza/monlight.git
cd monlight
cp deploy/secrets.env.example deploy/secrets.env
```

Edit `deploy/secrets.env` and set API keys:

```bash
ERROR_TRACKER_API_KEY=<random-32-char-string>
LOG_VIEWER_API_KEY=<random-32-char-string>
METRICS_COLLECTOR_API_KEY=<random-32-char-string>
BROWSER_RELAY_ADMIN_API_KEY=<random-32-char-string>
```

Generate keys with: `openssl rand -hex 16`

## 2. Start the stack

```bash
docker compose up -d
```

This pulls pre-built images from GHCR (~15MB each). All four services start with a 30MB memory limit and automatic restart.

Verify everything is running:

```bash
curl http://localhost:5010/health  # Error Tracker
curl http://localhost:5011/health  # Log Viewer
curl http://localhost:5012/health  # Metrics Collector
curl http://localhost:5013/health  # Browser Relay
```

Each returns `{"status":"ok"}`.

## 3. Send your first error (Python)

```bash
pip install monlight
```

```python
from monlight import ErrorClient

client = ErrorClient(
    base_url="http://localhost:5010",
    api_key="<your-error-tracker-api-key>",
    project="my-app",
)

try:
    1 / 0
except Exception as e:
    client.report_error_sync(e)
```

Open `http://localhost:5010` to see the error in the web UI.

## 4. Send your first error (JavaScript)

First, create a DSN key for the browser relay:

```bash
curl -X POST http://localhost:5013/api/dsn-keys \
  -H "X-API-Key: <your-browser-relay-admin-key>" \
  -H "Content-Type: application/json" \
  -d '{"project": "my-app"}'
```

This returns a `public_key`. Use it in your frontend:

```html
<script>
  window.MonlightConfig = {
    dsn: "<public-key-from-above>",
    endpoint: "http://localhost:5013",
  };
</script>
<script src="https://unpkg.com/@monlight/browser/dist/monlight.min.js"></script>
```

Or with a bundler:

```bash
npm install @monlight/browser
```

```javascript
import { init } from "@monlight/browser";

const monlight = init({
  dsn: "<public-key>",
  endpoint: "http://localhost:5013",
});
```

## 5. Collect metrics

**Python:**

```python
from monlight import MetricsClient

metrics = MetricsClient(
    base_url="http://localhost:5012",
    api_key="<your-metrics-api-key>",
)
metrics.start()

metrics.counter("signups_total", labels={"plan": "pro"})
metrics.histogram("response_time_ms", 42.5, labels={"endpoint": "/api/users"})

# On shutdown:
metrics.shutdown()
```

**JavaScript (automatic):** The browser SDK automatically collects Web Vitals (LCP, INP, CLS, FCP, TTFB) and HTTP request metrics. No additional setup needed.

## 6. View logs

The log viewer reads Docker container logs directly from the host filesystem. Set the `CONTAINERS` env var to filter which containers to monitor:

```bash
# In deploy/secrets.env
CONTAINERS=my_app,my_worker
```

If left empty, all containers are monitored. Open `http://localhost:5011` for the web UI, or query the API:

```bash
curl "http://localhost:5011/api/logs?search=error&level=ERROR&limit=10" \
  -H "X-API-Key: <your-log-viewer-api-key>"
```

## FastAPI integration (recommended)

For FastAPI applications, a single call sets up both error tracking and metrics:

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
)

@app.on_event("shutdown")
def shutdown():
    if clients["metrics_client"]:
        clients["metrics_client"].shutdown()
```

This automatically:
- Captures unhandled exceptions and reports them to the error tracker
- Records `http_requests_total` and `http_request_duration_seconds` for every request

## Next steps

- [Architecture](architecture) -- understand how the stack works
- [Configuration](configuration) -- tune each service
- [Deployment](deployment) -- production setup with TLS, backups, and upgrades
