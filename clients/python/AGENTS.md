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

## Testing Patterns
- Use `pytest-httpx` fixture `httpx_mock` to intercept HTTP calls (works for both async and sync)
- `httpx_mock.add_response(status_code=..., json=...)` for success cases
- `httpx_mock.add_exception(httpx.ConnectError(...))` for failure simulation
- `httpx_mock.get_requests()` to inspect sent requests (headers are lowercased)
- `caplog` fixture with `caplog.at_level(logging.WARNING, logger="monlightstack.error_client")` to verify warning logs
- `asyncio_mode = "auto"` in pyproject.toml means async test functions are auto-detected (no `@pytest.mark.asyncio` needed)
- When testing `MetricsClient` periodic timer, always pair `client.start()` with `client.shutdown()` in try/finally to avoid dangling timer threads
