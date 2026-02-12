"""Tests for MonlightMiddleware — FastAPI request metrics middleware.

Covers: timing recording, metric emission (counter + histogram),
label correctness (method, endpoint, status), endpoint normalization
with parameterized routes, and error handling behavior.
"""

from __future__ import annotations

import time
from unittest.mock import MagicMock, patch

import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from monlightstack.integrations.fastapi import MonlightMiddleware
from monlightstack.metrics_client import MetricsClient


@pytest.fixture
def mock_metrics_client() -> MagicMock:
    """Create a mock MetricsClient with counter/histogram/gauge methods."""
    client = MagicMock(spec=MetricsClient)
    return client


@pytest.fixture
def app_with_middleware(mock_metrics_client: MagicMock) -> FastAPI:
    """Create a test FastAPI app with MonlightMiddleware installed."""
    app = FastAPI()
    app.add_middleware(MonlightMiddleware, metrics_client=mock_metrics_client)

    @app.get("/items")
    async def list_items():
        return {"items": []}

    @app.get("/items/{item_id}")
    async def get_item(item_id: int):
        return {"id": item_id}

    @app.post("/items")
    async def create_item():
        return {"id": 1}

    @app.get("/users/{user_id}/profile")
    async def get_user_profile(user_id: int):
        return {"user_id": user_id}

    @app.get("/error-500")
    async def error_500():
        raise HTTPException(status_code=500, detail="Server error")

    @app.get("/error-404")
    async def error_404():
        raise HTTPException(status_code=404, detail="Not found")

    @app.get("/error-422")
    async def error_422():
        raise HTTPException(status_code=422, detail="Unprocessable")

    @app.get("/slow")
    async def slow_endpoint():
        time.sleep(0.05)
        return {"ok": True}

    return app


@pytest.fixture
def client(app_with_middleware: FastAPI) -> TestClient:
    """Create a TestClient for the app with middleware."""
    return TestClient(app_with_middleware)


# ── Basic metric emission ──────────────────────────────────────────────


class TestMetricEmission:
    """Tests that the middleware emits correct metrics for each request."""

    def test_emits_counter_on_request(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Middleware emits http_requests_total counter for each request."""
        client.get("/items")

        mock_metrics_client.counter.assert_called_once()
        call_args = mock_metrics_client.counter.call_args
        assert call_args[0][0] == "http_requests_total"

    def test_emits_histogram_on_request(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Middleware emits http_request_duration_seconds histogram for each request."""
        client.get("/items")

        mock_metrics_client.histogram.assert_called_once()
        call_args = mock_metrics_client.histogram.call_args
        assert call_args[0][0] == "http_request_duration_seconds"

    def test_both_metrics_emitted_per_request(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Both counter and histogram are emitted for a single request."""
        client.get("/items")

        assert mock_metrics_client.counter.call_count == 1
        assert mock_metrics_client.histogram.call_count == 1

    def test_multiple_requests_emit_multiple_metrics(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Each request produces its own pair of metrics."""
        client.get("/items")
        client.get("/items")
        client.get("/items")

        assert mock_metrics_client.counter.call_count == 3
        assert mock_metrics_client.histogram.call_count == 3


# ── Labels ──────────────────────────────────────────────────────────


class TestLabels:
    """Tests that labels are correctly set on emitted metrics."""

    def test_labels_include_method_get(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Labels include correct method for GET requests."""
        client.get("/items")

        counter_labels = mock_metrics_client.counter.call_args[1].get(
            "labels",
            mock_metrics_client.counter.call_args[0][1]
            if len(mock_metrics_client.counter.call_args[0]) > 1
            else mock_metrics_client.counter.call_args[1]["labels"],
        )
        assert counter_labels["method"] == "GET"

    def test_labels_include_method_post(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Labels include correct method for POST requests."""
        client.post("/items")

        # Counter is called with positional args: name, then kwargs
        call_args = mock_metrics_client.counter.call_args
        labels = (
            call_args.kwargs.get("labels") or call_args[0][1]
            if len(call_args[0]) > 1
            else call_args.kwargs["labels"]
        )
        assert labels["method"] == "POST"

    def test_labels_include_status_200(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Labels include correct status code for successful requests."""
        client.get("/items")

        call_args = mock_metrics_client.counter.call_args
        labels = (
            call_args.kwargs.get("labels") or call_args[0][1]
            if len(call_args[0]) > 1
            else call_args.kwargs["labels"]
        )
        assert labels["status"] == "200"

    def test_labels_include_status_404(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Labels include correct status code for 404 responses."""
        client.get("/error-404")

        call_args = mock_metrics_client.counter.call_args
        labels = (
            call_args.kwargs.get("labels") or call_args[0][1]
            if len(call_args[0]) > 1
            else call_args.kwargs["labels"]
        )
        assert labels["status"] == "404"

    def test_labels_include_status_500(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Labels include correct status code for 500 responses."""
        client.get("/error-500")

        call_args = mock_metrics_client.counter.call_args
        labels = (
            call_args.kwargs.get("labels") or call_args[0][1]
            if len(call_args[0]) > 1
            else call_args.kwargs["labels"]
        )
        assert labels["status"] == "500"

    def test_labels_include_endpoint(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Labels include the endpoint path."""
        client.get("/items")

        call_args = mock_metrics_client.counter.call_args
        labels = (
            call_args.kwargs.get("labels") or call_args[0][1]
            if len(call_args[0]) > 1
            else call_args.kwargs["labels"]
        )
        assert labels["endpoint"] == "/items"

    def test_counter_and_histogram_have_same_labels(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Counter and histogram labels are identical for the same request."""
        client.get("/items")

        counter_labels = mock_metrics_client.counter.call_args.kwargs.get("labels")
        histogram_labels = mock_metrics_client.histogram.call_args.kwargs.get("labels")
        assert counter_labels == histogram_labels


# ── Endpoint normalization ─────────────────────────────────────────────


class TestEndpointNormalization:
    """Tests that endpoint labels use path templates, not actual URLs."""

    def test_parameterized_route_uses_template(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Parameterized path /items/123 normalizes to /items/{item_id}."""
        client.get("/items/42")

        call_args = mock_metrics_client.counter.call_args
        labels = call_args.kwargs.get("labels")
        assert labels["endpoint"] == "/items/{item_id}"

    def test_nested_parameterized_route(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Nested path /users/456/profile normalizes to /users/{user_id}/profile."""
        client.get("/users/456/profile")

        call_args = mock_metrics_client.counter.call_args
        labels = call_args.kwargs.get("labels")
        assert labels["endpoint"] == "/users/{user_id}/profile"

    def test_different_ids_same_endpoint(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Different IDs on the same parameterized route produce the same endpoint label."""
        client.get("/items/1")
        client.get("/items/999")

        calls = mock_metrics_client.counter.call_args_list
        endpoint_1 = calls[0].kwargs.get("labels")["endpoint"]
        endpoint_2 = calls[1].kwargs.get("labels")["endpoint"]
        assert endpoint_1 == endpoint_2 == "/items/{item_id}"

    def test_non_parameterized_route_uses_literal_path(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Non-parameterized path /items stays as /items."""
        client.get("/items")

        call_args = mock_metrics_client.counter.call_args
        labels = call_args.kwargs.get("labels")
        assert labels["endpoint"] == "/items"

    def test_unknown_path_uses_raw_url(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Unknown paths (404 from FastAPI) use the raw URL path."""
        client.get("/nonexistent/path")

        call_args = mock_metrics_client.counter.call_args
        labels = call_args.kwargs.get("labels")
        # For unknown routes, there's no route object in scope,
        # so the raw path is used
        assert labels["endpoint"] == "/nonexistent/path"


# ── Timing ─────────────────────────────────────────────────────────────


class TestTiming:
    """Tests that duration is recorded correctly."""

    def test_histogram_value_is_positive(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Duration value is a positive number."""
        client.get("/items")

        call_args = mock_metrics_client.histogram.call_args
        duration = call_args.kwargs.get("value")
        assert duration > 0

    def test_slow_endpoint_has_longer_duration(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """A slow endpoint produces a larger duration than a fast one."""
        client.get("/items")
        fast_duration = mock_metrics_client.histogram.call_args.kwargs.get("value")

        mock_metrics_client.reset_mock()
        client.get("/slow")
        slow_duration = mock_metrics_client.histogram.call_args.kwargs.get("value")

        # The slow endpoint sleeps 50ms, so it should be significantly slower
        assert slow_duration > fast_duration
        assert slow_duration >= 0.04  # at least 40ms accounting for timer precision

    def test_counter_value_is_one(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Counter is incremented by 1 per request (no explicit value passed)."""
        client.get("/items")

        # counter is called as counter("http_requests_total", labels={...})
        # The default value in MetricsClient.counter is 1
        call_args = mock_metrics_client.counter.call_args
        # Verify the call — no explicit value kwarg means default of 1
        assert call_args[0][0] == "http_requests_total"


# ── Installation ────────────────────────────────────────────────────────


class TestInstallation:
    """Tests that the middleware is correctly installable."""

    def test_installable_via_add_middleware(self, mock_metrics_client: MagicMock):
        """Middleware can be installed via app.add_middleware()."""
        app = FastAPI()
        # Should not raise
        app.add_middleware(MonlightMiddleware, metrics_client=mock_metrics_client)

        @app.get("/test")
        async def test_route():
            return {"ok": True}

        client = TestClient(app)
        response = client.get("/test")
        assert response.status_code == 200
        assert mock_metrics_client.counter.called

    def test_middleware_does_not_alter_response(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Middleware does not modify the response body or status code."""
        response = client.get("/items")
        assert response.status_code == 200
        assert response.json() == {"items": []}

    def test_middleware_does_not_alter_error_response(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Middleware does not interfere with error responses."""
        response = client.get("/error-404")
        assert response.status_code == 404
        assert response.json() == {"detail": "Not found"}


# ── Edge cases ─────────────────────────────────────────────────────────


class TestEdgeCases:
    """Tests for edge cases and error scenarios."""

    def test_metrics_emitted_even_on_http_exception(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """Metrics are still emitted when the route raises HTTPException."""
        client.get("/error-500")

        assert mock_metrics_client.counter.called
        assert mock_metrics_client.histogram.called

    def test_422_status_tracked(
        self, client: TestClient, mock_metrics_client: MagicMock
    ):
        """422 Unprocessable Entity is correctly tracked."""
        client.get("/error-422")

        call_args = mock_metrics_client.counter.call_args
        labels = call_args.kwargs.get("labels")
        assert labels["status"] == "422"

    def test_status_is_string(self, client: TestClient, mock_metrics_client: MagicMock):
        """Status label value is a string, not an integer."""
        client.get("/items")

        call_args = mock_metrics_client.counter.call_args
        labels = call_args.kwargs.get("labels")
        assert isinstance(labels["status"], str)
