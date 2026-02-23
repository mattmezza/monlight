---
layout: default
title: API Reference
nav_order: 7
---

# API Reference

All endpoints use JSON. Authentication is via `X-API-Key` header unless otherwise noted. All services expose `GET /health` returning `{"status":"ok"}` (no auth required).

## Error Tracker (:5010)

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/errors` | API Key | Submit error report |
| GET | `/api/errors` | API Key | List errors (filterable) |
| GET | `/api/errors/{id}` | API Key | Error details with occurrences |
| POST | `/api/errors/{id}/resolve` | API Key | Mark error resolved |
| GET | `/api/projects` | API Key | List projects |
| GET | `/health` | None | Health check |

**POST /api/errors** body:

```json
{
  "project": "my-app",
  "environment": "prod",
  "exception_type": "ValueError",
  "message": "invalid input",
  "traceback": "Traceback (most recent call last):\n  ...",
  "request_url": "/api/users",
  "request_method": "POST",
  "request_headers": {"Accept": "application/json"},
  "user_id": "user-42",
  "extra": {"key": "value"}
}
```

Returns `201` (new) or `200` (existing fingerprint).

**GET /api/errors** query params: `project`, `environment`, `resolved` (bool), `search`, `source`, `limit` (default 50, max 200), `offset`.

---

## Log Viewer (:5011)

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/api/logs` | API Key | Query logs with FTS5 search |
| GET | `/api/logs/tail` | API Key | SSE live tail |
| GET | `/api/logs/containers` | API Key | List containers |
| GET | `/api/logs/stats` | API Key | Aggregated statistics |
| GET | `/health` | None | Health check |

**GET /api/logs** query params: `container`, `level` (DEBUG/INFO/WARNING/ERROR/CRITICAL), `search` (FTS5 MATCH), `since`, `until` (ISO 8601), `limit` (default 100, max 500), `offset`.

**GET /api/logs/tail** query params: `container`, `level`. Returns SSE stream with `event: log` (JSON data), `event: heartbeat`, `event: close`. Max 5 concurrent connections, 30min timeout.

---

## Metrics Collector (:5012)

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/metrics` | API Key | Submit metrics batch |
| GET | `/api/metrics` | API Key | Query aggregated metrics |
| GET | `/api/metrics/names` | API Key | List metric names |
| GET | `/api/dashboard` | API Key | Web Vitals dashboard |
| GET | `/health` | None | Health check |

**POST /api/metrics** body (JSON array, max 1000 items):

```json
[
  {
    "name": "http_requests_total",
    "type": "counter",
    "value": 1,
    "labels": {"method": "GET", "status": "200"},
    "timestamp": "2026-01-01T12:00:00Z"
  }
]
```

Returns `202`.

**GET /api/metrics** query params: `name` (required), `period` (`1h`/`24h`/`7d`/`30d`, default `24h`), `resolution` (`minute`/`hour`/`auto`, default `auto`), `labels` (`key:value,key2:value2`).

---

## Browser Relay (:5013)

### Admin endpoints (X-API-Key auth)

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/dsn-keys` | Admin Key | Create DSN key |
| GET | `/api/dsn-keys` | Admin Key | List DSN keys |
| DELETE | `/api/dsn-keys/{id}` | Admin Key | Deactivate DSN key |
| POST | `/api/source-maps` | Admin Key | Upload source map |
| GET | `/api/source-maps` | Admin Key | List source maps |
| DELETE | `/api/source-maps/{id}` | Admin Key | Delete source map |

**POST /api/dsn-keys** body: `{"project":"my-app"}`. Returns `201 {"public_key":"..."}`.

**POST /api/source-maps** body:

```json
{
  "project": "my-app",
  "release": "1.2.3",
  "file_url": "/assets/app.min.js",
  "map_content": "{\"version\":3,...}"
}
```

### Browser endpoints (X-Monlight-Key auth)

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/api/browser/errors` | DSN Key | Submit browser error |
| POST | `/api/browser/metrics` | DSN Key | Submit browser metrics |

**POST /api/browser/errors** body:

```json
{
  "type": "TypeError",
  "message": "Cannot read property 'x' of undefined",
  "stack": "TypeError: ...\n    at app.min.js:1:234",
  "url": "https://example.com",
  "user_agent": "Mozilla/5.0 ...",
  "session_id": "uuid",
  "release": "1.2.3",
  "environment": "prod",
  "context": {}
}
```

**POST /api/browser/metrics** body:

```json
{
  "metrics": [
    {"name": "web_vitals_lcp", "type": "histogram", "value": 1250.5, "labels": {"page": "/"}}
  ],
  "session_id": "uuid",
  "url": "https://example.com/page"
}
```

---

## Rate limits

| Service | Requests/min | Max body |
|---------|-------------|----------|
| Error Tracker | 100 | 256KB |
| Log Viewer | 60 | 64KB |
| Metrics Collector | 200 | 512KB |
| Browser Relay | 300 | 64KB |

Rate-limited requests receive `429 Too Many Requests`.

## Error codes

| Status | Meaning |
|--------|---------|
| 200 | Success (existing resource updated) |
| 201 | Created |
| 202 | Accepted (async processing) |
| 400 | Bad request (invalid JSON, missing fields) |
| 401 | Unauthorized (missing or invalid API key) |
| 404 | Not found |
| 413 | Payload too large |
| 429 | Rate limited |
| 500 | Internal server error |
