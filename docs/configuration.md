---
layout: default
title: Configuration
nav_order: 6
---

# Configuration Reference

All services are configured via environment variables. No configuration files.

## Error Tracker

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `API_KEY` | Yes | -- | API key for authentication |
| `DATABASE_PATH` | No | `./data/errors.db` | SQLite database path |
| `LOG_LEVEL` | No | `info` | `error`, `warn`, `info`, `debug` |
| `RETENTION_DAYS` | No | `90` | Days before resolved errors are deleted |
| `POSTMARK_API_TOKEN` | No | -- | Postmark token for email alerts |
| `POSTMARK_FROM_EMAIL` | No | -- | Sender email for alerts |
| `ALERT_EMAILS` | No | -- | Comma-separated alert recipients |

## Log Viewer

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `API_KEY` | Yes | -- | API key for authentication |
| `DATABASE_PATH` | No | `./data/logs.db` | SQLite database path |
| `CONTAINERS` | No | *(empty = all)* | Comma-separated container names to monitor |
| `LOG_SOURCES` | No | `/var/lib/docker/containers` | Docker containers directory |
| `MAX_ENTRIES` | No | `100000` | Max log entries (ring buffer) |
| `POLL_INTERVAL` | No | `2` | Seconds between log file polls |
| `TAIL_BUFFER` | No | `65536` | Bytes to read from file end on first run |
| `LOG_LEVEL` | No | `info` | `error`, `warn`, `info`, `debug` |

## Metrics Collector

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `API_KEY` | Yes | -- | API key for authentication |
| `DATABASE_PATH` | No | `./data/metrics.db` | SQLite database path |
| `RETENTION_RAW` | No | `1` | Hours to keep raw data |
| `RETENTION_MINUTE` | No | `24` | Hours to keep minute aggregates |
| `RETENTION_HOURLY` | No | `30` | Days to keep hourly aggregates |
| `AGGREGATION_INTERVAL` | No | `60` | Seconds between aggregation runs |
| `LOG_LEVEL` | No | `info` | `error`, `warn`, `info`, `debug` |

## Browser Relay

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ADMIN_API_KEY` | Yes | -- | API key for admin endpoints |
| `ERROR_TRACKER_URL` | Yes | -- | Internal error tracker URL |
| `ERROR_TRACKER_API_KEY` | Yes | -- | Error tracker API key |
| `METRICS_COLLECTOR_URL` | Yes | -- | Internal metrics collector URL |
| `METRICS_COLLECTOR_API_KEY` | Yes | -- | Metrics collector API key |
| `DATABASE_PATH` | No | `./data/browser-relay.db` | SQLite database path |
| `CORS_ORIGINS` | No | -- | Comma-separated allowed origins |
| `MAX_BODY_SIZE` | No | `65536` | Max request body in bytes |
| `RATE_LIMIT` | No | `300` | Requests per minute per key |
| `RETENTION_DAYS` | No | `90` | Days to keep source maps |
| `LOG_LEVEL` | No | `info` | `error`, `warn`, `info`, `debug` |

## secrets.env template

```bash
# Required - generate with: openssl rand -hex 16
ERROR_TRACKER_API_KEY=<random-32-char-string>
LOG_VIEWER_API_KEY=<random-32-char-string>
METRICS_COLLECTOR_API_KEY=<random-32-char-string>
BROWSER_RELAY_ADMIN_API_KEY=<random-32-char-string>

# Optional
# CORS_ORIGINS=https://yourdomain.com,https://www.yourdomain.com
# CONTAINERS=my_app,my_worker
# LOG_LEVEL=info

# Email alerts (optional)
# POSTMARK_API_TOKEN=
# POSTMARK_FROM_EMAIL=errors@example.com
# ALERT_EMAILS=admin@example.com
```
