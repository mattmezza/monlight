# Contributing to Monlight

Thanks for your interest in contributing to Monlight.

## Development Setup

### Prerequisites

- [Zig 0.13.0](https://ziglang.org/download/) (for backend services)
- Docker and Docker Compose (for integration testing)
- Python >= 3.10 (for the Python client)
- Node.js >= 21 (for the JS SDK)

### Building Zig services

Each service can be built and tested independently:

```bash
cd error-tracker   # or log-viewer, metrics-collector, browser-relay
zig build
zig build test
```

The services share common modules from `shared/` (sqlite, auth, rate limiting, config).

### Python client

```bash
cd clients/python
pip install -e ".[dev]"
pytest tests/ -v
```

### JS SDK

```bash
cd clients/js
npm install
npm test
npm run build
```

## Running the Full Stack Locally

```bash
# Build all services from source
docker compose -f deploy/docker-compose.monitoring.yml up -d --build

# Run smoke tests
bash deploy/smoke-test.sh

# Tear down
docker compose -f deploy/docker-compose.monitoring.yml down -v
```

## Submitting Changes

1. Fork the repository and create a branch from `main`.
2. Make your changes and ensure tests pass.
3. Keep commits focused -- one logical change per commit.
4. Open a pull request against `main`.

## Code Style

- **Zig**: Follow the [Zig style guide](https://ziglang.org/documentation/master/#Style-Guide). No external formatting tools needed -- `zig fmt` handles it.
- **Python**: Standard Python conventions. The project uses `ruff` for linting.
- **TypeScript**: The JS SDK is small and uses `esbuild` for bundling. Keep the bundle under 5KB gzipped.

## Reporting Issues

Open an issue on GitHub. Include:

- Which service/component is affected
- Steps to reproduce
- Expected vs actual behavior
- Relevant logs (use `docker compose logs <service>`)

## Release Process

See the [Releasing New Versions](README.md#releasing-new-versions) section in the README.
