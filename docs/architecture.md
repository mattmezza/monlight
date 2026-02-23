---
layout: default
title: Architecture
nav_order: 3
---

# Architecture

## Design principles

- **Single binary per service.** Each service compiles to one static binary under 20MB with the web UI embedded.
- **SQLite for storage.** WAL mode for concurrent reads during writes. No external database to manage.
- **No agents.** The log viewer reads Docker log files directly. No sidecar or log shipper needed.
- **Fire-and-forget clients.** SDK errors never crash your application. Failed telemetry is silently dropped.
- **Minimal resource usage.** Each service runs within a 30MB memory limit. The full stack uses under 50MB.

## System overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Your Infrastructure                                            │
│                                                                 │
│  ┌──────────────┐    ┌──────────────────────────────────────┐   │
│  │ Browser      │    │ Docker Host                          │   │
│  │ (JS SDK)     │    │                                      │   │
│  │              │    │  ┌────────────┐  ┌────────────────┐  │   │
│  └──────┬───────┘    │  │ App        │  │ /var/lib/docker│  │   │
│         │            │  │ Container  │  │ /containers/   │  │   │
│         │            │  │ (Python    │  │ (JSON logs)    │  │   │
│         │            │  │  SDK)      │  └───────┬────────┘  │   │
│         │            │  └─────┬──────┘          │           │   │
│         │            └────────┼──────────────────┼───────────┘   │
│         │                     │                  │               │
│  ┌──────▼───────┐    ┌───────▼──────┐  ┌────────▼─────────┐    │
│  │ Browser      │    │ Error        │  │ Log Viewer       │    │
│  │ Relay        │    │ Tracker      │  │ :5011            │    │
│  │ :5013        │    │ :5010        │  │                  │    │
│  │              │    │              │  │ FTS5 search      │    │
│  │ DSN auth     ├───►│ Fingerprint  │  │ SSE live tail    │    │
│  │ CORS         │    │ Dedup        │  │ Ring buffer      │    │
│  │ Source maps  │    │ Alerts       │  └──────────────────┘    │
│  │              │    └──────────────┘                           │
│  │              │    ┌──────────────┐                           │
│  │              ├───►│ Metrics      │                           │
│  │              │    │ Collector    │                           │
│  └──────────────┘    │ :5012        │                           │
│                      │              │                           │
│                      │ Aggregation  │                           │
│                      │ Retention    │                           │
│                      │ Web Vitals   │                           │
│                      └──────────────┘                           │
└─────────────────────────────────────────────────────────────────┘
```

## Service responsibilities

### Error Tracker (:5010)

Receives exception reports from backends (directly) and browsers (via relay). Groups errors by fingerprint -- an MD5 hash of `{project}:{exception_type}:{file}:{line}`. Duplicate errors increment a counter instead of creating new records. Keeps the last 5 occurrences per error group. Resolved errors reopen automatically on recurrence. Optional email alerts via Postmark.

### Log Viewer (:5011)

Background thread polls Docker JSON log files from the host filesystem. Parses and reassembles multiline entries (Python tracebacks, etc.). Stores in SQLite with FTS5 full-text search. Supports SSE live tail for real-time streaming. Ring buffer caps storage at a configurable maximum entry count.

### Metrics Collector (:5012)

Accepts counter, histogram, and gauge metrics with arbitrary labels. Background thread aggregates raw data into minute and hourly rollups with percentile computation (p50, p95, p99). Three-tier retention: raw (1h default), minute (24h), hourly (30d). Dashboard endpoint with Web Vitals support.

### Browser Relay (:5013)

Public-facing proxy for browser telemetry. Authenticates requests using DSN public keys (not API keys -- safe to expose in client-side code). Handles CORS. Accepts source map uploads and deobfuscates minified stack traces before forwarding to the error tracker. Forwards metrics to the metrics collector with enriched labels.

## Authentication model

Two auth mechanisms serve different trust levels:

| Mechanism | Header | Trust level | Used by |
|-----------|--------|-------------|---------|
| API Key | `X-API-Key` | High (server-to-server) | Python SDK, admin endpoints, inter-service |
| DSN Key | `X-Monlight-Key` | Low (public, browser-safe) | JavaScript SDK |

API keys authenticate trusted backends directly to services. DSN keys are public tokens that only grant access to submit telemetry through the browser relay -- they cannot read data or manage configuration.

The browser relay holds API keys for the error tracker and metrics collector internally, forwarding authenticated requests on behalf of browser clients.

## Data storage

Each service owns a single SQLite database in WAL mode:

| Service | Database | Key tables |
|---------|----------|------------|
| Error Tracker | `errors.db` | `errors`, `error_occurrences` |
| Log Viewer | `logs.db` | `log_entries`, `log_entries_fts`, `cursors` |
| Metrics Collector | `metrics.db` | `metrics_raw`, `metrics_aggregated` |
| Browser Relay | `browser-relay.db` | `dsn_keys`, `source_maps` |

Schema migrations are tracked in a `_meta` table. Services apply migrations automatically on startup.

## Shared modules

All four Zig services share common code from the `shared/` directory:

| Module | Purpose |
|--------|---------|
| `sqlite.zig` | SQLite C wrapper with prepared statements, WAL mode, migration runner |
| `config.zig` | Environment variable parsing (required/optional, typed) |
| `auth.zig` | API key authentication middleware with constant-time comparison |
| `rate_limit.zig` | Sliding window rate limiter with body size enforcement |

## Technology choices

| Component | Technology | Why |
|-----------|-----------|-----|
| Backend | Zig 0.13.0 | Single static binary, minimal memory, no runtime dependencies |
| Database | SQLite (WAL) | Zero-config, embedded, reliable, good enough for monitoring workloads |
| Search | FTS5 | Built into SQLite, fast full-text search without an external engine |
| JS SDK | TypeScript + esbuild | Zero runtime dependencies, ~5KB gzipped |
| Python SDK | httpx | Async-first HTTP client, widely used |
| Build | Docker multi-stage (Alpine 3.21) | Minimal images (~15MB), reproducible builds |
