"""Error tracking client for MonlightStack Error Tracker service."""

from __future__ import annotations

import logging
import traceback as tb_module
from typing import Any

import httpx

logger = logging.getLogger(__name__)

# Headers that should never be sent to the error tracker (PII/security)
_SENSITIVE_HEADERS = frozenset({"authorization", "cookie", "set-cookie", "x-api-key"})


class ErrorClient:
    """Client for reporting errors to MonlightStack Error Tracker.

    Sends error reports via HTTP POST to the Error Tracker service.
    Designed for fire-and-forget usage: connection failures are logged
    but never raised to the caller.

    Args:
        base_url: Base URL of the Error Tracker service (e.g., "http://error-tracker:8000").
        api_key: API key for authentication.
        project: Project identifier (e.g., "flowrent").
        environment: Environment name (e.g., "prod", "dev", "staging").
        timeout: HTTP request timeout in seconds. Defaults to 5.
        excluded_headers: Additional header names to strip from reports.
    """

    def __init__(
        self,
        base_url: str,
        api_key: str,
        project: str = "default",
        environment: str = "prod",
        timeout: float = 5.0,
        excluded_headers: set[str] | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.project = project
        self.environment = environment
        self.timeout = timeout
        self._excluded_headers = _SENSITIVE_HEADERS | {
            h.lower() for h in (excluded_headers or set())
        }

    def _filter_headers(self, headers: dict[str, str]) -> dict[str, str]:
        """Remove sensitive headers from the dict."""
        return {
            k: v for k, v in headers.items() if k.lower() not in self._excluded_headers
        }

    def _build_payload(
        self,
        exception: BaseException,
        request_context: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Build the JSON payload for the error report."""
        payload: dict[str, Any] = {
            "project": self.project,
            "environment": self.environment,
            "exception_type": type(exception).__qualname__,
            "message": str(exception),
            "traceback": "".join(tb_module.format_exception(exception)),
        }

        if request_context:
            if "request_url" in request_context:
                payload["request_url"] = request_context["request_url"]
            if "request_method" in request_context:
                payload["request_method"] = request_context["request_method"]
            if "request_headers" in request_context:
                payload["request_headers"] = self._filter_headers(
                    request_context["request_headers"]
                )
            if "user_id" in request_context:
                payload["user_id"] = str(request_context["user_id"])
            if "extra" in request_context:
                payload["extra"] = request_context["extra"]

        return payload

    async def report_error(
        self,
        exception: BaseException,
        request_context: dict[str, Any] | None = None,
    ) -> None:
        """Report an error to the Error Tracker service.

        This is a fire-and-forget operation. Connection failures are caught
        and logged at warning level but never raised.

        Args:
            exception: The exception to report.
            request_context: Optional dict with keys: request_url, request_method,
                request_headers, user_id, extra.
        """
        payload = self._build_payload(exception, request_context)
        try:
            async with httpx.AsyncClient(timeout=self.timeout) as client:
                response = await client.post(
                    f"{self.base_url}/api/errors",
                    json=payload,
                    headers={"X-API-Key": self.api_key},
                )
                if response.status_code not in (200, 201):
                    logger.warning(
                        "Error tracker returned status %d: %s",
                        response.status_code,
                        response.text[:200],
                    )
        except Exception:
            logger.warning("Failed to report error to error tracker", exc_info=True)

    def report_error_sync(
        self,
        exception: BaseException,
        request_context: dict[str, Any] | None = None,
    ) -> None:
        """Synchronous version of report_error.

        Uses a synchronous HTTP client. Connection failures are caught
        and logged at warning level but never raised.
        """
        payload = self._build_payload(exception, request_context)
        try:
            with httpx.Client(timeout=self.timeout) as client:
                response = client.post(
                    f"{self.base_url}/api/errors",
                    json=payload,
                    headers={"X-API-Key": self.api_key},
                )
                if response.status_code not in (200, 201):
                    logger.warning(
                        "Error tracker returned status %d: %s",
                        response.status_code,
                        response.text[:200],
                    )
        except Exception:
            logger.warning("Failed to report error to error tracker", exc_info=True)
