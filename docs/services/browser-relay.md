---
layout: default
title: Browser Relay
parent: Services
nav_order: 4
---

# Browser Relay

Public-facing proxy for browser telemetry. Authenticates browser requests using DSN public keys, handles CORS, deobfuscates source maps, and forwards data to the error tracker and metrics collector.

**Port:** 5013 | **Binary:** `browser-relay` | **Database:** `browser-relay.db`

## How it works

The browser relay sits between untrusted browser clients and backend services:

1. Browser JS SDK sends telemetry with a DSN public key (`X-Monlight-Key` header)
2. Relay validates the key against its database
3. For errors: optionally deobfuscates minified stack traces using uploaded source maps
4. Forwards the data to the error tracker or metrics collector using internal API keys
5. Returns the response to the browser

This design keeps API keys out of client-side code while still allowing browsers to submit telemetry.

## Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ADMIN_API_KEY` | Yes | -- | API key for admin endpoints (DSN key management, source maps) |
| `ERROR_TRACKER_URL` | Yes | -- | Internal URL of the error tracker (e.g., `http://error-tracker:8000`) |
| `ERROR_TRACKER_API_KEY` | Yes | -- | API key for the error tracker |
| `METRICS_COLLECTOR_URL` | Yes | -- | Internal URL of the metrics collector |
| `METRICS_COLLECTOR_API_KEY` | Yes | -- | API key for the metrics collector |
| `DATABASE_PATH` | No | `./data/browser-relay.db` | Path to SQLite database |
| `CORS_ORIGINS` | No | -- | Comma-separated allowed origins (no trailing slashes) |
| `MAX_BODY_SIZE` | No | `65536` | Max request body in bytes |
| `RATE_LIMIT` | No | `300` | Requests per minute per key |
| `RETENTION_DAYS` | No | `90` | Days to keep source maps |
| `LOG_LEVEL` | No | `info` | `error`, `warn`, `info`, `debug` |

## API -- Admin endpoints

Authenticated with `X-API-Key` header using `ADMIN_API_KEY`.

### POST /api/dsn-keys

Create a new DSN key for a project.

**Body:** `{"project": "my-app"}`

**Response:** `201 {"public_key":"a1b2c3d4...","project":"my-app"}`

The `public_key` is a randomly generated 32-character hex string. This is the value you pass as `dsn` in the JavaScript SDK configuration.

### GET /api/dsn-keys

List all DSN keys.

**Response:**

```json
{
  "keys": [
    {
      "id": 1,
      "public_key": "a1b2c3d4...",
      "project": "my-app",
      "active": true,
      "created_at": "2026-01-01T00:00:00Z"
    }
  ]
}
```

### DELETE /api/dsn-keys/{id}

Deactivate a DSN key (soft delete -- sets `active=false`).

**Response:** `{"status":"deactivated"}` or `404`

### POST /api/source-maps

Upload a source map for stack trace deobfuscation.

**Body:**

```json
{
  "project": "my-app",
  "release": "1.2.3",
  "file_url": "/assets/app.min.js",
  "map_content": "{\"version\":3,\"sources\":[...],\"mappings\":\"...\"}"
}
```

- `map_content` must be a valid source map with `version`, `sources`, and `mappings` fields
- Max 5MB per source map
- Upserts on (project, release, file_url) -- re-uploading replaces the existing map

**Response:** `201 {"status":"uploaded","project":"...","release":"...","file_url":"..."}`

### GET /api/source-maps

List uploaded source maps (metadata only, no content).

**Query parameters:** `project` (optional filter)

**Response:**

```json
{
  "source_maps": [
    {
      "id": 1,
      "project": "my-app",
      "release": "1.2.3",
      "file_url": "/assets/app.min.js",
      "uploaded_at": "2026-01-01T00:00:00Z"
    }
  ],
  "total": 1
}
```

### DELETE /api/source-maps/{id}

Delete a source map (hard delete).

**Response:** `{"status":"deleted"}` or `404`

## API -- Browser endpoints

Authenticated with `X-Monlight-Key` header using a DSN public key.

### POST /api/browser/errors

Submit a browser error report.

**Body:**

```json
{
  "type": "TypeError",
  "message": "Cannot read property 'x' of undefined",
  "stack": "TypeError: Cannot read property 'x' of undefined\n    at Object.<anonymous> (app.min.js:1:234)",
  "url": "https://example.com/page",
  "user_agent": "Mozilla/5.0 ...",
  "session_id": "uuid-v4",
  "release": "1.2.3",
  "environment": "prod",
  "context": {"user_id": "u-42"}
}
```

If `release` is provided and a matching source map exists, the stack trace is deobfuscated before forwarding.

The relay transforms this into the error tracker's format and forwards it with `request_method` set to `"BROWSER"`.

**Response:** `201 {"status":"created",...}` or `200 {"status":"existing",...}` (proxied from error tracker)

### POST /api/browser/metrics

Submit browser metrics (Web Vitals, custom metrics).

**Body:**

```json
{
  "metrics": [
    {
      "name": "web_vitals_lcp",
      "type": "histogram",
      "value": 1250.5,
      "labels": {"page": "/dashboard"}
    }
  ],
  "session_id": "uuid-v4",
  "url": "https://example.com/dashboard"
}
```

The relay enriches each metric's labels with `project`, `source: "browser"`, `session_id`, and `page` (extracted from URL path). Then forwards to the metrics collector.

**Response:** `202 {"status":"accepted","count":1}`

### GET /health

**Response:** `{"status":"ok"}`

## CORS

When `CORS_ORIGINS` is set, the relay handles CORS preflight requests:

- `OPTIONS` requests return `204` with appropriate headers
- Allowed headers: `X-Monlight-Key`, `Content-Type`
- Allowed methods: `POST`, `OPTIONS`
- Max-age: 86400 seconds (24 hours)
- Origins must match exactly (case-sensitive)
- Max 32 origins, max 256 characters each

## Source map deobfuscation

The relay supports full source map v3 deobfuscation:

1. Parses the minified stack trace (supports Chrome/V8 and Firefox/Safari formats)
2. For each frame, looks up the source map by matching `file_url` against the project and release
3. Decodes Base64 VLQ mappings to find the original source file, line, and column
4. Rewrites the stack trace with original locations

File URLs in stack traces are normalized by stripping protocol and domain before matching against stored source maps.

## Database schema

**`dsn_keys`** -- browser authentication keys:

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER | Primary key |
| `public_key` | VARCHAR(64) | Hex key, unique |
| `project` | VARCHAR(100) | Associated project |
| `created_at` | DATETIME | Creation time |
| `active` | BOOLEAN | Whether the key is active (default true) |

**`source_maps`** -- uploaded source maps:

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER | Primary key |
| `project` | VARCHAR(100) | Project name |
| `release` | VARCHAR(100) | Release version |
| `file_url` | VARCHAR(500) | JavaScript file URL |
| `map_content` | TEXT | Full source map JSON |
| `uploaded_at` | DATETIME | Upload time |

Unique constraint on (project, release, file_url).

## Background tasks

- **Source map retention:** Deletes source maps older than `RETENTION_DAYS`.

## Rate limits

- 300 requests/minute per key
- 64KB max request body (configurable via `MAX_BODY_SIZE`)
