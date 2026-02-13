/**
 * Tests for network monitoring module — fetch/XHR interception, URL sanitization
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { NetworkMonitor, sanitizeUrl } from "./network";
import { ErrorCapture } from "./errors";
import { MetricsCollector } from "./metrics";
import { Transport } from "./transport";
import type { ResolvedConfig } from "./types";

function makeConfig(overrides: Partial<ResolvedConfig> = {}): ResolvedConfig {
  return {
    dsn: "test-dsn",
    endpoint: "https://relay.example.com",
    release: "1.0.0",
    environment: "test",
    sampleRate: 1.0,
    debug: false,
    beforeSend: undefined,
    enabled: true,
    captureConsole: false,
    ...overrides,
  };
}

describe("sanitizeUrl", () => {
  it("strips query parameters", () => {
    expect(sanitizeUrl("https://api.example.com/users?page=1&limit=10")).toBe(
      "https://api.example.com/users"
    );
  });

  it("strips URL fragments", () => {
    expect(sanitizeUrl("https://example.com/page#section")).toBe(
      "https://example.com/page"
    );
  });

  it("collapses numeric IDs into {id}", () => {
    expect(sanitizeUrl("https://api.example.com/api/users/123/profile")).toBe(
      "https://api.example.com/api/users/{id}/profile"
    );
  });

  it("collapses UUID-like segments into {id}", () => {
    expect(
      sanitizeUrl(
        "https://api.example.com/api/orders/550e8400-e29b-41d4-a716-446655440000/items"
      )
    ).toBe("https://api.example.com/api/orders/{id}/items");
  });

  it("collapses multiple ID segments", () => {
    expect(sanitizeUrl("https://api.example.com/users/42/posts/99")).toBe(
      "https://api.example.com/users/{id}/posts/{id}"
    );
  });

  it("preserves non-ID path segments", () => {
    expect(sanitizeUrl("https://api.example.com/api/users/list")).toBe(
      "https://api.example.com/api/users/list"
    );
  });

  it("handles root path", () => {
    expect(sanitizeUrl("https://example.com/")).toBe("https://example.com/");
  });

  it("returns original string for invalid URLs", () => {
    expect(sanitizeUrl("not-a-url")).toBe("not-a-url");
  });
});

describe("NetworkMonitor", () => {
  let config: ResolvedConfig;
  let transport: Transport;
  let errorCapture: ErrorCapture;
  let metricsCollector: MetricsCollector;
  let counterSpy: ReturnType<typeof vi.spyOn>;
  let histogramSpy: ReturnType<typeof vi.spyOn>;
  let captureErrorSpy: ReturnType<typeof vi.spyOn>;
  let monitor: NetworkMonitor;
  let originalFetch: typeof fetch;

  beforeEach(() => {
    config = makeConfig();
    transport = new Transport(config);
    vi.spyOn(transport, "bufferMetric").mockImplementation(() => {});
    vi.spyOn(transport, "sendError").mockImplementation(() => {});
    errorCapture = new ErrorCapture(config, transport);
    metricsCollector = new MetricsCollector(transport);

    counterSpy = vi.spyOn(metricsCollector, "counter");
    histogramSpy = vi.spyOn(metricsCollector, "histogram");
    captureErrorSpy = vi.spyOn(errorCapture, "captureError");

    monitor = new NetworkMonitor(config, errorCapture, metricsCollector);
    originalFetch = window.fetch;
  });

  afterEach(() => {
    monitor.destroy();
    // Ensure fetch is restored even if destroy fails
    window.fetch = originalFetch;
    vi.restoreAllMocks();
  });

  describe("fetch interception", () => {
    it("patches window.fetch on install", () => {
      monitor.install();
      expect(window.fetch).not.toBe(originalFetch);
    });

    it("restores window.fetch on destroy", () => {
      monitor.install();
      monitor.destroy();
      expect(window.fetch).toBe(originalFetch);
    });

    it("records counter metric for successful fetch", async () => {
      // Mock the original fetch to return a success response
      const mockResponse = new Response("ok", { status: 200 });
      window.fetch = vi.fn().mockResolvedValue(mockResponse);
      const savedFetch = window.fetch;

      monitor = new NetworkMonitor(config, errorCapture, metricsCollector);
      monitor.install();

      await window.fetch("https://api.example.com/data");

      expect(counterSpy).toHaveBeenCalledWith(
        "browser_http_requests_total",
        expect.objectContaining({
          method: "GET",
          status: "200",
          host: "api.example.com",
        })
      );
    });

    it("records histogram metric for successful fetch", async () => {
      const mockResponse = new Response("ok", { status: 200 });
      window.fetch = vi.fn().mockResolvedValue(mockResponse);

      monitor = new NetworkMonitor(config, errorCapture, metricsCollector);
      monitor.install();

      await window.fetch("https://api.example.com/data");

      expect(histogramSpy).toHaveBeenCalledWith(
        "browser_http_request_duration_ms",
        expect.any(Number),
        expect.objectContaining({
          method: "GET",
          status: "200",
          host: "api.example.com",
        })
      );
    });

    it("uses the correct HTTP method from init", async () => {
      const mockResponse = new Response("created", { status: 201 });
      window.fetch = vi.fn().mockResolvedValue(mockResponse);

      monitor = new NetworkMonitor(config, errorCapture, metricsCollector);
      monitor.install();

      await window.fetch("https://api.example.com/data", { method: "POST" });

      expect(counterSpy).toHaveBeenCalledWith(
        "browser_http_requests_total",
        expect.objectContaining({ method: "POST", status: "201" })
      );
    });

    it("reports 500+ responses as NetworkError", async () => {
      const mockResponse = new Response("error", { status: 500 });
      window.fetch = vi.fn().mockResolvedValue(mockResponse);

      monitor = new NetworkMonitor(config, errorCapture, metricsCollector);
      monitor.install();

      await window.fetch("https://api.example.com/data");

      expect(captureErrorSpy).toHaveBeenCalledTimes(1);
      const errArg = captureErrorSpy.mock.calls[0][0] as Error;
      expect(errArg.message).toContain("failed with status 500");
    });

    it("does not report 4xx responses as errors", async () => {
      const mockResponse = new Response("not found", { status: 404 });
      window.fetch = vi.fn().mockResolvedValue(mockResponse);

      monitor = new NetworkMonitor(config, errorCapture, metricsCollector);
      monitor.install();

      await window.fetch("https://api.example.com/data");

      expect(captureErrorSpy).not.toHaveBeenCalled();
    });

    it("reports network errors (fetch rejection)", async () => {
      window.fetch = vi
        .fn()
        .mockRejectedValue(new TypeError("Failed to fetch"));

      monitor = new NetworkMonitor(config, errorCapture, metricsCollector);
      monitor.install();

      try {
        await window.fetch("https://api.example.com/data");
      } catch {
        // Expected to throw
      }

      expect(captureErrorSpy).toHaveBeenCalledTimes(1);
      const errArg = captureErrorSpy.mock.calls[0][0] as Error;
      expect(errArg.message).toContain("network error");
      expect(errArg.message).toContain("Failed to fetch");
    });

    it("records metrics with status 0 for network errors", async () => {
      window.fetch = vi
        .fn()
        .mockRejectedValue(new TypeError("Failed to fetch"));

      monitor = new NetworkMonitor(config, errorCapture, metricsCollector);
      monitor.install();

      try {
        await window.fetch("https://api.example.com/data");
      } catch {
        // Expected
      }

      expect(counterSpy).toHaveBeenCalledWith(
        "browser_http_requests_total",
        expect.objectContaining({ status: "0" })
      );
    });

    it("re-throws the original error on fetch failure", async () => {
      const originalError = new TypeError("Failed to fetch");
      window.fetch = vi.fn().mockRejectedValue(originalError);

      monitor = new NetworkMonitor(config, errorCapture, metricsCollector);
      monitor.install();

      await expect(
        window.fetch("https://api.example.com/data")
      ).rejects.toThrow("Failed to fetch");
    });

    it("excludes monitoring endpoint from interception", async () => {
      const mockResponse = new Response("ok", { status: 200 });
      window.fetch = vi.fn().mockResolvedValue(mockResponse);

      monitor = new NetworkMonitor(config, errorCapture, metricsCollector);
      monitor.install();

      await window.fetch(
        "https://relay.example.com/api/browser/errors"
      );

      // No metrics should be recorded for the monitoring endpoint
      expect(counterSpy).not.toHaveBeenCalled();
      expect(histogramSpy).not.toHaveBeenCalled();
    });

    it("returns the original response object", async () => {
      const mockResponse = new Response("test body", {
        status: 200,
        headers: { "X-Custom": "value" },
      });
      window.fetch = vi.fn().mockResolvedValue(mockResponse);

      monitor = new NetworkMonitor(config, errorCapture, metricsCollector);
      monitor.install();

      const response = await window.fetch("https://api.example.com/data");
      expect(response).toBe(mockResponse);
      expect(response.status).toBe(200);
    });
  });

  describe("XHR interception", () => {
    it("patches XMLHttpRequest.prototype.open and send on install", () => {
      const originalOpen = XMLHttpRequest.prototype.open;
      const originalSend = XMLHttpRequest.prototype.send;
      monitor.install();
      expect(XMLHttpRequest.prototype.open).not.toBe(originalOpen);
      expect(XMLHttpRequest.prototype.send).not.toBe(originalSend);
    });

    it("restores XMLHttpRequest prototype on destroy", () => {
      const originalOpen = XMLHttpRequest.prototype.open;
      const originalSend = XMLHttpRequest.prototype.send;
      monitor.install();
      monitor.destroy();
      expect(XMLHttpRequest.prototype.open).toBe(originalOpen);
      expect(XMLHttpRequest.prototype.send).toBe(originalSend);
    });
  });
});
