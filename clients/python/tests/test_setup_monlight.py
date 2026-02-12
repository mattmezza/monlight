"""Tests for setup_monlight() — the convenience function that wires up
both error tracking and metrics collection with a single call.

Covers: error client creation, metrics client creation, exception handler
registration, middleware installation, partial setup (one URL only),
no-op setup (no URLs), return value contents, and end-to-end behavior.
"""

from __future__ import annotations

import asyncio
from unittest.mock import MagicMock, patch

import httpx
import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from monlight.error_client import ErrorClient
from monlight.integrations.fastapi import setup_monlight
from monlight.metrics_client import MetricsClient


# ── Wiring up both services ────────────────────────────────────────────


class TestFullSetup:
    """Tests when both error_tracker_url and metrics_collector_url are given."""

    def test_returns_both_clients(self):
        """setup_monlight returns dict with both error_client and metrics_client."""
        app = FastAPI()
        result = setup_monlight(
            app,
            error_tracker_url="http://errors:5010",
            metrics_collector_url="http://metrics:5012",
            api_key="test-key",
        )
        try:
            assert isinstance(result["error_client"], ErrorClient)
            assert isinstance(result["metrics_client"], MetricsClient)
        finally:
            if result["metrics_client"]:
                result["metrics_client"].shutdown()

    def test_error_client_stored_on_app_state(self):
        """ErrorClient is attached to app.state.monlight_error_client."""
        app = FastAPI()
        result = setup_monlight(
            app,
            error_tracker_url="http://errors:5010",
            metrics_collector_url="http://metrics:5012",
            api_key="test-key",
        )
        try:
            assert app.state.monlight_error_client is result["error_client"]
        finally:
            if result["metrics_client"]:
                result["metrics_client"].shutdown()

    def test_error_client_configured_correctly(self):
        """ErrorClient receives the correct URL, API key, project, and env."""
        app = FastAPI()
        result = setup_monlight(
            app,
            error_tracker_url="http://errors:5010",
            metrics_collector_url="http://metrics:5012",
            api_key="my-key",
            project="flowrent",
            environment="staging",
        )
        try:
            ec = result["error_client"]
            assert ec.base_url == "http://errors:5010"
            assert ec.api_key == "my-key"
            assert ec.project == "flowrent"
            assert ec.environment == "staging"
        finally:
            if result["metrics_client"]:
                result["metrics_client"].shutdown()

    def test_metrics_client_configured_correctly(self):
        """MetricsClient receives the correct URL, API key, and flush interval."""
        app = FastAPI()
        result = setup_monlight(
            app,
            error_tracker_url="http://errors:5010",
            metrics_collector_url="http://metrics:5012",
            api_key="my-key",
            flush_interval=30.0,
        )
        try:
            mc = result["metrics_client"]
            assert mc.base_url == "http://metrics:5012"
            assert mc.api_key == "my-key"
            assert mc.flush_interval == 30.0
        finally:
            if result["metrics_client"]:
                result["metrics_client"].shutdown()

    def test_metrics_client_is_started(self):
        """MetricsClient.start() is called so periodic flushing is active."""
        app = FastAPI()
        with patch.object(MetricsClient, "start") as mock_start:
            result = setup_monlight(
                app,
                metrics_collector_url="http://metrics:5012",
                api_key="test-key",
            )
        # start() should have been called once
        mock_start.assert_called_once()
        # Clean up — since start was mocked, no timer is actually running
        if result["metrics_client"]:
            result["metrics_client"].shutdown()


# ── Error tracking only ────────────────────────────────────────────────


class TestErrorTrackingOnly:
    """Tests when only error_tracker_url is provided."""

    def test_error_client_created_metrics_is_none(self):
        """When only error tracker URL is given, metrics_client is None."""
        app = FastAPI()
        result = setup_monlight(
            app,
            error_tracker_url="http://errors:5010",
            api_key="test-key",
        )
        assert isinstance(result["error_client"], ErrorClient)
        assert result["metrics_client"] is None

    def test_exception_handler_registered(self, httpx_mock):
        """Exception handler is registered and catches unhandled exceptions."""
        httpx_mock.add_response(status_code=201, json={"status": "created", "id": 1})

        app = FastAPI()
        setup_monlight(
            app,
            error_tracker_url="http://errors:5010",
            api_key="test-key",
        )

        @app.get("/crash")
        async def crash():
            raise RuntimeError("boom")

        client = TestClient(app, raise_server_exceptions=False)
        response = client.get("/crash")
        assert response.status_code == 500
        assert response.json() == {"detail": "Internal server error"}


# ── Metrics only ───────────────────────────────────────────────────────


class TestMetricsOnly:
    """Tests when only metrics_collector_url is provided."""

    def test_metrics_client_created_error_is_none(self):
        """When only metrics URL is given, error_client is None."""
        app = FastAPI()
        result = setup_monlight(
            app,
            metrics_collector_url="http://metrics:5012",
            api_key="test-key",
        )
        try:
            assert result["error_client"] is None
            assert isinstance(result["metrics_client"], MetricsClient)
        finally:
            if result["metrics_client"]:
                result["metrics_client"].shutdown()

    def test_middleware_installed_and_records_metrics(self):
        """Middleware is installed and records request metrics."""
        app = FastAPI()

        @app.get("/hello")
        async def hello():
            return {"msg": "hi"}

        with (
            patch.object(MetricsClient, "counter") as mock_counter,
            patch.object(MetricsClient, "histogram") as mock_histogram,
            patch.object(MetricsClient, "start"),
        ):
            result = setup_monlight(
                app,
                metrics_collector_url="http://metrics:5012",
                api_key="test-key",
            )
            try:
                client = TestClient(app)
                client.get("/hello")

                mock_counter.assert_called()
                mock_histogram.assert_called()

                counter_call = mock_counter.call_args
                assert counter_call[0][0] == "http_requests_total"
            finally:
                if result["metrics_client"]:
                    result["metrics_client"].shutdown()


# ── No URLs provided ──────────────────────────────────────────────────


class TestNoUrls:
    """Tests when neither URL is provided — should be a safe no-op."""

    def test_both_clients_are_none(self):
        """When no URLs are given, both clients are None."""
        app = FastAPI()
        result = setup_monlight(app, api_key="test-key")
        assert result["error_client"] is None
        assert result["metrics_client"] is None

    def test_app_works_normally(self):
        """App still works normally with no monitoring configured."""
        app = FastAPI()
        setup_monlight(app, api_key="test-key")

        @app.get("/test")
        async def test_route():
            return {"ok": True}

        client = TestClient(app)
        response = client.get("/test")
        assert response.status_code == 200
        assert response.json() == {"ok": True}


# ── Default parameters ─────────────────────────────────────────────────


class TestDefaults:
    """Tests for default parameter values."""

    def test_default_project(self):
        """Default project is 'default'."""
        app = FastAPI()
        result = setup_monlight(
            app,
            error_tracker_url="http://errors:5010",
            api_key="k",
        )
        assert result["error_client"].project == "default"

    def test_default_environment(self):
        """Default environment is 'prod'."""
        app = FastAPI()
        result = setup_monlight(
            app,
            error_tracker_url="http://errors:5010",
            api_key="k",
        )
        assert result["error_client"].environment == "prod"

    def test_default_flush_interval(self):
        """Default flush interval is 10.0 seconds."""
        app = FastAPI()
        result = setup_monlight(
            app,
            metrics_collector_url="http://metrics:5012",
            api_key="k",
        )
        try:
            assert result["metrics_client"].flush_interval == 10.0
        finally:
            if result["metrics_client"]:
                result["metrics_client"].shutdown()

    def test_custom_project_and_environment(self):
        """Custom project and environment are passed to ErrorClient."""
        app = FastAPI()
        result = setup_monlight(
            app,
            error_tracker_url="http://errors:5010",
            api_key="k",
            project="my-app",
            environment="dev",
        )
        assert result["error_client"].project == "my-app"
        assert result["error_client"].environment == "dev"


# ── End-to-end: single call enables all monitoring ─────────────────────


class TestEndToEnd:
    """Verifies the key acceptance criterion: a single function call
    in FlowRent's main.py enables all monitoring."""

    @pytest.mark.httpx_mock(can_send_already_matched_responses=True)
    def test_single_call_enables_everything(self, httpx_mock):
        """A single setup_monlight call enables both error tracking and metrics."""
        # Mock the error tracker and metrics collector HTTP endpoints
        httpx_mock.add_response(status_code=201, json={"status": "created", "id": 1})
        httpx_mock.add_response(
            url="http://metrics:5012/api/metrics",
            status_code=202,
            json={"status": "accepted", "count": 0},
        )

        app = FastAPI()

        # This is the single function call from the acceptance criterion
        result = setup_monlight(
            app,
            error_tracker_url="http://errors:5010",
            metrics_collector_url="http://metrics:5012",
            api_key="shared-key",
            project="flowrent",
            environment="prod",
        )

        try:
            # Add a route that crashes
            @app.get("/api/bookings")
            async def bookings():
                return {"bookings": []}

            @app.get("/api/crash")
            async def crash():
                raise ValueError("test error")

            client = TestClient(app, raise_server_exceptions=False)

            # Normal request should record metrics
            with (
                patch.object(type(result["metrics_client"]), "counter") as mock_counter,
                patch.object(
                    type(result["metrics_client"]), "histogram"
                ) as mock_histogram,
            ):
                client.get("/api/bookings")
                assert mock_counter.called
                assert mock_histogram.called

            # Crashing request should trigger error reporting
            response = client.get("/api/crash")
            assert response.status_code == 500
            assert response.json() == {"detail": "Internal server error"}

        finally:
            if result["metrics_client"]:
                result["metrics_client"].shutdown()
