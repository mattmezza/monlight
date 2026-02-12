"""Tests for the ErrorClient class.

Covers:
- Payload formatting (exception_type, message, traceback extraction)
- PII header filtering
- HTTP request correctness (URL, method, headers)
- Fire-and-forget behavior (timeout handling, connection failure logging)
- Request context extraction
"""

from __future__ import annotations

import logging
from unittest.mock import patch

import httpx
import pytest

from monlightstack.error_client import ErrorClient


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def client() -> ErrorClient:
    """Standard error client for testing."""
    return ErrorClient(
        base_url="http://localhost:5010",
        api_key="test-api-key",
        project="myproject",
        environment="prod",
    )


def _make_exception() -> ValueError:
    """Create a real exception with a traceback."""
    try:
        raise ValueError("something went wrong")
    except ValueError as exc:
        return exc


def _make_nested_exception() -> TypeError:
    """Create an exception from a nested call for realistic traceback."""

    def inner():
        raise TypeError("bad type")

    try:
        inner()
    except TypeError as exc:
        return exc


# ---------------------------------------------------------------------------
# Payload formatting tests
# ---------------------------------------------------------------------------


class TestBuildPayload:
    """Tests for _build_payload (payload formatting)."""

    def test_basic_payload_fields(self, client: ErrorClient):
        """Payload contains project, environment, exception_type, message, traceback."""
        exc = _make_exception()
        payload = client._build_payload(exc)

        assert payload["project"] == "myproject"
        assert payload["environment"] == "prod"
        assert payload["exception_type"] == "ValueError"
        assert payload["message"] == "something went wrong"
        assert "traceback" in payload
        assert "ValueError" in payload["traceback"]
        assert "something went wrong" in payload["traceback"]

    def test_exception_type_uses_qualname(self, client: ErrorClient):
        """exception_type uses __qualname__ for nested classes."""

        class Outer:
            class InnerError(Exception):
                pass

        try:
            raise Outer.InnerError("nested")
        except Outer.InnerError as exc:
            payload = client._build_payload(exc)

        assert (
            payload["exception_type"]
            == "TestBuildPayload.test_exception_type_uses_qualname.<locals>.Outer.InnerError"
        )

    def test_traceback_contains_stack_frames(self, client: ErrorClient):
        """Traceback includes file and line information."""
        exc = _make_exception()
        payload = client._build_payload(exc)

        # Should contain the file reference
        assert "test_error_client.py" in payload["traceback"]
        assert "raise ValueError" in payload["traceback"]

    def test_payload_without_request_context(self, client: ErrorClient):
        """Payload without request_context has no extra fields."""
        exc = _make_exception()
        payload = client._build_payload(exc)

        assert "request_url" not in payload
        assert "request_method" not in payload
        assert "request_headers" not in payload
        assert "user_id" not in payload
        assert "extra" not in payload

    def test_payload_with_full_request_context(self, client: ErrorClient):
        """Payload includes all request context fields when provided."""
        exc = _make_exception()
        context = {
            "request_url": "/api/bookings",
            "request_method": "POST",
            "request_headers": {
                "Content-Type": "application/json",
                "Accept": "text/html",
            },
            "user_id": "user-42",
            "extra": {"booking_id": 123},
        }
        payload = client._build_payload(exc, request_context=context)

        assert payload["request_url"] == "/api/bookings"
        assert payload["request_method"] == "POST"
        assert payload["request_headers"] == {
            "Content-Type": "application/json",
            "Accept": "text/html",
        }
        assert payload["user_id"] == "user-42"
        assert payload["extra"] == {"booking_id": 123}

    def test_payload_with_partial_request_context(self, client: ErrorClient):
        """Only provided context fields are included."""
        exc = _make_exception()
        context = {"request_url": "/health"}
        payload = client._build_payload(exc, request_context=context)

        assert payload["request_url"] == "/health"
        assert "request_method" not in payload
        assert "request_headers" not in payload
        assert "user_id" not in payload

    def test_user_id_converted_to_string(self, client: ErrorClient):
        """user_id is converted to string regardless of input type."""
        exc = _make_exception()
        context = {"user_id": 42}
        payload = client._build_payload(exc, request_context=context)

        assert payload["user_id"] == "42"
        assert isinstance(payload["user_id"], str)

    def test_none_request_context_ignored(self, client: ErrorClient):
        """None request_context doesn't add extra fields."""
        exc = _make_exception()
        payload = client._build_payload(exc, request_context=None)

        assert "request_url" not in payload


# ---------------------------------------------------------------------------
# PII filtering tests
# ---------------------------------------------------------------------------


class TestPIIFiltering:
    """Tests for sensitive header filtering."""

    def test_authorization_header_stripped(self, client: ErrorClient):
        """Authorization header is never included."""
        exc = _make_exception()
        context = {
            "request_headers": {
                "Authorization": "Bearer secret-token",
                "Content-Type": "application/json",
            }
        }
        payload = client._build_payload(exc, request_context=context)

        assert "Authorization" not in payload["request_headers"]
        assert "Content-Type" in payload["request_headers"]

    def test_cookie_header_stripped(self, client: ErrorClient):
        """Cookie header is never included."""
        exc = _make_exception()
        context = {
            "request_headers": {
                "Cookie": "session=abc123",
                "Accept": "*/*",
            }
        }
        payload = client._build_payload(exc, request_context=context)

        assert "Cookie" not in payload["request_headers"]
        assert "Accept" in payload["request_headers"]

    def test_set_cookie_header_stripped(self, client: ErrorClient):
        """Set-Cookie header is never included."""
        exc = _make_exception()
        context = {
            "request_headers": {
                "Set-Cookie": "session=abc123; Path=/",
                "Content-Length": "42",
            }
        }
        payload = client._build_payload(exc, request_context=context)

        assert "Set-Cookie" not in payload["request_headers"]
        assert "Content-Length" in payload["request_headers"]

    def test_x_api_key_header_stripped(self, client: ErrorClient):
        """X-API-Key header is never included."""
        exc = _make_exception()
        context = {
            "request_headers": {
                "X-API-Key": "my-secret-key",
                "User-Agent": "test/1.0",
            }
        }
        payload = client._build_payload(exc, request_context=context)

        assert "X-API-Key" not in payload["request_headers"]
        assert "User-Agent" in payload["request_headers"]

    def test_filtering_is_case_insensitive(self, client: ErrorClient):
        """Header filtering works regardless of case."""
        exc = _make_exception()
        context = {
            "request_headers": {
                "AUTHORIZATION": "Bearer secret",
                "cookie": "session=abc",
                "X-Api-Key": "key",
            }
        }
        payload = client._build_payload(exc, request_context=context)

        assert len(payload["request_headers"]) == 0

    def test_custom_excluded_headers(self):
        """Custom excluded headers are also stripped."""
        client = ErrorClient(
            base_url="http://localhost:5010",
            api_key="key",
            excluded_headers={"X-Custom-Secret", "X-Internal-Token"},
        )
        exc = _make_exception()
        context = {
            "request_headers": {
                "X-Custom-Secret": "secret",
                "X-Internal-Token": "token",
                "Authorization": "Bearer abc",
                "Accept": "text/html",
            }
        }
        payload = client._build_payload(exc, request_context=context)

        assert "X-Custom-Secret" not in payload["request_headers"]
        assert "X-Internal-Token" not in payload["request_headers"]
        assert "Authorization" not in payload["request_headers"]
        assert payload["request_headers"] == {"Accept": "text/html"}

    def test_empty_headers_after_filtering(self, client: ErrorClient):
        """All-sensitive headers result in empty dict, not omission."""
        exc = _make_exception()
        context = {"request_headers": {"Authorization": "Bearer x", "Cookie": "y"}}
        payload = client._build_payload(exc, request_context=context)

        assert payload["request_headers"] == {}


# ---------------------------------------------------------------------------
# HTTP request tests (using pytest-httpx)
# ---------------------------------------------------------------------------


class TestReportError:
    """Tests for async report_error HTTP behavior."""

    async def test_sends_post_to_correct_url(self, client: ErrorClient, httpx_mock):
        """POST is sent to {base_url}/api/errors."""
        httpx_mock.add_response(status_code=201, json={"status": "created", "id": 1})

        exc = _make_exception()
        await client.report_error(exc)

        requests = httpx_mock.get_requests()
        assert len(requests) == 1
        assert requests[0].method == "POST"
        assert str(requests[0].url) == "http://localhost:5010/api/errors"

    async def test_sends_api_key_header(self, client: ErrorClient, httpx_mock):
        """X-API-Key header is included in the request."""
        httpx_mock.add_response(status_code=201, json={"status": "created", "id": 1})

        exc = _make_exception()
        await client.report_error(exc)

        requests = httpx_mock.get_requests()
        assert requests[0].headers["x-api-key"] == "test-api-key"

    async def test_sends_correct_json_body(self, client: ErrorClient, httpx_mock):
        """Request body contains all required fields."""
        httpx_mock.add_response(status_code=201, json={"status": "created", "id": 1})

        exc = _make_exception()
        await client.report_error(exc)

        requests = httpx_mock.get_requests()
        body = requests[0].read()
        import json

        payload = json.loads(body)

        assert payload["project"] == "myproject"
        assert payload["environment"] == "prod"
        assert payload["exception_type"] == "ValueError"
        assert payload["message"] == "something went wrong"
        assert "traceback" in payload
        assert len(payload["traceback"]) > 0

    async def test_sends_request_context_in_body(self, client: ErrorClient, httpx_mock):
        """Request context fields are included in the body."""
        httpx_mock.add_response(
            status_code=200, json={"status": "incremented", "id": 1, "count": 2}
        )

        exc = _make_exception()
        context = {
            "request_url": "/api/test",
            "request_method": "GET",
            "request_headers": {"Accept": "application/json"},
            "user_id": "u1",
            "extra": {"key": "value"},
        }
        await client.report_error(exc, request_context=context)

        requests = httpx_mock.get_requests()
        import json

        payload = json.loads(requests[0].read())

        assert payload["request_url"] == "/api/test"
        assert payload["request_method"] == "GET"
        assert payload["request_headers"] == {"Accept": "application/json"}
        assert payload["user_id"] == "u1"
        assert payload["extra"] == {"key": "value"}

    async def test_handles_201_response(self, client: ErrorClient, httpx_mock):
        """201 response (new error) is accepted without error."""
        httpx_mock.add_response(status_code=201, json={"status": "created", "id": 5})

        exc = _make_exception()
        await client.report_error(exc)  # Should not raise

    async def test_handles_200_response(self, client: ErrorClient, httpx_mock):
        """200 response (incremented error) is accepted without error."""
        httpx_mock.add_response(
            status_code=200, json={"status": "incremented", "id": 5, "count": 3}
        )

        exc = _make_exception()
        await client.report_error(exc)  # Should not raise


# ---------------------------------------------------------------------------
# Fire-and-forget / timeout tests
# ---------------------------------------------------------------------------


class TestFireAndForget:
    """Tests for fire-and-forget behavior."""

    async def test_connection_failure_does_not_raise(
        self, client: ErrorClient, httpx_mock
    ):
        """Connection failure is caught, not raised."""
        httpx_mock.add_exception(httpx.ConnectError("Connection refused"))

        exc = _make_exception()
        await client.report_error(exc)  # Should not raise

    async def test_connection_failure_logs_warning(
        self, client: ErrorClient, httpx_mock, caplog
    ):
        """Connection failure is logged at warning level."""
        httpx_mock.add_exception(httpx.ConnectError("Connection refused"))

        exc = _make_exception()
        with caplog.at_level(logging.WARNING, logger="monlightstack.error_client"):
            await client.report_error(exc)

        assert any(
            "Failed to report error" in record.message for record in caplog.records
        )

    async def test_timeout_does_not_raise(self, client: ErrorClient, httpx_mock):
        """Timeout is caught, not raised."""
        httpx_mock.add_exception(httpx.ReadTimeout("Read timed out"))

        exc = _make_exception()
        await client.report_error(exc)  # Should not raise

    async def test_server_error_logs_warning(
        self, client: ErrorClient, httpx_mock, caplog
    ):
        """Non-200/201 response is logged at warning level."""
        httpx_mock.add_response(status_code=500, text="Internal Server Error")

        exc = _make_exception()
        with caplog.at_level(logging.WARNING, logger="monlightstack.error_client"):
            await client.report_error(exc)

        assert any(
            "Error tracker returned status 500" in record.message
            for record in caplog.records
        )

    async def test_401_response_logs_warning(
        self, client: ErrorClient, httpx_mock, caplog
    ):
        """401 response is logged at warning level."""
        httpx_mock.add_response(status_code=401, json={"detail": "Invalid API key"})

        exc = _make_exception()
        with caplog.at_level(logging.WARNING, logger="monlightstack.error_client"):
            await client.report_error(exc)

        assert any(
            "Error tracker returned status 401" in record.message
            for record in caplog.records
        )

    def test_default_timeout_is_5_seconds(self):
        """Default timeout is 5 seconds."""
        client = ErrorClient(base_url="http://localhost:5010", api_key="key")
        assert client.timeout == 5.0

    def test_custom_timeout(self):
        """Custom timeout is respected."""
        client = ErrorClient(
            base_url="http://localhost:5010", api_key="key", timeout=10.0
        )
        assert client.timeout == 10.0


# ---------------------------------------------------------------------------
# Sync variant tests
# ---------------------------------------------------------------------------


class TestReportErrorSync:
    """Tests for synchronous report_error_sync."""

    def test_sync_sends_post(self, client: ErrorClient, httpx_mock):
        """Sync variant sends POST to correct URL."""
        httpx_mock.add_response(status_code=201, json={"status": "created", "id": 1})

        exc = _make_exception()
        client.report_error_sync(exc)

        requests = httpx_mock.get_requests()
        assert len(requests) == 1
        assert requests[0].method == "POST"
        assert str(requests[0].url) == "http://localhost:5010/api/errors"

    def test_sync_connection_failure_does_not_raise(
        self, client: ErrorClient, httpx_mock
    ):
        """Sync variant catches connection failures."""
        httpx_mock.add_exception(httpx.ConnectError("Connection refused"))

        exc = _make_exception()
        client.report_error_sync(exc)  # Should not raise

    def test_sync_sends_api_key(self, client: ErrorClient, httpx_mock):
        """Sync variant includes X-API-Key header."""
        httpx_mock.add_response(status_code=201, json={"status": "created", "id": 1})

        exc = _make_exception()
        client.report_error_sync(exc)

        requests = httpx_mock.get_requests()
        assert requests[0].headers["x-api-key"] == "test-api-key"
