"""Tests for the MetricsClient class.

Covers:
- Counter, histogram, gauge buffering
- Payload formatting (metric fields, timestamps, labels)
- Flush behavior (single batch POST, buffer cleared)
- Periodic flush via background timer
- Shutdown (flush remaining, stop timer)
- Connection failure handling (log warning, drop metrics)
"""

from __future__ import annotations

import json
import logging
import time
from unittest.mock import patch

import httpx
import pytest

from monlight.metrics_client import MetricsClient


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def client() -> MetricsClient:
    """Standard metrics client for testing (no auto-flush timer)."""
    return MetricsClient(
        base_url="http://localhost:5012",
        api_key="test-metrics-key",
        flush_interval=10.0,
        timeout=5.0,
    )


# ---------------------------------------------------------------------------
# Buffering tests
# ---------------------------------------------------------------------------


class TestBuffering:
    """Tests for in-memory metric buffering."""

    def test_counter_buffers_metric(self, client: MetricsClient):
        """counter() adds a metric to the buffer."""
        client.counter("http_requests_total")

        assert len(client._buffer) == 1
        m = client._buffer[0]
        assert m["name"] == "http_requests_total"
        assert m["type"] == "counter"
        assert m["value"] == 1

    def test_counter_with_custom_value(self, client: MetricsClient):
        """counter() accepts a custom value."""
        client.counter("http_requests_total", value=5)

        assert client._buffer[0]["value"] == 5

    def test_counter_with_labels(self, client: MetricsClient):
        """counter() stores labels when provided."""
        client.counter(
            "http_requests_total",
            labels={"method": "GET", "endpoint": "/bookings"},
        )

        m = client._buffer[0]
        assert m["labels"] == {"method": "GET", "endpoint": "/bookings"}

    def test_counter_without_labels_omits_field(self, client: MetricsClient):
        """counter() without labels does not include labels key."""
        client.counter("http_requests_total")

        assert "labels" not in client._buffer[0]

    def test_histogram_buffers_metric(self, client: MetricsClient):
        """histogram() adds a metric to the buffer."""
        client.histogram("http_request_duration_seconds", 0.234)

        assert len(client._buffer) == 1
        m = client._buffer[0]
        assert m["name"] == "http_request_duration_seconds"
        assert m["type"] == "histogram"
        assert m["value"] == 0.234

    def test_histogram_with_labels(self, client: MetricsClient):
        """histogram() stores labels when provided."""
        client.histogram(
            "http_request_duration_seconds",
            0.150,
            labels={"method": "POST", "status": "200"},
        )

        m = client._buffer[0]
        assert m["labels"] == {"method": "POST", "status": "200"}

    def test_gauge_buffers_metric(self, client: MetricsClient):
        """gauge() adds a metric to the buffer."""
        client.gauge("active_rentals", 42)

        assert len(client._buffer) == 1
        m = client._buffer[0]
        assert m["name"] == "active_rentals"
        assert m["type"] == "gauge"
        assert m["value"] == 42

    def test_gauge_with_labels(self, client: MetricsClient):
        """gauge() stores labels when provided."""
        client.gauge("active_rentals", 42, labels={"city": "Valencia"})

        assert client._buffer[0]["labels"] == {"city": "Valencia"}

    def test_multiple_metrics_buffered(self, client: MetricsClient):
        """Multiple metrics are buffered in order."""
        client.counter("req_total", value=1)
        client.histogram("req_duration", 0.1)
        client.gauge("active", 5)

        assert len(client._buffer) == 3
        assert client._buffer[0]["type"] == "counter"
        assert client._buffer[1]["type"] == "histogram"
        assert client._buffer[2]["type"] == "gauge"

    def test_metrics_have_timestamps(self, client: MetricsClient):
        """All buffered metrics include an ISO 8601 timestamp."""
        client.counter("test_metric")

        ts = client._buffer[0]["timestamp"]
        assert "T" in ts
        assert ts.endswith("Z")

    def test_counter_default_value_is_one(self, client: MetricsClient):
        """counter() default value is 1."""
        client.counter("test_counter")

        assert client._buffer[0]["value"] == 1


# ---------------------------------------------------------------------------
# Flush tests
# ---------------------------------------------------------------------------


class TestFlush:
    """Tests for the flush() method."""

    def test_flush_sends_batch_post(self, client: MetricsClient, httpx_mock):
        """flush() sends all buffered metrics in a single POST."""
        httpx_mock.add_response(
            status_code=202, json={"status": "accepted", "count": 2}
        )

        client.counter("metric_a")
        client.histogram("metric_b", 0.5)
        client.flush()

        requests = httpx_mock.get_requests()
        assert len(requests) == 1
        assert requests[0].method == "POST"

        body = json.loads(requests[0].read())
        assert "metrics" in body
        assert len(body["metrics"]) == 2

    def test_flush_sends_to_correct_url(self, client: MetricsClient, httpx_mock):
        """flush() POSTs to {base_url}/api/metrics."""
        httpx_mock.add_response(
            status_code=202, json={"status": "accepted", "count": 1}
        )

        client.counter("test")
        client.flush()

        requests = httpx_mock.get_requests()
        assert str(requests[0].url) == "http://localhost:5012/api/metrics"

    def test_flush_sends_api_key_header(self, client: MetricsClient, httpx_mock):
        """flush() includes X-API-Key header."""
        httpx_mock.add_response(
            status_code=202, json={"status": "accepted", "count": 1}
        )

        client.counter("test")
        client.flush()

        requests = httpx_mock.get_requests()
        assert requests[0].headers["x-api-key"] == "test-metrics-key"

    def test_flush_clears_buffer(self, client: MetricsClient, httpx_mock):
        """Buffer is cleared after successful flush."""
        httpx_mock.add_response(
            status_code=202, json={"status": "accepted", "count": 1}
        )

        client.counter("test")
        assert len(client._buffer) == 1

        client.flush()
        assert len(client._buffer) == 0

    def test_flush_empty_buffer_no_request(self, client: MetricsClient, httpx_mock):
        """flush() with empty buffer does not send any request."""
        client.flush()

        requests = httpx_mock.get_requests()
        assert len(requests) == 0

    def test_flush_payload_structure(self, client: MetricsClient, httpx_mock):
        """flush() sends correctly structured payload."""
        httpx_mock.add_response(
            status_code=202, json={"status": "accepted", "count": 1}
        )

        client.counter(
            "http_requests_total",
            labels={"method": "GET", "endpoint": "/bookings", "status": "200"},
        )
        client.flush()

        requests = httpx_mock.get_requests()
        body = json.loads(requests[0].read())
        metric = body["metrics"][0]

        assert metric["name"] == "http_requests_total"
        assert metric["type"] == "counter"
        assert metric["value"] == 1
        assert metric["labels"] == {
            "method": "GET",
            "endpoint": "/bookings",
            "status": "200",
        }
        assert "timestamp" in metric

    def test_flush_accepts_200_response(self, client: MetricsClient, httpx_mock):
        """200 response is accepted without error."""
        httpx_mock.add_response(
            status_code=200, json={"status": "accepted", "count": 1}
        )

        client.counter("test")
        client.flush()  # Should not raise

        assert len(client._buffer) == 0

    def test_flush_accepts_202_response(self, client: MetricsClient, httpx_mock):
        """202 response is accepted without error."""
        httpx_mock.add_response(
            status_code=202, json={"status": "accepted", "count": 1}
        )

        client.counter("test")
        client.flush()  # Should not raise

        assert len(client._buffer) == 0


# ---------------------------------------------------------------------------
# Connection failure tests
# ---------------------------------------------------------------------------


class TestConnectionFailures:
    """Tests for graceful error handling during flush."""

    def test_connection_error_does_not_raise(self, client: MetricsClient, httpx_mock):
        """Connection failure is caught, not raised."""
        httpx_mock.add_exception(httpx.ConnectError("Connection refused"))

        client.counter("test")
        client.flush()  # Should not raise

    def test_connection_error_logs_warning(
        self, client: MetricsClient, httpx_mock, caplog
    ):
        """Connection failure is logged at warning level."""
        httpx_mock.add_exception(httpx.ConnectError("Connection refused"))

        client.counter("test")
        with caplog.at_level(logging.WARNING, logger="monlight.metrics_client"):
            client.flush()

        assert any("Failed to flush" in record.message for record in caplog.records)

    def test_timeout_does_not_raise(self, client: MetricsClient, httpx_mock):
        """Timeout is caught, not raised."""
        httpx_mock.add_exception(httpx.ReadTimeout("Read timed out"))

        client.counter("test")
        client.flush()  # Should not raise

    def test_server_error_logs_warning(self, client: MetricsClient, httpx_mock, caplog):
        """Non-200/202 response is logged at warning level."""
        httpx_mock.add_response(status_code=500, text="Internal Server Error")

        client.counter("test")
        with caplog.at_level(logging.WARNING, logger="monlight.metrics_client"):
            client.flush()

        assert any("returned status 500" in record.message for record in caplog.records)

    def test_401_response_logs_warning(self, client: MetricsClient, httpx_mock, caplog):
        """401 response (bad API key) logs warning."""
        httpx_mock.add_response(status_code=401, json={"detail": "Invalid API key"})

        client.counter("test")
        with caplog.at_level(logging.WARNING, logger="monlight.metrics_client"):
            client.flush()

        assert any("returned status 401" in record.message for record in caplog.records)

    def test_metrics_dropped_on_failure(self, client: MetricsClient, httpx_mock):
        """Metrics are dropped (not retried) on flush failure."""
        httpx_mock.add_exception(httpx.ConnectError("Connection refused"))

        client.counter("test")
        client.flush()

        # Buffer should be empty - metrics were dropped
        assert len(client._buffer) == 0

    def test_subsequent_flush_works_after_failure(
        self, client: MetricsClient, httpx_mock
    ):
        """After a failure, subsequent flush works normally."""
        # First flush fails
        httpx_mock.add_exception(httpx.ConnectError("Connection refused"))
        client.counter("failed_metric")
        client.flush()

        # Second flush succeeds
        httpx_mock.add_response(
            status_code=202, json={"status": "accepted", "count": 1}
        )
        client.counter("success_metric")
        client.flush()

        # Should have made 2 requests (one failed, one succeeded)
        requests = httpx_mock.get_requests()
        assert len(requests) == 2


# ---------------------------------------------------------------------------
# Periodic flush timer tests
# ---------------------------------------------------------------------------


class TestPeriodicFlush:
    """Tests for automatic periodic flushing."""

    def test_start_enables_timer(self, client: MetricsClient):
        """start() sets running flag and schedules a timer."""
        client.start()
        try:
            assert client._running is True
            assert client._timer is not None
            assert client._timer.is_alive()
        finally:
            client.shutdown()

    def test_start_is_idempotent(self, client: MetricsClient):
        """Calling start() twice does not create duplicate timers."""
        client.start()
        timer1 = client._timer
        client.start()
        timer2 = client._timer
        try:
            assert timer1 is timer2
        finally:
            client.shutdown()

    def test_timer_is_daemon(self, client: MetricsClient):
        """Timer thread is a daemon (won't prevent process exit)."""
        client.start()
        try:
            assert client._timer.daemon is True
        finally:
            client.shutdown()

    def test_periodic_flush_fires(self, httpx_mock):
        """Timer fires flush after interval."""
        httpx_mock.add_response(
            status_code=202, json={"status": "accepted", "count": 1}
        )

        # Use a very short interval
        client = MetricsClient(
            base_url="http://localhost:5012",
            api_key="key",
            flush_interval=0.1,
        )
        client.counter("test_auto_flush")
        client.start()

        try:
            # Wait for the timer to fire
            time.sleep(0.5)

            requests = httpx_mock.get_requests()
            assert len(requests) >= 1

            body = json.loads(requests[0].read())
            assert body["metrics"][0]["name"] == "test_auto_flush"
        finally:
            client.shutdown()

    def test_default_flush_interval(self):
        """Default flush interval is 10 seconds."""
        client = MetricsClient(base_url="http://localhost:5012", api_key="key")
        assert client.flush_interval == 10.0

    def test_custom_flush_interval(self):
        """Custom flush interval is respected."""
        client = MetricsClient(
            base_url="http://localhost:5012",
            api_key="key",
            flush_interval=30.0,
        )
        assert client.flush_interval == 30.0


# ---------------------------------------------------------------------------
# Shutdown tests
# ---------------------------------------------------------------------------


class TestShutdown:
    """Tests for the shutdown() method."""

    def test_shutdown_stops_timer(self, client: MetricsClient):
        """shutdown() stops the periodic timer."""
        client.start()
        assert client._running is True

        client.shutdown()
        assert client._running is False
        assert client._timer is None

    def test_shutdown_flushes_remaining(self, client: MetricsClient, httpx_mock):
        """shutdown() flushes any buffered metrics."""
        httpx_mock.add_response(
            status_code=202, json={"status": "accepted", "count": 1}
        )

        client.counter("final_metric")
        client.shutdown()

        requests = httpx_mock.get_requests()
        assert len(requests) == 1

        body = json.loads(requests[0].read())
        assert body["metrics"][0]["name"] == "final_metric"

    def test_shutdown_with_empty_buffer(self, client: MetricsClient, httpx_mock):
        """shutdown() with no buffered metrics does not send request."""
        client.shutdown()

        requests = httpx_mock.get_requests()
        assert len(requests) == 0

    def test_shutdown_clears_buffer(self, client: MetricsClient, httpx_mock):
        """Buffer is empty after shutdown flush."""
        httpx_mock.add_response(
            status_code=202, json={"status": "accepted", "count": 1}
        )

        client.counter("test")
        client.shutdown()

        assert len(client._buffer) == 0

    def test_shutdown_without_start(self, client: MetricsClient, httpx_mock):
        """shutdown() works even if start() was never called."""
        httpx_mock.add_response(
            status_code=202, json={"status": "accepted", "count": 1}
        )

        client.counter("test")
        client.shutdown()  # Should not raise

        requests = httpx_mock.get_requests()
        assert len(requests) == 1

    def test_shutdown_is_idempotent(self, client: MetricsClient, httpx_mock):
        """Multiple shutdown() calls don't cause errors."""
        httpx_mock.add_response(
            status_code=202, json={"status": "accepted", "count": 1}
        )

        client.counter("test")
        client.shutdown()
        client.shutdown()  # Should not raise

        # Only one HTTP request should have been sent
        requests = httpx_mock.get_requests()
        assert len(requests) == 1


# ---------------------------------------------------------------------------
# Configuration tests
# ---------------------------------------------------------------------------


class TestConfiguration:
    """Tests for MetricsClient configuration."""

    def test_base_url_trailing_slash_stripped(self):
        """Trailing slash on base_url is stripped."""
        client = MetricsClient(base_url="http://localhost:5012/", api_key="key")
        assert client.base_url == "http://localhost:5012"

    def test_default_timeout(self):
        """Default timeout is 5 seconds."""
        client = MetricsClient(base_url="http://localhost:5012", api_key="key")
        assert client.timeout == 5.0

    def test_custom_timeout(self):
        """Custom timeout is respected."""
        client = MetricsClient(
            base_url="http://localhost:5012", api_key="key", timeout=15.0
        )
        assert client.timeout == 15.0


# ---------------------------------------------------------------------------
# Thread safety tests
# ---------------------------------------------------------------------------


class TestThreadSafety:
    """Tests for thread-safe buffering."""

    def test_concurrent_buffering(self, client: MetricsClient):
        """Multiple threads can buffer metrics concurrently."""
        import threading

        num_threads = 10
        metrics_per_thread = 100

        def buffer_metrics():
            for i in range(metrics_per_thread):
                client.counter(f"thread_metric_{i}")

        threads = [threading.Thread(target=buffer_metrics) for _ in range(num_threads)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert len(client._buffer) == num_threads * metrics_per_thread
