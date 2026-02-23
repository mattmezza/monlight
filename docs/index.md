---
layout: default
title: Home
nav_order: 1
permalink: /
---

# Monlight

Self-hosted, lightweight monitoring for small teams. Four services, each under 20MB, running on less than 50MB RAM combined.

Built with Zig and SQLite. No external dependencies. No agents. No complex setup.

## What's in the stack

| Service | Port | Purpose |
|---------|------|---------|
| [Error Tracker]({% link services/error-tracker.md %}) | 5010 | Captures exceptions from backends and browsers |
| [Log Viewer]({% link services/log-viewer.md %}) | 5011 | Indexes Docker container logs with full-text search |
| [Metrics Collector]({% link services/metrics-collector.md %}) | 5012 | Collects counters, histograms, and gauges with tiered retention |
| [Browser Relay]({% link services/browser-relay.md %}) | 5013 | Authenticates and proxies browser telemetry, deobfuscates source maps |

## Client SDKs

| SDK | Package | Runtime |
|-----|---------|---------|
| [JavaScript]({% link sdks/javascript.md %}) | `@monlight/browser` | Browser (zero dependencies, ~5KB gzipped) |
| [Python]({% link sdks/python.md %}) | `monlight` | Python 3.10+ (FastAPI integration included) |

## How it works

```
Browser JS SDK ──► Browser Relay ──► Error Tracker
                        │              Metrics Collector
                        ▼
                   (DSN auth,
                    source maps,
                    CORS)

Python backend ──► Error Tracker (direct, X-API-Key)
                   Metrics Collector (direct, X-API-Key)

Docker containers ──► Log Viewer (reads log files directly)
```

The **browser relay** sits between untrusted browser clients and the backend services. It authenticates requests using DSN public keys, handles CORS, deobfuscates stack traces using uploaded source maps, and forwards data to the error tracker and metrics collector.

Backend services communicate directly with the error tracker and metrics collector using API keys.

The log viewer reads Docker JSON log files from the host filesystem -- no log shipping agent required.

## Quick links

- [Getting Started]({% link getting-started.md %}) -- up and running in 5 minutes
- [Architecture]({% link architecture.md %}) -- how the pieces fit together
- [Configuration Reference]({% link configuration.md %}) -- all environment variables
- [API Reference]({% link api-reference.md %}) -- every endpoint
- [Deployment]({% link deployment.md %}) -- production setup, backups, upgrades
