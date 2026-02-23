---
layout: default
title: Deployment
nav_order: 8
---

# Deployment

## Quick start (Docker Compose)

```bash
git clone https://github.com/mattmezza/monlight.git
cd monlight
cp deploy/secrets.env.example deploy/secrets.env
# Edit deploy/secrets.env with your API keys
docker compose up -d
```

This pulls pre-built images from GHCR (~15MB each). Services are available at ports 5010-5013.

## Building from source

Use the monitoring compose file to build locally:

```bash
docker compose -f deploy/docker-compose.monitoring.yml up --build -d
```

This builds all four services from source using multi-stage Docker builds (Zig build stage + Alpine 3.21 runtime).

## Reverse proxy (nginx)

An example nginx config is provided at `deploy/nginx.conf.example`. Key points:

- TLS termination at nginx
- Error tracker, log viewer, and metrics collector behind basic auth
- Browser relay **must not** have basic auth (browsers need direct access; auth is via DSN keys)

```nginx
location /error-tracker/ {
    auth_basic "Monitoring";
    auth_basic_user_file /etc/nginx/.htpasswd;
    proxy_pass http://127.0.0.1:5010/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

# Browser relay - NO basic auth (public endpoint)
location /browser-relay/ {
    proxy_pass http://127.0.0.1:5013/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

## Backups

`deploy/backup.sh` creates consistent SQLite backups using the `.backup` command (safe for WAL-mode databases).

```bash
./deploy/backup.sh              # Back up all databases
./deploy/backup.sh errors       # Back up only errors.db
./deploy/backup.sh logs metrics # Specific databases
```

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_DIR` | `deploy/backups` | Where backups are stored |
| `DATA_DIR` | `deploy/data` | Where live databases reside |
| `RETENTION_COUNT` | `7` | Daily backups to keep per database |

Each backup runs `PRAGMA integrity_check` to verify validity. Old backups beyond `RETENTION_COUNT` are automatically pruned.

**Recommended crontab:**

```
0 3 * * * /path/to/deploy/backup.sh >> /var/log/monlight-backup.log 2>&1
```

The script has a commented-out section for S3-compatible upload (AWS, MinIO, Contabo).

## Upgrades

`deploy/upgrade.sh` performs rolling upgrades with health verification:

```bash
./deploy/upgrade.sh                           # Upgrade all services
./deploy/upgrade.sh error-tracker             # Single service
./deploy/upgrade.sh --no-backup --no-pull     # Skip backup and git pull
```

| Flag | Description |
|------|-------------|
| `--no-pull` | Skip `git pull` |
| `--no-backup` | Skip pre-upgrade backup |
| `--force` | Continue past health check failures |

The script:

1. Tags current Docker images as `:rollback`
2. Runs `backup.sh` (unless `--no-backup`)
3. Pulls latest code (unless `--no-pull`)
4. For each service: rebuilds, restarts, polls `/health` for up to 60 seconds
5. On failure: prints exact rollback commands

**Manual rollback:**

```bash
git checkout <previous-commit>
docker compose -f deploy/docker-compose.monitoring.yml build <service>
docker compose -f deploy/docker-compose.monitoring.yml up -d --no-deps <service>
```

## Smoke tests

`deploy/smoke-test.sh` runs end-to-end tests against all four services. Uses the test compose file with offset ports (15010-15013) and hardcoded test credentials.

```bash
docker compose -f deploy/docker-compose.test.yml up --build -d
./deploy/smoke-test.sh
docker compose -f deploy/docker-compose.test.yml down -v
```

Tests cover: health checks, error submission and deduplication, metrics ingestion, DSN key management, browser relay forwarding, CORS, source map upload, rate limiting, and graceful shutdown.

## Resource limits

Each service runs within a 30MB Docker memory limit. The full stack uses under 50MB RAM.

| Service | Memory limit | Docker image size |
|---------|-------------|-------------------|
| Error Tracker | 30MB | <20MB |
| Log Viewer | 30MB | <20MB |
| Metrics Collector | 30MB | <20MB |
| Browser Relay | 30MB | <20MB |

CI enforces the 20MB image size limit. Docker images fail to publish if they exceed this threshold.

## Releases

Releases are managed via the root `Makefile`:

```bash
make release-error-tracker V=1.0.0   # Single service
make release-services V=1.0.0        # All 4 Zig services
make release-python V=1.0.0          # Python SDK to PyPI
make release-js V=1.0.0              # JS SDK to npm
make release-all V=1.0.0             # Everything
make versions                        # Show current versions
```

Each release target bumps the version in source files, commits, tags, and pushes. CI handles building and publishing based on the tag:

| Tag pattern | CI action |
|-------------|-----------|
| `error-tracker-v*` | Build + push Docker image to GHCR |
| `log-viewer-v*` | Build + push Docker image to GHCR |
| `metrics-collector-v*` | Build + push Docker image to GHCR |
| `browser-relay-v*` | Build + push Docker image to GHCR |
| `python-v*` | Publish to PyPI |
| `js-v*` | Publish to npm |

## Docker network

All services communicate on an internal Docker network (`monlight`). The browser relay connects to the error tracker and metrics collector via internal hostnames (`http://error-tracker:8000`, `http://metrics-collector:8000`). Only the exposed ports (5010-5013) are accessible from outside Docker.
