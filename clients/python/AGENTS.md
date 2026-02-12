# Python Client - Development Guide

## Setup
```bash
cd clients/python
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
```

## Running Tests
```bash
pytest tests/ -v
```

## Package Structure
- `monlightstack/__init__.py` - Top-level exports: `ErrorClient`, `MetricsClient`
- `monlightstack/error_client.py` - Error tracking client (async + sync)
- `monlightstack/metrics_client.py` - Metrics collection client with buffering
- `monlightstack/integrations/fastapi.py` - FastAPI middleware + exception handler

## Key Patterns
- `ErrorClient.report_error()` is async; use `report_error_sync()` for synchronous contexts
- `MetricsClient` buffers metrics in-memory and flushes via background `threading.Timer`
- Call `MetricsClient.start()` to begin automatic periodic flushing
- Call `MetricsClient.shutdown()` on app shutdown to flush remaining metrics
- `MonlightExceptionHandler` reads the error client from `request.app.state.monlight_error_client`
- `setup_monlight()` is the recommended way to wire up both error tracking and metrics in FastAPI
- PII filtering: `Authorization`, `Cookie`, `Set-Cookie`, `X-API-Key` headers are always stripped from error reports

## Dependencies
- `httpx` - HTTP client (async + sync)
- `starlette` / `fastapi` - Required only for the FastAPI integration module
- `pytest`, `pytest-asyncio`, `pytest-httpx` - Testing dependencies (in `[dev]` extra)
