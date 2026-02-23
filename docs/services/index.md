---
layout: default
title: Services
nav_order: 4
has_children: true
---

# Services

Monlight consists of four independent microservices. Each compiles to a single static binary under 20MB with the web UI embedded.

| Service | Port | Purpose |
|---------|------|---------|
| [Error Tracker]({% link services/error-tracker.md %}) | 5010 | Captures and groups exceptions |
| [Log Viewer]({% link services/log-viewer.md %}) | 5011 | Indexes Docker container logs |
| [Metrics Collector]({% link services/metrics-collector.md %}) | 5012 | Collects and aggregates metrics |
| [Browser Relay]({% link services/browser-relay.md %}) | 5013 | Proxies browser telemetry |

All services share common modules from `shared/` for SQLite access, configuration, authentication, and rate limiting.
