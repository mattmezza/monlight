"""Metrics collection client for MonlightStack Metrics Collector service."""

from __future__ import annotations

import logging
import threading
from datetime import datetime, timezone
from typing import Any

import httpx

logger = logging.getLogger(__name__)


class MetricsClient:
    """Client for sending metrics to MonlightStack Metrics Collector.

    Buffers metrics in memory and periodically flushes them as a batch
    POST to the Metrics Collector service.

    Args:
        base_url: Base URL of the Metrics Collector service (e.g., "http://metrics-collector:8000").
        api_key: API key for authentication.
        flush_interval: Seconds between automatic flushes. Defaults to 10.
        timeout: HTTP request timeout in seconds. Defaults to 5.
    """

    def __init__(
        self,
        base_url: str,
        api_key: str,
        flush_interval: float = 10.0,
        timeout: float = 5.0,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.flush_interval = flush_interval
        self.timeout = timeout

        self._buffer: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._timer: threading.Timer | None = None
        self._running = False

    def start(self) -> None:
        """Start the periodic flush timer."""
        if self._running:
            return
        self._running = True
        self._schedule_flush()

    def _schedule_flush(self) -> None:
        """Schedule the next flush."""
        if not self._running:
            return
        self._timer = threading.Timer(self.flush_interval, self._flush_and_reschedule)
        self._timer.daemon = True
        self._timer.start()

    def _flush_and_reschedule(self) -> None:
        """Flush buffered metrics and reschedule."""
        self.flush()
        self._schedule_flush()

    def counter(
        self, name: str, labels: dict[str, str] | None = None, value: float = 1
    ) -> None:
        """Record a counter metric (cumulative count, only increases).

        Args:
            name: Metric name (e.g., "http_requests_total").
            labels: Optional dict of label key-value pairs.
            value: Counter increment value. Defaults to 1.
        """
        self._buffer_metric(name, "counter", value, labels)

    def histogram(
        self, name: str, value: float, labels: dict[str, str] | None = None
    ) -> None:
        """Record a histogram metric (distribution of values).

        Args:
            name: Metric name (e.g., "http_request_duration_seconds").
            value: Observed value.
            labels: Optional dict of label key-value pairs.
        """
        self._buffer_metric(name, "histogram", value, labels)

    def gauge(
        self, name: str, value: float, labels: dict[str, str] | None = None
    ) -> None:
        """Record a gauge metric (point-in-time value, can go up/down).

        Args:
            name: Metric name (e.g., "active_rentals").
            value: Current gauge value.
            labels: Optional dict of label key-value pairs.
        """
        self._buffer_metric(name, "gauge", value, labels)

    def _buffer_metric(
        self,
        name: str,
        metric_type: str,
        value: float,
        labels: dict[str, str] | None,
    ) -> None:
        """Add a metric to the in-memory buffer."""
        metric: dict[str, Any] = {
            "name": name,
            "type": metric_type,
            "value": value,
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        if labels:
            metric["labels"] = labels

        with self._lock:
            self._buffer.append(metric)

    def flush(self) -> None:
        """Send all buffered metrics to the Metrics Collector service.

        Metrics are sent in a single batch POST request. On success, the
        buffer is cleared. On failure, metrics are dropped and a warning
        is logged.
        """
        with self._lock:
            if not self._buffer:
                return
            metrics_to_send = self._buffer.copy()
            self._buffer.clear()

        payload = {"metrics": metrics_to_send}
        try:
            with httpx.Client(timeout=self.timeout) as client:
                response = client.post(
                    f"{self.base_url}/api/metrics",
                    json=payload,
                    headers={"X-API-Key": self.api_key},
                )
                if response.status_code not in (200, 202):
                    logger.warning(
                        "Metrics collector returned status %d: %s",
                        response.status_code,
                        response.text[:200],
                    )
        except Exception:
            logger.warning(
                "Failed to flush %d metrics to collector",
                len(metrics_to_send),
                exc_info=True,
            )

    def shutdown(self) -> None:
        """Stop the periodic flush timer and flush remaining metrics.

        Should be called during application shutdown to ensure all
        buffered metrics are sent.
        """
        self._running = False
        if self._timer is not None:
            self._timer.cancel()
            self._timer = None
        self.flush()
