"""FastAPI integration for Monlight monitoring.

Provides middleware for automatic request metrics and an exception handler
for error tracking.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any, Callable

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.types import ASGIApp

from monlight.error_client import ErrorClient
from monlight.metrics_client import MetricsClient

logger = logging.getLogger(__name__)


class MonlightMiddleware(BaseHTTPMiddleware):
    """ASGI middleware that records HTTP request metrics.

    Emits ``http_requests_total`` (counter) and
    ``http_request_duration_seconds`` (histogram) for every request.

    Labels: method, endpoint (normalized path template), status.

    Usage::

        app.add_middleware(MonlightMiddleware, metrics_client=client)
    """

    def __init__(self, app: ASGIApp, metrics_client: MetricsClient) -> None:
        super().__init__(app)
        self.metrics_client = metrics_client

    async def dispatch(self, request: Request, call_next: Callable) -> Response:  # type: ignore[type-arg]
        start = time.perf_counter()
        response: Response | None = None
        try:
            response = await call_next(request)
            return response
        finally:
            duration = time.perf_counter() - start
            status = str(response.status_code) if response else "500"
            endpoint = self._normalize_endpoint(request)
            labels = {
                "method": request.method,
                "endpoint": endpoint,
                "status": status,
            }
            self.metrics_client.counter("http_requests_total", labels=labels)
            self.metrics_client.histogram(
                "http_request_duration_seconds", value=duration, labels=labels
            )

    @staticmethod
    def _normalize_endpoint(request: Request) -> str:
        """Extract the path template from the request scope.

        FastAPI populates ``request.scope["route"]`` with the matched route
        object, which has a ``.path`` attribute containing the template
        (e.g., ``/bookings/{id}`` instead of ``/bookings/123``).
        """
        route = request.scope.get("route")
        if route and hasattr(route, "path"):
            return route.path  # type: ignore[no-any-return]
        return request.url.path


async def MonlightExceptionHandler(request: Request, exc: Exception) -> JSONResponse:
    """Global exception handler that reports errors to Monlight.

    Catches all unhandled exceptions (excluding ``HTTPException`` and
    ``RequestValidationError``), reports them to the Error Tracker, and
    returns a generic 500 JSON response.

    Usage::

        app.add_exception_handler(Exception, MonlightExceptionHandler)

    Note: The ``ErrorClient`` must be attached to ``request.app.state.monlight_error_client``
    before this handler is invoked. Use :func:`setup_monlight` to wire everything up.
    """
    error_client: ErrorClient | None = getattr(
        request.app.state, "monlight_error_client", None
    )

    if error_client is not None:
        request_context: dict[str, Any] = {
            "request_url": str(request.url),
            "request_method": request.method,
        }
        # Extract headers as a plain dict
        try:
            request_context["request_headers"] = dict(request.headers)
        except Exception:
            pass

        # Fire-and-forget: schedule but don't await result
        asyncio.create_task(_safe_report(error_client, exc, request_context))

    logger.exception("Unhandled exception: %s", exc)
    return JSONResponse(
        status_code=500,
        content={"detail": "Internal server error"},
    )


async def _safe_report(
    client: ErrorClient,
    exc: Exception,
    ctx: dict[str, Any],
) -> None:
    """Report error without propagating failures."""
    try:
        await client.report_error(exc, request_context=ctx)
    except Exception:
        logger.warning("Failed to report error in exception handler", exc_info=True)


def setup_monlight(
    app: Any,
    *,
    error_tracker_url: str | None = None,
    metrics_collector_url: str | None = None,
    api_key: str,
    project: str = "default",
    environment: str = "prod",
    flush_interval: float = 10.0,
) -> dict[str, Any]:
    """Wire up Monlight monitoring on a FastAPI/Starlette application.

    This is a convenience function that sets up both the exception handler
    and the metrics middleware in a single call.

    Args:
        app: The FastAPI or Starlette application instance.
        error_tracker_url: Base URL for the Error Tracker service. If None,
            error tracking is disabled.
        metrics_collector_url: Base URL for the Metrics Collector service.
            If None, metrics collection is disabled.
        api_key: Shared API key for both services.
        project: Project identifier for error reports.
        environment: Environment name for error reports.
        flush_interval: Seconds between automatic metric flushes.

    Returns:
        Dict with ``error_client`` and ``metrics_client`` keys (values may
        be None if the corresponding URL was not provided).
    """
    result: dict[str, Any] = {"error_client": None, "metrics_client": None}

    if error_tracker_url:
        error_client = ErrorClient(
            base_url=error_tracker_url,
            api_key=api_key,
            project=project,
            environment=environment,
        )
        app.state.monlight_error_client = error_client
        app.add_exception_handler(Exception, MonlightExceptionHandler)
        result["error_client"] = error_client
        logger.info("Monlight error tracking enabled: %s", error_tracker_url)

    if metrics_collector_url:
        metrics_client = MetricsClient(
            base_url=metrics_collector_url,
            api_key=api_key,
            flush_interval=flush_interval,
        )
        app.add_middleware(MonlightMiddleware, metrics_client=metrics_client)
        metrics_client.start()
        result["metrics_client"] = metrics_client
        logger.info("Monlight metrics collection enabled: %s", metrics_collector_url)

    return result
