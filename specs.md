# FlowRent Monitoring Stack - Technical Specification

Version: 1.0
Status: Draft
Last Updated: 2025-01-23

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [FlowRent System Context](#2-flowrent-system-context)
3. [Monitoring Stack Overview](#3-monitoring-stack-overview)
4. [Error Tracker Service](#4-error-tracker-service)
5. [Log Viewer Service](#5-log-viewer-service)
6. [Metrics Collector Service](#6-metrics-collector-service)
7. [FlowRent Integration](#7-flowrent-integration)
8. [Deployment Architecture](#8-deployment-architecture)
9. [Non-Functional Requirements](#9-non-functional-requirements)
10. [Security Considerations](#10-security-considerations)
11. [Future Enhancements](#11-future-enhancements)

---

## 1. Introduction

### 1.1 Purpose

This document specifies a self-hosted monitoring stack for the FlowRent application. The stack provides error tracking, log aggregation, and metrics collection through three independent microservices.

### 1.2 Design Philosophy

- **Minimal**: Each service does one thing well
- **Low resource**: Total stack uses <50MB RAM
- **Independent**: Services can be deployed individually
- **80/20 rule**: Deliver 80% of value with 20% of complexity
- **SQLite-based**: No external database dependencies
- **Compatible**: HTTP API integration with FlowRent's tech stack

### 1.3 Goals

| Goal | Description |
|------|-------------|
| Capture production errors | Know when things break, with full context |
| Debug issues | Search logs when investigating problems |
| Monitor performance | Track response times and error rates |
| Low overhead | Minimal resource usage on production VPS |
| Zero vendor lock-in | Self-hosted, open source, own your data |

### 1.4 Non-Goals

- Real-time alerting rules engine
- Distributed tracing
- APM (Application Performance Monitoring)
- User session replay
- Uptime monitoring

---

## 2. FlowRent System Context

The monitoring stack is designed to integrate with FlowRent. This section documents FlowRent's architecture to ensure compatibility.

### 2.1 What is FlowRent

FlowRent is a rental management system for a bike rental shop in Valencia, Spain. It handles:
- Customer self-service booking flow (on shop tablets)
- Staff dashboard for booking management
- Contract generation and digital signatures
- Email notifications
- Payment tracking

### 2.2 Technology Stack

| Layer | Technology |
|-------|------------|
| **Language** | Python 3.11+ |
| **Web Framework** | FastAPI 0.104+ |
| **ASGI Server** | Uvicorn 0.27+ |
| **Database** | SQLite with SQLAlchemy 2.0+ ORM |
| **Migrations** | Alembic |
| **Templating** | Jinja2 |
| **Frontend** | HTMX + Tailwind CSS |
| **Email** | Postmark API |
| **File Storage** | S3-compatible (Contabo) |
| **Containerization** | Docker |
| **Orchestration** | Docker Compose |

### 2.3 Application Structure

```
app/
├── app/
│   ├── main.py              # FastAPI application entry point
│   ├── config.py            # Pydantic Settings configuration
│   ├── database.py          # SQLAlchemy engine and session
│   ├── models/              # SQLAlchemy ORM models
│   ├── routes/              # FastAPI routers (13 modules)
│   ├── services/            # Business logic services
│   ├── jobs/                # APScheduler background jobs
│   ├── schemas/             # Pydantic request/response schemas
│   ├── utils/               # Helper utilities
│   └── templates/           # Jinja2 HTML templates
├── static/                  # CSS, JS assets
├── alembic/                 # Database migrations
├── tests/                   # Pytest test suite
└── Dockerfile
```

### 2.4 Configuration Pattern

FlowRent uses Pydantic Settings for configuration:

```
app/app/config.py:
- Settings class inherits from BaseSettings
- Reads from environment variables
- Singleton pattern via get_settings() with lru_cache
- Supports .env files
```

New settings are added as class attributes with type hints and optional defaults.

### 2.5 Logging Pattern

Current logging approach:
- Standard Python `logging` module
- Logger per module: `logger = logging.getLogger(__name__)`
- Logs to stdout (captured by Docker)
- Log levels: DEBUG, INFO, WARNING, ERROR
- No structured logging (plain text format)

### 2.6 Error Handling Pattern

Current error handling:
- FastAPI exception handlers for HTTPException, RequestValidationError
- Try/except blocks in route handlers
- Errors logged via `logger.error()` or `logger.exception()`
- No centralized error capture

### 2.7 Deployment Architecture

```
┌─────────────────────────────────────────────────────────┐
│                         VPS                             │
│                                                         │
│   ┌─────────────────┐       ┌─────────────────┐        │
│   │   Nginx         │       │   FlowRent      │        │
│   │   (reverse      │──────▶│   Container     │        │
│   │    proxy)       │       │   (port 5002)   │        │
│   └─────────────────┘       └─────────────────┘        │
│           │                         │                   │
│           │                         ▼                   │
│           │                 ┌─────────────────┐        │
│           │                 │   SQLite DB     │        │
│           │                 │   (./data/)     │        │
│           │                 └─────────────────┘        │
│           │                                             │
│           ▼                                             │
│   HTTPS (Let's Encrypt)                                │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### 2.8 Docker Configuration

**Production container:**
- Image: Custom Dockerfile (Python 3.11 slim + Node for Tailwind build)
- Port: 5002 (mapped to internal 8000)
- Volumes: `./data:/app/data` for SQLite persistence
- Workers: 4 Uvicorn workers
- Health check: `GET /health` every 30s
- Network: `172.101.0.0/16` subnet

**Log driver:** Docker default (json-file)
- Logs stored at: `/var/lib/docker/containers/<id>/<id>-json.log`
- Format: `{"log": "...", "stream": "stdout|stderr", "time": "ISO8601"}`

### 2.9 External Services

| Service | Purpose | Integration |
|---------|---------|-------------|
| Postmark | Transactional email | HTTP API |
| Contabo S3 | File storage (contracts, images) | boto3 SDK |
| DeepL | Translation (optional) | HTTP API |

### 2.10 Existing Observability

| Capability | Current State |
|------------|---------------|
| Health check | `GET /health` returns `{"status": "ok"}` |
| Logging | Plain text to stdout |
| Error tracking | None (errors logged but not aggregated) |
| Metrics | None |
| Audit trail | Database-based for business events |

---

## 3. Monitoring Stack Overview

### 3.1 Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              VPS                                        │
│                                                                         │
│  ┌─────────────────┐                                                    │
│  │    FlowRent     │                                                    │
│  │  (port 5002)    │─────────────────┬─────────────────┐               │
│  └────────┬────────┘                 │                 │               │
│           │                          │                 │               │
│           │ stdout/stderr            │ POST            │ POST          │
│           │                          │ /api/errors     │ /api/metrics  │
│           ▼                          ▼                 ▼               │
│  ┌─────────────────┐      ┌─────────────────┐  ┌─────────────────┐    │
│  │   Docker Logs   │      │  Error Tracker  │  │    Metrics      │    │
│  │  (json files)   │      │  (port 5010)    │  │   Collector     │    │
│  └────────┬────────┘      └────────┬────────┘  │  (port 5012)    │    │
│           │                        │           └────────┬────────┘    │
│           │ read                   │                    │              │
│           ▼                        ▼                    ▼              │
│  ┌─────────────────┐      ┌─────────────────┐  ┌─────────────────┐    │
│  │   Log Viewer    │      │     SQLite      │  │     SQLite      │    │
│  │  (port 5011)    │      │   errors.db     │  │   metrics.db    │    │
│  └────────┬────────┘      └─────────────────┘  └─────────────────┘    │
│           │                        │                    │              │
│           ▼                        │                    │              │
│  ┌─────────────────┐               │                    │              │
│  │     SQLite      │               ▼                    │              │
│  │    logs.db      │        ┌─────────────┐             │              │
│  └─────────────────┘        │  Postmark   │◀────────────┘              │
│                             │  (alerts)   │                            │
│                             └─────────────┘                            │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Services Summary

| Service | Port | Purpose | Data Flow |
|---------|------|---------|-----------|
| Error Tracker | 5010 | Capture and aggregate exceptions | FlowRent → HTTP POST → Error Tracker |
| Log Viewer | 5011 | Index and search logs | Docker log files → Log Viewer |
| Metrics Collector | 5012 | Collect and visualize metrics | FlowRent → HTTP POST → Metrics Collector |

### 3.3 Technology Stack (Monitoring Services)

| Layer | Technology | Rationale |
|-------|------------|-----------|
| Language | Zig (0.13+) | Minimal runtime, low memory footprint, compiles to single static binary |
| HTTP Server | std.http.Server (Zig stdlib) | No external framework dependency, built-in async I/O |
| Database | SQLite (C library via Zig's @cImport) | Simple, no external dependencies; Zig has first-class C interop |
| Templating | Embedded Zig templates (comptime) | Compile-time HTML generation, no runtime overhead |
| Container | Docker | Same as FlowRent |

### 3.4 Resource Budget

| Service | RAM | Disk | CPU |
|---------|-----|------|-----|
| Error Tracker | 10MB | 100MB | 0.1 core |
| Log Viewer | 15MB | 200MB | 0.1 core |
| Metrics Collector | 10MB | 50MB | 0.1 core |
| **Total** | **35MB** | **350MB** | **0.3 core** |

**Note:** Zig compiles to static binaries with no runtime or garbage collector, resulting in significantly lower memory usage than interpreted languages.

---

## 4. Error Tracker Service

### 4.1 Purpose

Capture unhandled exceptions from FlowRent with full context (stack trace, request info), group duplicate errors, and send email alerts for new errors.

### 4.2 Functional Requirements

#### 4.2.1 Error Ingestion

| ID | Requirement |
|----|-------------|
| ET-001 | Accept error reports via HTTP POST |
| ET-002 | Validate API key authentication |
| ET-003 | Parse and store exception details |
| ET-004 | Support multiple projects (multi-tenant) |
| ET-005 | Support environment tagging (prod, dev, staging) |

#### 4.2.2 Error Grouping

| ID | Requirement |
|----|-------------|
| ET-010 | Generate fingerprint for each error based on exception type and stack trace location |
| ET-011 | Group errors with identical fingerprints |
| ET-012 | Track occurrence count for grouped errors |
| ET-013 | Track first seen and last seen timestamps |
| ET-014 | Only alert on first occurrence of new error fingerprint |

#### 4.2.3 Alerting

| ID | Requirement |
|----|-------------|
| ET-020 | Send email alert when new error fingerprint is detected |
| ET-021 | Include exception type, message, and stack trace in alert |
| ET-022 | Include request URL and method if available |
| ET-023 | Support multiple alert recipients |
| ET-024 | Use Postmark API for email delivery (same as FlowRent) |

#### 4.2.4 Error Management

| ID | Requirement |
|----|-------------|
| ET-030 | Mark errors as resolved |
| ET-031 | Reopen resolved errors if same fingerprint occurs again |
| ET-032 | List errors with filtering (project, environment, resolved status) |
| ET-033 | View individual error details |
| ET-034 | Delete old resolved errors (retention policy) |

#### 4.2.5 Web Interface

| ID | Requirement |
|----|-------------|
| ET-040 | Display list of unresolved errors |
| ET-041 | Filter by project and environment |
| ET-042 | Show error count, first/last seen |
| ET-043 | Expand to view full stack trace |
| ET-044 | Button to mark as resolved |

### 4.3 Data Model

#### 4.3.1 Error Entity

| Field | Type | Description |
|-------|------|-------------|
| id | INTEGER | Primary key, auto-increment |
| fingerprint | VARCHAR(32) | MD5 hash for grouping (indexed) |
| project | VARCHAR(100) | Project identifier, e.g., "flowrent" (indexed) |
| environment | VARCHAR(20) | Environment: "prod", "dev", "staging" (indexed) |
| exception_type | VARCHAR(200) | Exception class name, e.g., "ValueError" |
| message | TEXT | Exception message (from first occurrence) |
| traceback | TEXT | Full stack trace (from first occurrence) |
| count | INTEGER | Occurrence count, default 1 |
| first_seen | DATETIME | First occurrence timestamp (indexed) |
| last_seen | DATETIME | Most recent occurrence timestamp (indexed) |
| resolved | BOOLEAN | Resolution status, default false (indexed) |
| resolved_at | DATETIME | When marked resolved (nullable) |

**Note:** Per-occurrence context (request_url, request_method, request_headers, user_id, extra) is stored in the `error_occurrences` table. The `errors` table holds the group-level summary. The `traceback` and `message` on the `errors` table are from the first occurrence and used for display/fingerprinting.

#### 4.3.2 Error Occurrence Entity

Stores the most recent individual occurrences of each error group, preserving request context from recurring errors.

| Field | Type | Description |
|-------|------|-------------|
| id | INTEGER | Primary key, auto-increment |
| error_id | INTEGER | Foreign key to errors.id (indexed) |
| timestamp | DATETIME | When this occurrence happened |
| request_url | VARCHAR(500) | HTTP request URL (nullable) |
| request_method | VARCHAR(10) | HTTP method (nullable) |
| request_headers | TEXT | JSON blob of relevant headers (nullable) |
| user_id | VARCHAR(100) | User identifier (nullable) |
| extra | TEXT | JSON blob for additional context (nullable) |
| traceback | TEXT | Full stack trace for this occurrence |

**Retention:** Keep the last 5 occurrences per error group. When a 6th occurrence arrives, delete the oldest occurrence for that error_id.

#### 4.3.3 Indexes

- `idx_fingerprint_resolved` on (fingerprint, resolved) - for deduplication lookup
- `idx_project_env` on (project, environment) - for filtering
- `idx_last_seen` on (last_seen) - for sorting
- `idx_resolved` on (resolved) - for filtering
- `idx_occurrence_error_id` on error_occurrences(error_id) - for occurrence lookup

### 4.4 API Specification

#### 4.4.1 POST /api/errors

Receive error report from client.

**Headers:**
- `X-API-Key: <api_key>` (required)
- `Content-Type: application/json`

**Request Body:**
```
{
  "project": "flowrent",           // required, string, max 100 chars
  "environment": "prod",           // optional, default "prod"
  "exception_type": "ValueError",  // required, string, max 200 chars
  "message": "invalid input",      // required, string
  "traceback": "Traceback...",     // required, string
  "request_url": "/api/bookings",  // optional, string
  "request_method": "POST",        // optional, string
  "request_headers": {},           // optional, object
  "user_id": "123",                // optional, string
  "extra": {}                      // optional, object
}
```

**Response (201 Created - new error):**
```
{
  "status": "created",
  "id": 42,
  "fingerprint": "abc123..."
}
```

**Response (200 OK - existing error incremented):**
```
{
  "status": "incremented",
  "id": 42,
  "count": 5
}
```

**Response (401 Unauthorized):**
```
{
  "detail": "Invalid API key"
}
```

#### 4.4.2 GET /api/errors

List errors with filtering.

**Headers:**
- `X-API-Key: <api_key>` (required)

**Query Parameters:**
- `project` (optional): Filter by project
- `environment` (optional): Filter by environment
- `resolved` (optional): Filter by resolution status, default false
- `limit` (optional): Max results, default 50, max 200
- `offset` (optional): Pagination offset, default 0

**Response (200 OK):**
```
{
  "errors": [
    {
      "id": 42,
      "fingerprint": "abc123...",
      "project": "flowrent",
      "environment": "prod",
      "exception_type": "ValueError",
      "message": "invalid input",
      "request_url": "/api/bookings",
      "count": 5,
      "first_seen": "2025-01-20T10:00:00Z",
      "last_seen": "2025-01-23T15:30:00Z",
      "resolved": false
    }
  ],
  "total": 100,
  "limit": 50,
  "offset": 0
}
```

#### 4.4.3 GET /api/errors/{id}

Get single error with full details.

**Response (200 OK):**
```
{
  "id": 42,
  "fingerprint": "abc123...",
  "project": "flowrent",
  "environment": "prod",
  "exception_type": "ValueError",
  "message": "invalid input",
  "traceback": "Traceback (most recent call last):\n...",
  "count": 5,
  "first_seen": "2025-01-20T10:00:00Z",
  "last_seen": "2025-01-23T15:30:00Z",
  "resolved": false,
  "resolved_at": null,
  "occurrences": [
    {
      "id": 101,
      "timestamp": "2025-01-23T15:30:00Z",
      "request_url": "/api/bookings",
      "request_method": "POST",
      "request_headers": {"User-Agent": "..."},
      "user_id": "123",
      "extra": {"booking_id": 456},
      "traceback": "Traceback (most recent call last):\n..."
    },
    {
      "id": 100,
      "timestamp": "2025-01-22T10:00:00Z",
      "request_url": "/api/bookings",
      "request_method": "POST",
      "request_headers": {"User-Agent": "..."},
      "user_id": "789",
      "extra": {"booking_id": 321},
      "traceback": "Traceback (most recent call last):\n..."
    }
  ]
}
```

#### 4.4.4 POST /api/errors/{id}/resolve

Mark error as resolved.

**Response (200 OK):**
```
{
  "status": "resolved",
  "id": 42
}
```

#### 4.4.5 GET /api/projects

List known projects.

**Response (200 OK):**
```
{
  "projects": ["flowrent", "other-app"]
}
```

#### 4.4.6 GET /health

Health check endpoint (no auth required).

**Response (200 OK):**
```
{
  "status": "ok"
}
```

### 4.5 Fingerprinting Algorithm

Purpose: Group errors that are "the same bug" together.

**Algorithm:**
1. Extract exception type (e.g., "ValueError")
2. Parse traceback to find the last application code location (file:line)
3. Concatenate: `{project}:{exception_type}:{file}:{line}`
4. Hash with MD5 to produce 32-char fingerprint

**Example:**
```
Input:
  project = "flowrent"
  exception_type = "ValueError"
  traceback = """
    Traceback (most recent call last):
      File "/app/app/routes/bookings.py", line 142, in create_booking
        validate_input(data)
      File "/app/app/utils/validation.py", line 56, in validate_input
        raise ValueError("invalid input")
    ValueError: invalid input
  """

Extract location: "/app/app/utils/validation.py:56"
Key: "flowrent:ValueError:/app/app/utils/validation.py:56"
Fingerprint: MD5(key) = "a1b2c3d4e5f6..."
```

### 4.6 Email Alert Template

**Subject:** `[{project}] {exception_type}: {message_truncated_50_chars}`

**Body:**
```
New error in {project} ({environment})

Exception: {exception_type}
Message: {message}

Request: {request_method} {request_url}
Time: {first_seen}

Traceback:
{traceback}

---
View in Error Tracker: {dashboard_url}
```

### 4.7 Configuration

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| DATABASE_PATH | string | ./data/errors.db | SQLite database file path |
| API_KEY | string | (required) | Shared secret for authentication |
| POSTMARK_API_TOKEN | string | (optional) | Postmark API token for alerts |
| POSTMARK_FROM_EMAIL | string | errors@example.com | Sender email address |
| ALERT_EMAILS | string | (optional) | Comma-separated recipient emails |
| RETENTION_DAYS | int | 90 | Days to keep resolved errors |
| BASE_URL | string | http://localhost:5010 | Base URL for dashboard links |

---

## 5. Log Viewer Service

### 5.1 Purpose

Read Docker container logs, index them in SQLite for searchability, and provide a web interface for browsing and searching logs.

### 5.2 Functional Requirements

#### 5.2.1 Log Ingestion

| ID | Requirement |
|----|-------------|
| LV-001 | Read Docker JSON log files from mounted volume |
| LV-002 | Watch for new log entries (polling) |
| LV-003 | Parse Docker JSON format: {"log", "stream", "time"} |
| LV-004 | Extract log level from message content (INFO, ERROR, etc.) |
| LV-005 | Support multiple containers |
| LV-006 | Handle log rotation gracefully |
| LV-007 | Track read position to avoid reprocessing |
| LV-008 | Reassemble multiline log entries (e.g., Python tracebacks) |

#### 5.2.2 Log Storage

| ID | Requirement |
|----|-------------|
| LV-010 | Store logs in SQLite with full-text search |
| LV-011 | Implement ring buffer (max N entries) |
| LV-012 | Delete oldest logs when limit exceeded |
| LV-013 | Index by timestamp, container, level |

#### 5.2.3 Log Search

| ID | Requirement |
|----|-------------|
| LV-020 | Full-text search on log message |
| LV-021 | Filter by container |
| LV-022 | Filter by log level |
| LV-023 | Filter by time range |
| LV-024 | Paginate results |
| LV-025 | Sort by timestamp (newest first default) |

#### 5.2.4 Web Interface

| ID | Requirement |
|----|-------------|
| LV-030 | Display log entries in scrollable list |
| LV-031 | Color-code by log level |
| LV-032 | Search box with full-text search |
| LV-033 | Filter dropdowns for container and level |
| LV-034 | Time range selector (last 1h, 24h, 7d, custom) |
| LV-035 | Live tail mode (auto-refresh new logs) |
| LV-036 | Click to expand full log entry |

### 5.3 Data Model

#### 5.3.1 Log Entry Entity

| Field | Type | Description |
|-------|------|-------------|
| id | INTEGER | Primary key, auto-increment |
| timestamp | DATETIME | Log timestamp from Docker (indexed) |
| container | VARCHAR(100) | Container name (indexed) |
| stream | VARCHAR(10) | stdout or stderr |
| level | VARCHAR(10) | Extracted level: DEBUG, INFO, WARNING, ERROR (indexed) |
| message | TEXT | Log message content |
| raw | TEXT | Original JSON line |

#### 5.3.2 Full-Text Search Table

SQLite FTS5 virtual table on message field for efficient text search.

#### 5.3.3 Cursor Entity

Track read position for each log file.

| Field | Type | Description |
|-------|------|-------------|
| id | INTEGER | Primary key |
| container_id | VARCHAR(100) | Docker container ID |
| file_path | VARCHAR(500) | Log file path |
| position | INTEGER | Byte offset in file |
| inode | INTEGER | File inode (detect rotation) |
| updated_at | DATETIME | Last update time |

#### 5.3.4 Indexes

- `idx_timestamp` on (timestamp) - for time range queries
- `idx_container` on (container) - for filtering
- `idx_level` on (level) - for filtering
- `idx_container_timestamp` on (container, timestamp) - for combined queries

### 5.4 Log Level Extraction

Parse log message to extract level. FlowRent logs may use various formats:

**Patterns to match:**
1. `[LEVEL]` - e.g., `[INFO]`, `[ERROR]`
2. `level=LEVEL` - e.g., `level=info`
3. `LEVEL:` at start - e.g., `INFO: message`
4. Uvicorn format - e.g., `INFO:     127.0.0.1...`

**Default:** INFO if no level detected

**stderr stream:** Default to ERROR unless level detected

### 5.5 API Specification

#### 5.5.1 GET /api/logs

Query logs with filtering.

**Headers:**
- `X-API-Key: <api_key>` (required)

**Query Parameters:**
- `container` (optional): Filter by container name
- `level` (optional): Filter by level (DEBUG, INFO, WARNING, ERROR)
- `search` (optional): Full-text search query
- `since` (optional): Start time, ISO8601 format
- `until` (optional): End time, ISO8601 format
- `limit` (optional): Max results, default 100, max 500
- `offset` (optional): Pagination offset, default 0

**Response (200 OK):**
```
{
  "logs": [
    {
      "id": 12345,
      "timestamp": "2025-01-23T15:30:00Z",
      "container": "rentl_prod",
      "stream": "stdout",
      "level": "ERROR",
      "message": "Failed to send email: connection timeout"
    }
  ],
  "total": 5000,
  "limit": 100,
  "offset": 0
}
```

#### 5.5.2 GET /api/logs/tail

Server-Sent Events stream for live tail.

**Headers:**
- `X-API-Key: <api_key>` (required)

**Query Parameters:**
- `container` (optional): Filter by container
- `level` (optional): Filter by level

**Response:** SSE stream
```
event: log
data: {"id": 12346, "timestamp": "...", "level": "INFO", "message": "..."}

event: log
data: {"id": 12347, "timestamp": "...", "level": "ERROR", "message": "..."}
```

**SSE connection lifecycle:**
- Maximum connection duration: 30 minutes (client should reconnect automatically)
- Heartbeat: Send `event: heartbeat\ndata: {}\n\n` every 15 seconds to detect dead connections
- Maximum concurrent SSE connections: 5 (return `503 Service Unavailable` when exceeded)
- On client disconnect: Clean up connection resources immediately
- Backpressure: If a client cannot keep up, drop log events for that client (don't buffer unboundedly)

#### 5.5.3 GET /api/containers

List known containers.

**Response (200 OK):**
```
{
  "containers": [
    {"name": "rentl_prod", "log_count": 50000},
    {"name": "rentl_dev", "log_count": 12000}
  ]
}
```

#### 5.5.4 GET /api/stats

Log statistics.

**Response (200 OK):**
```
{
  "total_logs": 62000,
  "oldest_log": "2025-01-16T00:00:00Z",
  "newest_log": "2025-01-23T15:35:00Z",
  "by_level": {
    "DEBUG": 5000,
    "INFO": 50000,
    "WARNING": 5000,
    "ERROR": 2000
  },
  "by_container": {
    "rentl_prod": 50000,
    "rentl_dev": 12000
  }
}
```

#### 5.5.5 GET /health

Health check endpoint.

**Response (200 OK):**
```
{
  "status": "ok",
  "logs_indexed": 62000,
  "last_ingest": "2025-01-23T15:35:00Z"
}
```

### 5.6 Ingestion Process

**Startup:**
1. Scan LOG_SOURCES directory for container directories
2. Filter to containers matching CONTAINERS config
3. For each container:
   a. Find JSON log file
   b. Load cursor position from database (or start from end if new)
   c. Start watching file

**Polling loop (every POLL_INTERVAL seconds):**
1. For each watched file:
   a. Check if file inode changed (rotation)
   b. If rotated, start from beginning
   c. Seek to last position
   d. Read new lines
   e. Reassemble multiline entries (see below)
   f. For each complete entry:
      - Parse JSON
      - Extract timestamp, stream, message
      - Extract log level from message
      - Insert into database
   g. Update cursor position
2. Run cleanup if total logs > MAX_ENTRIES

**Multiline log reassembly:**

Docker splits each `\n`-terminated line into a separate JSON log entry. A single logical log message (e.g., a Python traceback) may span many Docker JSON lines. The Log Viewer reassembles these:

1. Buffer incoming lines per container
2. A line starts a **new** log entry if it matches any log level pattern (see 5.4) or begins with a timestamp pattern (ISO8601 or common log formats)
3. A line that does **not** match any start pattern is appended to the current buffered entry (it is a continuation line, e.g., a traceback frame or multiline message)
4. When a new start pattern is detected, the previously buffered entry is flushed (inserted into the database) and a new buffer starts
5. On poll cycle end, any buffered entry older than 2 seconds is flushed (to avoid holding partial entries indefinitely)

**Example:** Python traceback arriving as separate Docker JSON lines:
```
{"log": "ERROR:  Traceback (most recent call last):\n", ...}  → starts new entry
{"log": "  File \"/app/routes/bookings.py\", line 42\n", ...} → continuation
{"log": "    result = process(data)\n", ...}                  → continuation
{"log": "ValueError: invalid input\n", ...}                   → continuation
```
These four Docker lines become a single log entry in the database.

**Cleanup:**
1. Count total log entries
2. If count > MAX_ENTRIES:
   a. Calculate how many to delete (count - MAX_ENTRIES + buffer)
   b. Delete oldest entries
   c. Rebuild FTS index if needed

### 5.7 Configuration

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| DATABASE_PATH | string | ./data/logs.db | SQLite database file path |
| API_KEY | string | (required) | Shared secret for authentication |
| LOG_SOURCES | string | /var/lib/docker/containers | Docker containers directory |
| CONTAINERS | string | (required) | Comma-separated container names to watch |
| MAX_ENTRIES | int | 100000 | Maximum log entries to retain |
| POLL_INTERVAL | int | 5 | Seconds between log file checks |
| TAIL_BUFFER | int | 1000 | Initial lines to load per container |

---

## 6. Metrics Collector Service

### 6.1 Purpose

Collect application metrics from FlowRent (request latency, error rates, business metrics), store aggregated data, and provide a simple dashboard.

### 6.2 Functional Requirements

#### 6.2.1 Metrics Ingestion

| ID | Requirement |
|----|-------------|
| MC-001 | Accept metrics via HTTP POST (batch) |
| MC-002 | Validate API key authentication |
| MC-003 | Support metric types: counter, histogram, gauge |
| MC-004 | Support labels/dimensions on metrics |
| MC-005 | Buffer and batch-insert for efficiency |

#### 6.2.2 Metric Types

| Type | Description | Example |
|------|-------------|---------|
| Counter | Cumulative count, only increases | http_requests_total |
| Histogram | Distribution of values | http_request_duration_seconds |
| Gauge | Point-in-time value, can go up/down | active_rentals |

#### 6.2.3 Storage and Aggregation

| ID | Requirement |
|----|-------------|
| MC-010 | Store raw metrics with short retention (1 hour) |
| MC-011 | Aggregate to minute buckets |
| MC-012 | Aggregate to hourly buckets (longer retention) |
| MC-013 | Calculate: count, sum, min, max, avg |
| MC-014 | Calculate percentiles for histograms: p50, p95, p99 |
| MC-015 | Delete old data per retention policy |

#### 6.2.4 Querying

| ID | Requirement |
|----|-------------|
| MC-020 | Query metrics by name and labels |
| MC-021 | Query with time range |
| MC-022 | Return aggregated data at appropriate resolution |
| MC-023 | Support common aggregations: sum, avg, max, min |

#### 6.2.5 Dashboard

| ID | Requirement |
|----|-------------|
| MC-030 | Overview page with key metrics |
| MC-031 | Request rate chart (requests per minute) |
| MC-032 | Response time chart (p50, p95, p99) |
| MC-033 | Error rate chart (4xx, 5xx per minute) |
| MC-034 | Top endpoints table |
| MC-035 | Time range selector (1h, 24h, 7d) |

### 6.3 Data Model

#### 6.3.1 Raw Metrics Table

Short retention, for recent detailed data.

| Field | Type | Description |
|-------|------|-------------|
| id | INTEGER | Primary key |
| timestamp | DATETIME | Metric timestamp (indexed) |
| name | VARCHAR(100) | Metric name (indexed) |
| labels | TEXT | JSON object of labels |
| value | FLOAT | Metric value |
| type | VARCHAR(20) | counter, histogram, gauge |

#### 6.3.2 Aggregated Metrics Table

Longer retention, pre-computed aggregates.

| Field | Type | Description |
|-------|------|-------------|
| id | INTEGER | Primary key |
| bucket | DATETIME | Time bucket (minute or hour) (indexed) |
| resolution | VARCHAR(10) | "minute" or "hour" |
| name | VARCHAR(100) | Metric name (indexed) |
| labels | TEXT | JSON object of labels |
| count | INTEGER | Number of data points |
| sum | FLOAT | Sum of values |
| min | FLOAT | Minimum value |
| max | FLOAT | Maximum value |
| avg | FLOAT | Average value |
| p50 | FLOAT | 50th percentile (nullable) |
| p95 | FLOAT | 95th percentile (nullable) |
| p99 | FLOAT | 99th percentile (nullable) |

#### 6.3.3 Indexes

- `idx_raw_timestamp` on metrics_raw(timestamp)
- `idx_raw_name` on metrics_raw(name)
- `idx_raw_name_timestamp` on metrics_raw(name, timestamp) - for aggregation queries
- `idx_agg_bucket` on metrics_aggregated(bucket)
- `idx_agg_name_resolution` on metrics_aggregated(name, resolution)
- `idx_agg_name_resolution_bucket` on metrics_aggregated(name, resolution, bucket) - for time-range queries

#### 6.3.4 Label Filtering Strategy

Labels are stored as JSON text (e.g., `{"method": "GET", "endpoint": "/bookings", "status": "200"}`). SQLite's `json_extract()` function is used for label filtering at query time.

**Performance trade-off:** JSON-based label filtering requires a full scan of rows matching the name/time criteria. This is acceptable because:
1. Label filtering always happens after name + time range filtering, which uses indexes to narrow the candidate set
2. The expected cardinality is low (hundreds to low thousands of aggregated rows per query)
3. Adding a normalized labels table would increase storage and write complexity for minimal query benefit at this scale

**If label filtering becomes a bottleneck:** Consider adding a `label_hash` column (hash of sorted label key-value pairs) with an index, allowing exact-match label filtering via index lookup. This is a future optimization, not needed for initial implementation.

### 6.4 Pre-defined Metrics

Metrics that FlowRent should send:

#### 6.4.1 HTTP Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| http_requests_total | counter | method, endpoint, status | Total HTTP requests |
| http_request_duration_seconds | histogram | method, endpoint, status | Request latency |
| http_requests_in_progress | gauge | - | Currently processing requests |

#### 6.4.2 Business Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| booking_created_total | counter | rental_item_type | Bookings created |
| booking_confirmed_total | counter | rental_item_type | Bookings confirmed |
| booking_cancelled_total | counter | reason | Bookings cancelled |
| payment_received_total | counter | method | Payments marked |
| email_sent_total | counter | template | Emails sent |
| email_failed_total | counter | template, error | Failed emails |

#### 6.4.3 Background Job Metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| job_executed_total | counter | job_name, status | Job executions |
| job_duration_seconds | histogram | job_name | Job duration |

### 6.5 API Specification

#### 6.5.1 POST /api/metrics

Receive batch of metrics.

**Headers:**
- `X-API-Key: <api_key>` (required)
- `Content-Type: application/json`

**Request Body:**
```
{
  "metrics": [
    {
      "name": "http_requests_total",
      "type": "counter",
      "labels": {"method": "GET", "endpoint": "/bookings", "status": "200"},
      "value": 1,
      "timestamp": "2025-01-23T15:30:00Z"  // optional, defaults to now
    },
    {
      "name": "http_request_duration_seconds",
      "type": "histogram",
      "labels": {"method": "GET", "endpoint": "/bookings", "status": "200"},
      "value": 0.234
    }
  ]
}
```

**Response (202 Accepted):**
```
{
  "status": "accepted",
  "count": 2
}
```

#### 6.5.2 GET /api/metrics

Query aggregated metrics.

**Query Parameters:**
- `name` (required): Metric name
- `period` (optional): Time period - 1h, 24h, 7d, 30d (default: 24h)
- `resolution` (optional): minute, hour, auto (default: auto)
- `labels` (optional): Label filter, format: `key:value,key2:value2`

**Response (200 OK):**
```
{
  "name": "http_request_duration_seconds",
  "period": "24h",
  "resolution": "hour",
  "data": [
    {
      "bucket": "2025-01-22T16:00:00Z",
      "count": 1500,
      "avg": 0.156,
      "p50": 0.120,
      "p95": 0.450,
      "p99": 0.890
    },
    {
      "bucket": "2025-01-22T17:00:00Z",
      "count": 1800,
      "avg": 0.142,
      "p50": 0.110,
      "p95": 0.380,
      "p99": 0.750
    }
  ]
}
```

#### 6.5.3 GET /api/metrics/names

List available metrics.

**Response (200 OK):**
```
{
  "metrics": [
    {"name": "http_requests_total", "type": "counter"},
    {"name": "http_request_duration_seconds", "type": "histogram"},
    {"name": "booking_created_total", "type": "counter"}
  ]
}
```

#### 6.5.4 GET /api/dashboard

Pre-computed dashboard data.

**Query Parameters:**
- `period` (optional): 1h, 24h, 7d (default: 24h)

**Response (200 OK):**
```
{
  "period": "24h",
  "summary": {
    "total_requests": 45000,
    "error_rate": 0.02,
    "avg_latency_ms": 145,
    "p95_latency_ms": 380
  },
  "request_rate": [
    {"bucket": "2025-01-22T16:00:00Z", "count": 1500},
    {"bucket": "2025-01-22T17:00:00Z", "count": 1800}
  ],
  "latency": [
    {"bucket": "2025-01-22T16:00:00Z", "p50": 120, "p95": 450, "p99": 890},
    {"bucket": "2025-01-22T17:00:00Z", "p50": 110, "p95": 380, "p99": 750}
  ],
  "error_rate": [
    {"bucket": "2025-01-22T16:00:00Z", "rate": 0.015},
    {"bucket": "2025-01-22T17:00:00Z", "rate": 0.022}
  ],
  "top_endpoints": [
    {"endpoint": "/bookings", "requests": 12000, "avg_ms": 234, "error_rate": 0.01},
    {"endpoint": "/api/availability", "requests": 8000, "avg_ms": 89, "error_rate": 0.005}
  ]
}
```

#### 6.5.5 GET /health

Health check endpoint.

**Response (200 OK):**
```
{
  "status": "ok",
  "metrics_received_24h": 125000,
  "last_aggregation": "2025-01-23T15:35:00Z"
}
```

### 6.6 Aggregation Process

**Every minute:**
1. Query raw metrics from previous minute
2. Group by (name, labels)
3. For each group:
   - Calculate count, sum, min, max, avg
   - For histograms, calculate p50, p95, p99
4. Insert into aggregated table (resolution=minute)

**Every hour:**
1. Query minute aggregates from previous hour
2. Group by (name, labels)
3. Merge aggregates:
   - count = sum of counts
   - sum = sum of sums
   - min = min of mins
   - max = max of maxes
   - avg = total sum / total count
   - percentiles = weighted merge (approximate)
4. Insert into aggregated table (resolution=hour)

**Cleanup (daily):**
1. Delete raw metrics older than 1 hour
2. Delete minute aggregates older than 24 hours
3. Delete hourly aggregates older than retention period

### 6.7 Percentile Calculation

For histogram metrics, calculate approximate percentiles using sorted values.

**Algorithm:**
1. Collect all values in time bucket
2. Sort values
3. p50 = value at position count * 0.50
4. p95 = value at position count * 0.95
5. p99 = value at position count * 0.99

**Note:** For hourly aggregation, percentiles are approximated by weighting minute percentiles. This is less accurate but acceptable for this use case.

### 6.8 Configuration

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| DATABASE_PATH | string | ./data/metrics.db | SQLite database file path |
| API_KEY | string | (required) | Shared secret for authentication |
| RETENTION_RAW | string | 1h | Raw metrics retention |
| RETENTION_MINUTE | string | 24h | Minute aggregates retention |
| RETENTION_HOURLY | string | 30d | Hourly aggregates retention |
| AGGREGATION_INTERVAL | int | 60 | Seconds between aggregation runs |

---

## 7. FlowRent Integration

This section specifies the changes needed in FlowRent to integrate with the monitoring stack.

### 7.1 Configuration Additions

Add to FlowRent's `app/config.py`:

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| ERROR_TRACKER_URL | string | None | Error Tracker base URL |
| ERROR_TRACKER_API_KEY | string | None | Error Tracker API key |
| METRICS_COLLECTOR_URL | string | None | Metrics Collector base URL |
| METRICS_COLLECTOR_API_KEY | string | None | Metrics Collector API key |
| METRICS_FLUSH_INTERVAL | int | 10 | Seconds between metric flushes |

### 7.2 Error Tracking Integration

#### 7.2.1 Error Client Module

Create a new module `app/utils/error_client.py` with:

**Functions:**
- `report_error(request, exception)` - async, sends error to Error Tracker
- Handles connection failures gracefully (log warning, don't crash)
- Extracts request context if available

**Behavior:**
- Fire-and-forget (don't block request on error reporting)
- Timeout: 5 seconds
- No retries (best effort)

#### 7.2.2 Exception Handler

Add global exception handler in `app/main.py`:

**Behavior:**
1. Catch all unhandled exceptions
2. Call `report_error()` with request and exception
3. Log error locally (existing behavior)
4. Return appropriate error response

**Exclusions:**
- Don't report HTTPException (these are intentional)
- Don't report RequestValidationError (client errors)

### 7.3 Metrics Integration

#### 7.3.1 Metrics Client Module

Create a new module `app/utils/metrics_client.py` with:

**Functions:**
- `counter(name, labels, value=1)` - increment counter
- `histogram(name, labels, value)` - record histogram value
- `gauge(name, labels, value)` - set gauge value
- `flush()` - send buffered metrics to collector

**Behavior:**
- Buffer metrics in memory
- Flush every METRICS_FLUSH_INTERVAL seconds (background task)
- Flush on application shutdown
- Handle connection failures gracefully

#### 7.3.2 Request Metrics Middleware

Add middleware in `app/main.py`:

**Behavior:**
1. Record request start time
2. Process request
3. Record request end time
4. Emit metrics:
   - `http_requests_total` (counter)
   - `http_request_duration_seconds` (histogram)
5. Labels: method, endpoint (path template), status

**Endpoint normalization:**
- `/bookings/123` → `/bookings/{id}`
- `/users/456/profile` → `/users/{id}/profile`
- Use FastAPI route path template if available

#### 7.3.3 Business Metrics

Instrument key business operations:

| Location | Metric | When |
|----------|--------|------|
| routes/bookings.py | booking_created_total | After successful booking creation |
| routes/bookings.py | booking_confirmed_total | After booking confirmation |
| routes/bookings.py | booking_cancelled_total | After booking cancellation |
| services/email.py | email_sent_total | After successful email send |
| services/email.py | email_failed_total | After email send failure |
| scheduler.py | job_executed_total | After job completion |
| scheduler.py | job_duration_seconds | Job execution time |

### 7.4 Structured Logging (Optional Enhancement)

If enhanced log search is desired, switch to JSON logging:

**Changes:**
- Create JSONFormatter class
- Configure root logger to use JSON format
- Include structured fields: timestamp, level, logger, message

**JSON format:**
```
{"ts": "2025-01-23T15:30:00Z", "level": "INFO", "logger": "app.routes.bookings", "msg": "Booking created", "booking_id": 123}
```

### 7.5 Integration Checklist

| Component | Files to Modify | Effort | Note |
|-----------|-----------------|--------|------|
| Error Tracker Client | config.py, main.py, new error_client.py | Small | Python client; server is Zig |
| Metrics Collector Client | config.py, main.py, new metrics_client.py | Medium | Python client; server is Zig |
| Business Metrics | routes/bookings.py, services/email.py, scheduler.py | Small | Python instrumentation |
| JSON Logging | main.py or logging config | Small | Python logging config |

---

## 8. Deployment Architecture

### 8.1 Directory Structure

```
deploy/
├── docker-compose.prod.yml      # FlowRent production
├── docker-compose.dev.yml       # FlowRent development
├── docker-compose.monitoring.yml # Monitoring stack
├── secrets.env                  # Shared secrets
├── monitoring/
│   ├── error-tracker/
│   │   ├── src/                 # Zig source files
│   │   ├── build.zig
│   │   ├── build.zig.zon
│   │   └── Dockerfile
│   ├── log-viewer/
│   │   ├── src/                 # Zig source files
│   │   ├── build.zig
│   │   ├── build.zig.zon
│   │   └── Dockerfile
│   └── metrics-collector/
│       ├── src/                 # Zig source files
│       ├── build.zig
│       ├── build.zig.zon
│       └── Dockerfile
└── data/
    ├── errors/                  # Error Tracker SQLite
    ├── logs/                    # Log Viewer SQLite
    └── metrics/                 # Metrics Collector SQLite
```

### 8.2 Docker Compose Configuration

**docker-compose.monitoring.yml:**

```yaml
version: "3.8"

services:
  error-tracker:
    build: ./monitoring/error-tracker
    container_name: error_tracker
    ports:
      - "5010:8000"
    volumes:
      - ./data/errors:/app/data
    env_file:
      - secrets.env
    environment:
      - DATABASE_PATH=/app/data/errors.db
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "/app/error-tracker", "--healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - monitoring

  log-viewer:
    build: ./monitoring/log-viewer
    container_name: log_viewer
    ports:
      - "5011:8000"
    volumes:
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - ./data/logs:/app/data
    env_file:
      - secrets.env
    environment:
      - DATABASE_PATH=/app/data/logs.db
      - CONTAINERS=rentl_prod,rentl_dev
      - MAX_ENTRIES=100000
      - POLL_INTERVAL=5
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "/app/log-viewer", "--healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - monitoring

  metrics-collector:
    build: ./monitoring/metrics-collector
    container_name: metrics_collector
    ports:
      - "5012:8000"
    volumes:
      - ./data/metrics:/app/data
    env_file:
      - secrets.env
    environment:
      - DATABASE_PATH=/app/data/metrics.db
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "/app/metrics-collector", "--healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - monitoring

networks:
  monitoring:
    name: flowrent_network
    external: true
```

**Note:** Each Zig service compiles to a single static binary with no runtime dependencies. The Docker images use `scratch` or `alpine` as base image, resulting in images under 10MB.

### 8.3 Environment Variables

**secrets.env additions:**
```
# Error Tracker
ERROR_TRACKER_API_KEY=<generate-random-32-char-string>

# Log Viewer
LOG_VIEWER_API_KEY=<generate-random-32-char-string>

# Metrics Collector
METRICS_COLLECTOR_API_KEY=<generate-random-32-char-string>

# Shared (already exist for FlowRent)
POSTMARK_API_TOKEN=<existing>
POSTMARK_FROM_EMAIL=<existing>
OWNER_EMAILS=<existing>
```

### 8.4 Network Configuration

All services on same Docker network (`flowrent_network`):
- FlowRent can reach monitoring services by container name
- `http://error-tracker:8000` from within FlowRent container
- `http://metrics-collector:8000` from within FlowRent container

### 8.5 Port Mapping

| Service | Internal Port | External Port | Access |
|---------|---------------|---------------|--------|
| FlowRent Prod | 8000 | 5002 | Via nginx |
| FlowRent Dev | 8000 | 5001 | Via nginx |
| Error Tracker | 8000 | 5010 | Internal only |
| Log Viewer | 8000 | 5011 | Internal only |
| Metrics Collector | 8000 | 5012 | Internal only |

### 8.6 Nginx Configuration (Optional)

If external access to monitoring dashboards is needed:

```nginx
# /etc/nginx/sites-available/monitoring

server {
    listen 443 ssl;
    server_name monitoring.rentyourbikevalencia.com;

    ssl_certificate /etc/letsencrypt/live/.../fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/.../privkey.pem;

    # Basic auth for all monitoring endpoints
    auth_basic "Monitoring";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location /errors/ {
        proxy_pass http://127.0.0.1:5010/;
    }

    location /logs/ {
        proxy_pass http://127.0.0.1:5011/;
    }

    location /metrics/ {
        proxy_pass http://127.0.0.1:5012/;
    }
}
```

### 8.7 Deployment Commands

```bash
# Build monitoring stack (compiles Zig services inside Docker)
docker compose -f docker-compose.monitoring.yml build

# Start monitoring stack
docker compose -f docker-compose.monitoring.yml up -d

# View logs
docker compose -f docker-compose.monitoring.yml logs -f

# Restart single service
docker compose -f docker-compose.monitoring.yml restart error-tracker

# Stop monitoring stack
docker compose -f docker-compose.monitoring.yml down
```

### 8.8 Dockerfile Template (per service)

```dockerfile
# Build stage: compile Zig source to static binary
FROM alpine:3.19 AS builder

RUN apk add --no-cache zig sqlite-dev musl-dev

WORKDIR /build
COPY build.zig build.zig.zon ./
COPY src/ src/

RUN zig build -Doptimize=.ReleaseSafe

# Runtime stage: minimal image with just the binary
FROM alpine:3.19

RUN apk add --no-cache sqlite-libs

WORKDIR /app
COPY --from=builder /build/zig-out/bin/<service-name> /app/<service-name>

EXPOSE 8000
CMD ["/app/<service-name>"]
```

**Note:** Each resulting Docker image is ~15MB (Alpine base + static binary + SQLite shared lib).

---

## 9. Non-Functional Requirements

### 9.1 Performance

| Requirement | Target | Rationale |
|-------------|--------|-----------|
| Error Tracker API response time | < 100ms p95 | Don't slow down FlowRent error handling |
| Metrics Collector API response time | < 50ms p95 | High-frequency metric submission |
| Log Viewer search response time | < 500ms p95 | Acceptable for interactive use |
| Log Viewer ingestion lag | < 10 seconds | Near real-time log visibility |
| Dashboard page load time | < 1 second | Responsive UI |

### 9.2 Reliability

| Requirement | Target | Rationale |
|-------------|--------|-----------|
| Service availability | 99% | Monitoring can be briefly unavailable |
| Data durability | Best effort | Monitoring data is not critical |
| Graceful degradation | Required | FlowRent must work if monitoring fails |

**Graceful degradation behavior:**
- If Error Tracker unreachable: Log error locally, continue processing
- If Metrics Collector unreachable: Drop metrics, continue processing
- If Log Viewer down: Logs still captured by Docker, viewable via CLI

### 9.3 Scalability

| Requirement | Target | Rationale |
|-------------|--------|-----------|
| Concurrent FlowRent instances | 2 (prod + dev) | Current deployment |
| Errors per day | Up to 1,000 | Reasonable error volume |
| Log entries per day | Up to 100,000 | ~70 logs/minute |
| Metrics per day | Up to 500,000 | ~350 metrics/minute |

**Note:** These limits are well within SQLite's capabilities for a single-instance deployment.

### 9.4 Resource Limits

| Service | Max RAM | Max Disk | Max CPU |
|---------|---------|----------|---------|
| Error Tracker | 30MB | 500MB | 0.2 core |
| Log Viewer | 30MB | 500MB | 0.2 core |
| Metrics Collector | 30MB | 200MB | 0.2 core |
| **Total** | **90MB** | **1.2GB** | **0.6 core** |

### 9.5 Data Retention

| Data Type | Retention | Rationale |
|-----------|-----------|-----------|
| Errors (unresolved) | Indefinite | Until manually resolved |
| Errors (resolved) | 90 days | Historical reference |
| Logs | 100k entries (~7 days) | Recent debugging |
| Metrics (raw) | 1 hour | Aggregation source |
| Metrics (minute) | 24 hours | Recent detail |
| Metrics (hourly) | 30 days | Trend analysis |

### 9.6 Backup

| Data | Backup Strategy |
|------|-----------------|
| Error Tracker SQLite | Daily copy to S3 (optional) |
| Log Viewer SQLite | No backup (reconstructible from Docker logs) |
| Metrics Collector SQLite | No backup (historical metrics not critical) |

### 9.7 Monitoring the Monitoring

Each service exposes `/health` endpoint:
- Can be monitored by external uptime checker
- Returns service-specific health metrics
- Used by Docker health checks for auto-restart

### 9.8 Request Limits

| Service | Max Request Body | Rate Limit |
|---------|-----------------|------------|
| Error Tracker | 256KB per POST | 100 requests/minute per API key |
| Metrics Collector | 512KB per POST | 200 requests/minute per API key |
| Log Viewer | N/A (read-only) | 60 requests/minute per API key |

**Behavior on limit exceeded:**
- Body too large: Return `413 Payload Too Large` with `{"detail": "Request body exceeds maximum size"}`
- Rate limit exceeded: Return `429 Too Many Requests` with `{"detail": "Rate limit exceeded", "retry_after": N}`

**Rate limiting implementation:**
- Simple in-memory sliding window counter per API key
- No external dependencies (no Redis)
- Reset on service restart (acceptable for this use case)
- Rate limits are generous enough to never trigger under normal FlowRent load

### 9.9 Timestamps and Timezones

All timestamps throughout the monitoring stack use **UTC** exclusively:
- Stored in SQLite as ISO8601 strings with `Z` suffix (e.g., `2025-01-23T15:30:00Z`)
- API responses always use UTC ISO8601 format
- API request parameters (`since`, `until`, `timestamp`) are parsed as UTC; timezone offsets are accepted and converted to UTC on ingestion
- Web UI displays timestamps in UTC with a "(UTC)" label
- FlowRent clients must send timestamps in UTC (or omit to use server time)

### 9.10 Concurrency Model

**Zig service architecture:**
- Single-threaded event loop using Zig's `std.http.Server`
- One HTTP connection handled at a time (sufficient for low-traffic monitoring services)
- Background tasks (log polling, metric aggregation, retention cleanup) run on separate threads
- If concurrency becomes a bottleneck, migrate to a thread-pool model with N worker threads (future enhancement)

**SQLite configuration:**
- WAL (Write-Ahead Logging) mode enabled on startup for concurrent read/write support
- Busy timeout set to 5000ms to handle contention between HTTP thread and background threads
- Single database connection per thread (no connection pooling needed)
- `PRAGMA journal_mode=WAL;` and `PRAGMA busy_timeout=5000;` executed on connection open
- `PRAGMA synchronous=NORMAL;` for balanced durability/performance (monitoring data is not critical)
- `PRAGMA foreign_keys=ON;` for referential integrity

### 9.11 Graceful Shutdown

Each service must handle `SIGTERM` and `SIGINT` signals:
1. Stop accepting new HTTP connections
2. Wait for in-flight HTTP requests to complete (max 5 second timeout)
3. Stop background tasks (polling, aggregation)
4. Flush any pending writes to SQLite
5. Close SQLite connections cleanly (ensures WAL checkpoint)
6. Exit with code 0

**Docker integration:** Docker sends `SIGTERM` on `docker stop`, waits 10 seconds (default), then sends `SIGKILL`. The 5-second drain timeout ensures clean shutdown within this window.

### 9.12 Service Logging

The monitoring services themselves log to stdout in a structured JSON format:

```
{"ts": "2025-01-23T15:30:00Z", "level": "INFO", "service": "error-tracker", "msg": "Server started on port 8000"}
```

**Log levels:**
- `ERROR`: Service-level failures (SQLite errors, Postmark API failures)
- `WARN`: Degraded conditions (rate limit hit, oversized request rejected, connection timeouts)
- `INFO`: Operational events (startup, shutdown, ingestion stats, aggregation runs)
- `DEBUG`: Detailed request/response logging (disabled in production)

**Configuration:** `LOG_LEVEL` environment variable (default: `INFO`)

Logs are captured by Docker's json-file log driver and can be viewed via `docker logs` or ingested by the Log Viewer itself.

### 9.13 Database Migration Strategy

**Philosophy:** Keep schema changes simple and additive; avoid complex migration frameworks.

**Implementation:**
1. Each service stores a `schema_version` in a `_meta` table: `CREATE TABLE IF NOT EXISTS _meta (key TEXT PRIMARY KEY, value TEXT);`
2. On startup, the service reads the current `schema_version` (default: "0" if table doesn't exist)
3. Migrations are defined as an ordered array of SQL statements in the Zig source code, each associated with a version number
4. The service executes all migrations with version > current, inside a transaction
5. After all migrations succeed, `schema_version` is updated to the latest version

**Example migration sequence:**
```
Version 1: CREATE TABLE errors (...)
Version 2: ALTER TABLE errors ADD COLUMN severity VARCHAR(20) DEFAULT 'error';
Version 3: CREATE INDEX idx_severity ON errors(severity);
```

**Rules:**
- Migrations are append-only; never modify or delete an existing migration
- Each migration must be idempotent where possible (use `IF NOT EXISTS`)
- Breaking changes (column removal, type changes) require a new table + data copy approach
- Rollbacks are not supported; fix forward only

### 9.14 CORS Policy

**Default:** No CORS headers are sent. Services are designed for same-origin access only (served from the same host via nginx).

**If cross-origin access is needed** (e.g., monitoring UI on a different subdomain):
- Add `CORS_ORIGINS` environment variable (comma-separated allowed origins)
- When set, respond with `Access-Control-Allow-Origin`, `Access-Control-Allow-Headers` (X-API-Key, Content-Type), and `Access-Control-Allow-Methods`
- Preflight `OPTIONS` requests return 204 with CORS headers

### 9.15 Upgrade and Deployment Procedure

**Standard upgrade (zero-downtime for FlowRent):**

```bash
# 1. Pull latest code
git pull origin main

# 2. Build new images
docker compose -f docker-compose.monitoring.yml build

# 3. Rolling restart (one service at a time)
docker compose -f docker-compose.monitoring.yml up -d --no-deps error-tracker
docker compose -f docker-compose.monitoring.yml up -d --no-deps log-viewer
docker compose -f docker-compose.monitoring.yml up -d --no-deps metrics-collector

# 4. Verify health
curl http://localhost:5010/health
curl http://localhost:5011/health
curl http://localhost:5012/health
```

**Notes:**
- FlowRent is unaffected during monitoring stack restarts (graceful degradation applies)
- SQLite databases persist across restarts via volume mounts
- Schema migrations run automatically on startup (see 9.13)
- If a migration fails, the service logs the error and exits; the previous container version continues running until the issue is resolved

### 9.16 Backup

**Error Tracker database:**
- Optional daily backup script copies `errors.db` to S3 using the SQLite `.backup` API (or `sqlite3 errors.db ".backup /tmp/errors-backup.db"`)
- Cron job or Docker-based scheduled task
- Retain last 7 daily backups

**Log Viewer and Metrics Collector databases:**
- No backup needed (logs reconstructible from Docker, metrics are ephemeral by design)

**Backup script (`deploy/backup.sh`):**
```bash
#!/bin/bash
BACKUP_DIR="/tmp/monlight-backups"
DATE=$(date +%Y%m%d)
mkdir -p "$BACKUP_DIR"
sqlite3 /path/to/data/errors/errors.db ".backup $BACKUP_DIR/errors-$DATE.db"
# Upload to S3 (optional)
# aws s3 cp "$BACKUP_DIR/errors-$DATE.db" s3://bucket/backups/
# Cleanup old backups
find "$BACKUP_DIR" -name "errors-*.db" -mtime +7 -delete
```

---

## 10. Security Considerations

### 10.1 Authentication

| Service | Method | Scope |
|---------|--------|-------|
| Error Tracker API | API Key (X-API-Key header) | All POST and GET endpoints |
| Error Tracker UI | None (internal network only) | Or nginx basic auth |
| Log Viewer API | API Key (X-API-Key header) | All GET endpoints (except /health) |
| Log Viewer UI | None (internal network only) | Or nginx basic auth |
| Metrics Collector API | API Key (X-API-Key header) | All POST and GET endpoints |
| Metrics Collector UI | None (internal network only) | Or nginx basic auth |

### 10.2 Network Security

| Control | Implementation |
|---------|----------------|
| Internal services | Don't expose ports 5010-5012 to internet |
| Service-to-service | Docker network isolation |
| External access | Via nginx with basic auth (optional) |
| TLS | Terminate at nginx if exposed |

### 10.3 Data Privacy (GDPR)

| Concern | Mitigation |
|---------|------------|
| Customer PII in errors | FlowRent filters PII before sending |
| Customer PII in logs | Don't log customer data; or redact |
| Request headers | Don't include Authorization header |
| User identification | Use internal user ID, not email |

**FlowRent error filtering:**
- Strip customer email, phone, address from error context
- Include only: user_id, booking_id (internal identifiers)
- Never include: passwords, tokens, payment info

### 10.4 API Key Management

| Requirement | Implementation |
|-------------|----------------|
| Key generation | `openssl rand -base64 32` |
| Key storage | Environment variables in secrets.env |
| Key rotation | Manual; update both sides |
| Key length | Minimum 32 characters |

### 10.5 SQLite Security

| Concern | Mitigation |
|---------|------------|
| File permissions | 600 (owner read/write only) |
| SQL injection | Use parameterized queries via SQLite C API bind functions |
| Data at rest | Not encrypted (acceptable for monitoring data) |

---

## 11. Future Enhancements

Potential improvements if requirements grow:

### 11.1 Error Tracker

| Enhancement | Description | Trigger |
|-------------|-------------|---------|
| Slack notifications | Alert to Slack channel | Team prefers Slack |
| Error assignment | Assign errors to team members | Multiple developers |
| Release tracking | Track errors by release version | Frequent releases |
| Source context | Show code around error line | Complex debugging |

### 11.2 Log Viewer

| Enhancement | Description | Trigger |
|-------------|-------------|---------|
| Request tracing | Correlate logs by request ID | Debugging complex flows |
| Log forwarding | Forward to external service | Compliance requirements |
| Saved searches | Save common search queries | Repeated investigations |
| Alerting | Alert on log patterns | Proactive monitoring |

### 11.3 Metrics Collector

| Enhancement | Description | Trigger |
|-------------|-------------|---------|
| Custom dashboards | User-defined charts | Complex analysis |
| Alerting | Threshold-based alerts | Proactive monitoring |
| Anomaly detection | Detect unusual patterns | Mature operations |
| Export to Prometheus | Prometheus-compatible endpoint | Integration with external tools |

### 11.4 Cross-Service

| Enhancement | Description | Trigger |
|-------------|-------------|---------|
| Unified UI | Single dashboard for all services | Convenience |
| Correlation | Link errors to logs to metrics | Root cause analysis |
| Multi-tenant | Support multiple applications | New projects |

---

## Appendix A: Glossary

| Term | Definition |
|------|------------|
| Fingerprint | Hash identifying unique errors for grouping |
| Ring buffer | Fixed-size buffer that overwrites oldest entries |
| Histogram | Metric type tracking distribution of values |
| Counter | Metric type tracking cumulative count |
| Gauge | Metric type tracking point-in-time value |
| Percentile | Value below which a percentage of data falls |
| SSE | Server-Sent Events, for real-time streaming |
| FTS | Full-Text Search |

## Appendix B: References

- Zig language documentation: https://ziglang.org/documentation/master/
- Zig standard library HTTP server: https://ziglang.org/documentation/master/std/#std.http.Server
- SQLite C API: https://www.sqlite.org/cintro.html
- SQLite FTS5: https://www.sqlite.org/fts5.html
- FastAPI documentation: https://fastapi.tiangolo.com/ (FlowRent client)
- Docker logging: https://docs.docker.com/config/containers/logging/
- Postmark API: https://postmarkapp.com/developer
