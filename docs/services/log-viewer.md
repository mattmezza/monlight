---
layout: default
title: Log Viewer
parent: Services
nav_order: 2
---

# Log Viewer

Indexes Docker container logs with full-text search and real-time SSE streaming. Reads log files directly from the host filesystem -- no agents or log shippers required.

**Port:** 5011 | **Binary:** `log-viewer` | **Database:** `logs.db`

## How it works

1. A background thread scans Docker container config files to find monitored containers
2. Reads Docker JSON log files (`/var/lib/docker/containers/{id}/{id}-json.log`)
3. Parses JSON log entries, reassembles multiline messages (Python tracebacks, etc.)
4. Auto-detects log levels from message content
5. Stores entries in SQLite with FTS5 indexing
6. Tracks file cursors to avoid re-reading on restart

Log rotation is handled automatically via inode tracking. When a log file is rotated, the viewer detects the inode change and reads from the beginning of the new file.

## Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `API_KEY` | Yes | -- | Authentication key |
| `DATABASE_PATH` | No | `./data/logs.db` | Path to SQLite database |
| `CONTAINERS` | No | *(empty = all)* | Comma-separated container names to monitor |
| `LOG_SOURCES` | No | `/var/lib/docker/containers` | Docker containers directory path |
| `MAX_ENTRIES` | No | `100000` | Maximum log entries to keep (ring buffer) |
| `POLL_INTERVAL` | No | `2` | Seconds between log file polls |
| `TAIL_BUFFER` | No | `65536` | Bytes to read from end of file on first run |
| `LOG_LEVEL` | No | `info` | `error`, `warn`, `info`, `debug` |

## API

### GET /api/logs

Query indexed logs with filtering and full-text search.

**Headers:** `X-API-Key: <api-key>`

**Query parameters:**

| Param | Description |
|-------|-------------|
| `container` | Filter by container name |
| `level` | Filter by level: `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL` |
| `search` | Full-text search query (FTS5 MATCH syntax) |
| `since` | ISO 8601 start time |
| `until` | ISO 8601 end time |
| `limit` | Max results (default 100, max 500) |
| `offset` | Pagination offset |

**FTS5 search syntax examples:**
- `error` -- entries containing "error"
- `"connection refused"` -- exact phrase
- `error OR timeout` -- either term
- `error NOT debug` -- exclude term

**Response:**

```json
{
  "logs": [
    {
      "id": 1,
      "timestamp": "2026-01-01T12:00:00Z",
      "container": "my_app",
      "stream": "stderr",
      "level": "ERROR",
      "message": "Connection refused"
    }
  ],
  "total": 42,
  "limit": 100,
  "offset": 0
}
```

### GET /api/logs/tail

Real-time log streaming via Server-Sent Events (SSE).

**Query parameters:**

| Param | Description |
|-------|-------------|
| `container` | Filter by container name |
| `level` | Filter by level |

**SSE events:**

| Event | Data | Description |
|-------|------|-------------|
| `log` | JSON log entry | New log entry |
| `heartbeat` | -- | Keep-alive (every 15s) |
| `close` | -- | Server closing connection |

**Limits:** Max 5 concurrent SSE connections. Connections close after 30 minutes.

### GET /api/logs/containers

List monitored containers with log counts.

**Response:** `{"containers":[{"name":"my_app","log_count":1234}]}`

### GET /api/logs/stats

Aggregated statistics.

**Response:**

```json
{
  "total_logs": 50000,
  "oldest_log": "2026-01-01T00:00:00Z",
  "newest_log": "2026-01-02T00:00:00Z",
  "by_level": {"ERROR": 100, "INFO": 49900},
  "by_container": {"my_app": 30000, "worker": 20000}
}
```

### GET /health

**Response:** `{"status":"ok"}`

## Log level detection

Levels are auto-detected from log messages using these patterns (in priority order):

1. JSON field: `"level":"ERROR"` or `"severity":"warning"`
2. Bracket format: `[ERROR]`, `[WARN]`
3. Key-value: `level=error`
4. Colon prefix: `ERROR: something failed`
5. Default: `stderr` stream maps to `ERROR`, `stdout` to `INFO`

## Multiline reassembly

The ingestion engine reassembles multiline log entries by detecting continuation lines:

- Lines starting with whitespace
- Python traceback patterns (`Traceback`, `File "..."`, exception lines)
- Stack trace frames

These are appended to the previous log entry rather than creating new entries.

## Database schema

**`log_entries`** -- indexed log storage:

| Column | Type | Description |
|--------|------|-------------|
| `id` | INTEGER | Primary key |
| `timestamp` | DATETIME | Log timestamp |
| `container` | VARCHAR(200) | Container name |
| `stream` | VARCHAR(10) | `stdout` or `stderr` |
| `level` | VARCHAR(10) | Detected log level |
| `message` | TEXT | Log message |
| `raw` | TEXT | Original raw line |

**`log_entries_fts`** -- FTS5 virtual table on the `message` column.

**`cursors`** -- tracks ingestion position per container:

| Column | Type | Description |
|--------|------|-------------|
| `container_id` | TEXT | Container ID (unique) |
| `file_path` | TEXT | Log file path |
| `position` | INTEGER | Byte offset in file |
| `inode` | INTEGER | File inode for rotation detection |
| `updated_at` | DATETIME | Last update time |

## Background tasks

- **Log ingestion:** Polls Docker log files every `POLL_INTERVAL` seconds.
- **Ring buffer cleanup:** After each poll cycle, trims entries exceeding `MAX_ENTRIES`.

## Rate limits

- 60 requests/minute per IP
- 64KB max request body
