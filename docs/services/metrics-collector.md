---
layout: default
title: Metrics Collector
parent: Services
nav_order: 3
---

# Metrics Collector

Collects counter, histogram, and gauge metrics with arbitrary labels. Aggregates raw data into minute and hourly rollups with percentile computation. Supports Web Vitals dashboards.

**Port:** 5012 | **Binary:** `metrics-collector` | **Database:** `metrics.db`

## How it works

1. Receives metric data points via `POST /api/metrics`
2. Stores raw values in SQLite
3. Background thread aggregates raw data into minute buckets (count, sum, min, max, avg, p50, p95, p99)
4. Every 60 aggregation cycles, computes hourly rollups from minute data
5. Retention cleanup removes old data at each tier

## Metric types

| Type | Description | Use case |
|------|-------------|----------|
| `counter` | Monotonically increasing value | Request counts, signups, events |
| `histogram` | Distribution of values | Response times, payload sizes |
| `gauge` | Point-in-time value | Active connections, queue depth |

## Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `API_KEY` | Yes | -- | Authentication key |
| `DATABASE_PATH` | No | `./data/metrics.db` | Path to SQLite database |
| `RETENTION_RAW` | No | `1` | Hours to keep raw data points |
| `RETENTION_MINUTE` | No | `24` | Hours to keep minute aggregates |
| `RETENTION_HOURLY` | No | `30` | Days to keep hourly aggregates |
| `AGGREGATION_INTERVAL` | No | `60` | Seconds between aggregation runs |
| `LOG_LEVEL` | No | `info` | `error`, `warn`, `info`, `debug` |

## API

### POST /api/metrics

Submit a batch of metric data points.

**Headers:** `X-API-Key: <api-key>`, `Content-Type: application/json`

**Body:**

```json
[
  {
    "name": "http_requests_total",
    "type": "counter",
    "value": 1,
    "labels": {"method": "GET", "status": "200"},
    "timestamp": "2026-01-01T12:00:00Z"
  },
  {
    "name": "response_time_ms",
    "type": "histogram",
    "value": 42.5,
    "labels": {"endpoint": "/api/users"}
  }
]
```

- `name`: metric name (max 200 chars)
- `type`: `counter`, `histogram`, or `gauge`
- `value`: numeric value
- `labels`: optional key-value pairs (stored as JSON)
- `timestamp`: optional ISO 8601 (defaults to server time)
- Max 1000 items per batch

**Response:** `202 {"status":"accepted","count":2}`

### GET /api/metrics

Query aggregated metrics.

**Query parameters:**

| Param | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Metric name |
| `period` | No | `1h`, `24h`, `7d`, `30d` (default `24h`) |
| `resolution` | No | `minute`, `hour`, `auto` (default `auto`) |
| `labels` | No | Filter by labels: `key:value,key2:value2` |

Auto resolution: `minute` for periods up to 24h, `hour` for longer periods.

**Response:**

```json
{
  "name": "http_requests_total",
  "resolution": "minute",
  "period": "24h",
  "data": [
    {
      "bucket": "2026-01-01T12:00:00Z",
      "count": 150,
      "sum": 150,
      "min": 1,
      "max": 1,
      "avg": 1,
      "p50": null,
      "p95": null,
      "p99": null
    }
  ]
}
```

Percentiles (p50, p95, p99) are only computed for histogram metrics.

### GET /api/metrics/names

List all known metric names.

**Response:** `{"metrics":[{"name":"http_requests_total","type":"counter"}]}`

### GET /api/dashboard

Web Vitals dashboard data. Returns ratings (good/needs-improvement/poor) and per-page breakdowns.

### GET /health

**Response:** `{"status":"ok"}`

## Aggregation

The background aggregation thread runs every `AGGREGATION_INTERVAL` seconds:

**Minute aggregation:**
- Groups raw data points from the previous minute by (name, labels, type)
- Computes: count, sum, min, max, avg
- For histograms: sorts values and computes p50, p95, p99 using nearest-rank method

**Hourly aggregation** (every 60 aggregation cycles):
- Merges minute aggregates into hourly buckets
- count = SUM(count), sum = SUM(sum), min = MIN(min), max = MAX(max)
- avg = weighted average, percentiles = AVG of minute percentiles

## Database schema

**`metrics_raw`** -- incoming data points:

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER | Primary key |
| `timestamp` | DATETIME | Data point timestamp |
| `name` | VARCHAR(200) | Metric name |
| `labels` | TEXT | JSON-encoded labels |
| `value` | REAL | Metric value |
| `type` | VARCHAR(20) | `counter`, `histogram`, `gauge` |

**`metrics_aggregated`** -- rollup data:

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER | Primary key |
| `bucket` | DATETIME | Time bucket start |
| `resolution` | VARCHAR(10) | `minute` or `hour` |
| `name` | VARCHAR(200) | Metric name |
| `labels` | TEXT | JSON-encoded labels |
| `count` | INTEGER | Number of data points |
| `sum` | REAL | Sum of values |
| `min` | REAL | Minimum value |
| `max` | REAL | Maximum value |
| `avg` | REAL | Average value |
| `p50` | REAL | 50th percentile (histograms only) |
| `p95` | REAL | 95th percentile (histograms only) |
| `p99` | REAL | 99th percentile (histograms only) |

## Background tasks

- **Aggregation:** Runs every `AGGREGATION_INTERVAL` seconds. Computes minute rollups.
- **Hourly rollup:** Every 60 aggregation cycles. Computes hourly aggregates from minute data.
- **Retention cleanup:** Every 60 aggregation cycles. Deletes data older than configured thresholds.

## Rate limits

- 200 requests/minute per IP
- 512KB max request body
