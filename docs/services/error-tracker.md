---
layout: default
title: Error Tracker
parent: Services
nav_order: 1
---

# Error Tracker

Captures and groups exceptions from backends and browsers. Deduplicates errors by fingerprint, tracks occurrence count, and optionally sends email alerts.

**Port:** 5010 | **Binary:** `error-tracker` | **Database:** `errors.db`

## How it works

1. Receives an exception via `POST /api/errors`
2. Computes a fingerprint: MD5 of `{project}:{exception_type}:{file}:{line}`
3. If the fingerprint already exists:
   - Increments the counter
   - Updates `last_seen`
   - Stores the occurrence (keeps last 5 per error group)
   - Reopens if previously resolved
4. If new: creates the error record and optionally sends an email alert

Stack traces from both Python and JavaScript (Chrome V8, Firefox, Safari) are parsed to extract file and line information for fingerprinting.

## Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `API_KEY` | Yes | -- | Authentication key for all API requests |
| `DATABASE_PATH` | No | `./data/errors.db` | Path to SQLite database |
| `LOG_LEVEL` | No | `info` | `error`, `warn`, `info`, `debug` |
| `RETENTION_DAYS` | No | `90` | Days to keep resolved errors before deletion |
| `SMTP_HOST` | No | -- | SMTP server host for email alerts |
| `SMTP_PORT` | No | `25` | SMTP server port (use 587 for STARTTLS) |
| `SMTP_USERNAME` | No | -- | SMTP username for authentication |
| `SMTP_PASSWORD` | No | -- | SMTP password for authentication |
| `SMTP_FROM` | No | `errors@example.com` | Sender email for alerts |
| `ALERT_EMAILS` | No | -- | Comma-separated recipient emails |

### SMTP and STARTTLS

STARTTLS is automatically detected and used when the server advertises it in the EHLO response. No additional configuration is needed -- just point `SMTP_HOST` and `SMTP_PORT` at your mail server:

- **Port 587** (recommended): STARTTLS upgrade from plain to encrypted
- **Port 25**: Plain SMTP (STARTTLS used if advertised)

Authentication (`SMTP_USERNAME`/`SMTP_PASSWORD`) works over both plain and STARTTLS connections.

## Web UI

The error tracker includes a built-in web interface at `/`. The UI requires an API key for authentication -- on first visit, a prompt asks for the key, which is stored in the browser's localStorage.

The UI supports filtering by project, resolution status, source (browser/server), and text search.

## API

### POST /api/errors

Submit an error report.

**Headers:** `X-API-Key: <api-key>`, `Content-Type: application/json`

**Body:**

```json
{
  "project": "my-app",
  "exception_type": "ValueError",
  "message": "invalid input",
  "traceback": "Traceback (most recent call last):\n  ...",
  "request_url": "/api/users",
  "request_method": "POST",
  "request_headers": {"Accept": "application/json"},
  "user_id": "user-42",
  "extra": {"request_id": "abc123"}
}
```

**Responses:**
- `201` -- new error created: `{"status":"created","fingerprint":"...","id":1}`
- `200` -- existing error updated: `{"status":"existing","fingerprint":"...","count":5}`

### GET /api/errors

List errors with optional filtering.

**Query parameters:**

| Param | Description |
|-------|-------------|
| `project` | Filter by project name |
| `resolved` | `true` or `false` |
| `search` | Search in exception type and message |
| `source` | Filter by source (`browser`, etc.) |
| `limit` | Max results (default 50, max 200) |
| `offset` | Pagination offset |

**Response:**

```json
{
  "errors": [
    {
      "id": 1,
      "fingerprint": "a1b2c3...",
      "project": "my-app",
      "exception_type": "ValueError",
      "message": "invalid input",
      "count": 3,
      "first_seen": "2026-01-01T00:00:00Z",
      "last_seen": "2026-01-02T00:00:00Z",
      "resolved": false
    }
  ],
  "total": 1,
  "limit": 50,
  "offset": 0
}
```

### GET /api/errors/{id}

Get error details including recent occurrences.

**Response:**

```json
{
  "error": {
    "id": 1,
    "fingerprint": "...",
    "project": "my-app",
    "exception_type": "ValueError",
    "message": "invalid input",
    "traceback": "Traceback ...",
    "count": 3,
    "first_seen": "...",
    "last_seen": "...",
    "resolved": false
  },
  "occurrences": [
    {
      "id": 1,
      "timestamp": "...",
      "request_url": "/api/users",
      "request_method": "POST",
      "request_headers": "...",
      "user_id": "user-42",
      "extra": "..."
    }
  ]
}
```

### POST /api/test-alert

Dispatch a synthetic SMTP alert so you can verify your `SMTP_*` and `ALERT_EMAILS` configuration without polluting the error database. The email is sent in a background thread; the actual SMTP transaction result is logged by the service.

**Headers:** `X-API-Key: <api-key>`

**Responses:**
- `202` -- alert dispatched: `{"status":"test alert dispatched","detail":"Check service logs for SMTP transaction result"}`
- `503` -- SMTP not configured: `{"detail":"SMTP not configured: SMTP_HOST is not set"}` (or `ALERT_EMAILS`)
- `401` -- missing or invalid API key

Example:

```bash
curl -X POST http://localhost:5010/api/test-alert \
  -H "X-API-Key: $API_KEY"
```

Then watch the service logs for `Email alert sent to <addr> via SMTP (...)` on success, or `SMTP ...` warn lines on failure.

### POST /api/errors/{id}/resolve

Mark an error as resolved. It will reopen automatically if the same fingerprint is reported again.

**Response:** `{"status":"resolved"}`

### GET /api/projects

List all projects that have reported errors.

**Response:** `{"projects":["my-app","other-app"]}`

### GET /health

**Response:** `{"status":"ok"}`

## Database schema

**`errors`** -- one row per unique fingerprint:

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER | Primary key |
| `fingerprint` | VARCHAR(32) | MD5 hash, unique |
| `project` | VARCHAR(100) | Project name |
| `exception_type` | VARCHAR(200) | Exception class name |
| `message` | TEXT | Error message |
| `traceback` | TEXT | Full stack trace |
| `count` | INTEGER | Occurrence count |
| `first_seen` | DATETIME | First occurrence |
| `last_seen` | DATETIME | Most recent occurrence |
| `resolved` | BOOLEAN | Resolution status |

**`error_occurrences`** -- last 5 per error group:

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER | Primary key |
| `error_id` | INTEGER | FK to errors (CASCADE delete) |
| `timestamp` | DATETIME | Occurrence time |
| `request_url` | TEXT | Request URL |
| `request_method` | VARCHAR(10) | HTTP method |
| `request_headers` | TEXT | Request headers (JSON) |
| `user_id` | VARCHAR(200) | User identifier |
| `extra` | TEXT | Additional metadata |

## Background tasks

- **Retention cleanup:** Runs every 24 hours. Deletes resolved errors older than `RETENTION_DAYS`.

## Rate limits

- 100 requests/minute per IP
- 256KB max request body
