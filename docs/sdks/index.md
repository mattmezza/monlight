---
layout: default
title: Client SDKs
nav_order: 5
has_children: true
---

# Client SDKs

| SDK | Package | Runtime |
|-----|---------|---------|
| [JavaScript]({% link sdks/javascript.md %}) | `@monlight/browser` | Browser (zero runtime dependencies, ~5KB gzipped) |
| [Python]({% link sdks/python.md %}) | `monlight` | Python 3.10+ (FastAPI integration included) |

Both SDKs are fire-and-forget: telemetry errors never crash your application. Failed requests are silently dropped.
