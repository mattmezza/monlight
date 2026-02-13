/**
 * Tests for transport module — batching, beacon fallback, flush behavior
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { Transport } from "./transport";
import type { ResolvedConfig, BrowserError, BrowserMetric } from "./types";

function makeConfig(overrides: Partial<ResolvedConfig> = {}): ResolvedConfig {
  return {
    dsn: "test-dsn-key",
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

function makeError(overrides: Partial<BrowserError> = {}): BrowserError {
  return {
    type: "Error",
    message: "test error",
    stack: "Error: test\n  at test.js:1:1",
    ...overrides,
  };
}

function makeMetric(overrides: Partial<BrowserMetric> = {}): BrowserMetric {
  return {
    name: "test_metric",
    type: "counter",
    value: 1,
    ...overrides,
  };
}

describe("Transport", () => {
  let config: ResolvedConfig;
  let transport: Transport;
  let fetchSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    vi.useFakeTimers();
    config = makeConfig();
    transport = new Transport(config);

    // Mock fetch to return success
    fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response("ok", { status: 200 })
    );
  });

  afterEach(() => {
    transport.destroy();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  describe("sendError", () => {
    it("sends error immediately via fetch (not batched)", () => {
      const error = makeError();
      transport.sendError(error);

      expect(fetchSpy).toHaveBeenCalledTimes(1);
      const [url, options] = fetchSpy.mock.calls[0];
      expect(url).toBe("https://relay.example.com/api/browser/errors");
      expect(options?.method).toBe("POST");
    });

    it("includes X-Monlight-Key header with DSN", () => {
      transport.sendError(makeError());

      const options = fetchSpy.mock.calls[0][1] as RequestInit;
      expect(options.headers).toEqual(
        expect.objectContaining({ "X-Monlight-Key": "test-dsn-key" })
      );
    });

    it("includes Content-Type application/json header", () => {
      transport.sendError(makeError());

      const options = fetchSpy.mock.calls[0][1] as RequestInit;
      expect(options.headers).toEqual(
        expect.objectContaining({ "Content-Type": "application/json" })
      );
    });

    it("sends with keepalive: true", () => {
      transport.sendError(makeError());

      const options = fetchSpy.mock.calls[0][1] as RequestInit;
      expect(options.keepalive).toBe(true);
    });

    it("serializes the error payload as JSON body", () => {
      const error = makeError({ type: "TypeError", message: "oops" });
      transport.sendError(error);

      const options = fetchSpy.mock.calls[0][1] as RequestInit;
      const body = JSON.parse(options.body as string);
      expect(body.type).toBe("TypeError");
      expect(body.message).toBe("oops");
    });

    it("does not send after destroy", () => {
      transport.destroy();
      transport.sendError(makeError());
      // Only the flush from destroy may call fetch, not the sendError
      // Clear calls from destroy's flush
      fetchSpy.mockClear();
      transport.sendError(makeError());
      expect(fetchSpy).not.toHaveBeenCalled();
    });
  });

  describe("bufferMetric", () => {
    it("buffers metrics without sending immediately", () => {
      transport.bufferMetric(makeMetric());
      // No fetch call for a single buffered metric
      expect(fetchSpy).not.toHaveBeenCalled();
    });

    it("flushes when buffer reaches 10 items", () => {
      for (let i = 0; i < 10; i++) {
        transport.bufferMetric(makeMetric({ name: `metric_${i}` }));
      }

      expect(fetchSpy).toHaveBeenCalledTimes(1);
      const [url, options] = fetchSpy.mock.calls[0];
      expect(url).toBe("https://relay.example.com/api/browser/metrics");
      const body = JSON.parse(options?.body as string);
      expect(body.metrics).toHaveLength(10);
    });

    it("does not buffer after destroy", () => {
      transport.destroy();
      fetchSpy.mockClear();
      transport.bufferMetric(makeMetric());
      // Should not be buffered or sent
      transport.flushMetrics();
      expect(fetchSpy).not.toHaveBeenCalled();
    });
  });

  describe("flushMetrics", () => {
    it("sends buffered metrics as a batch", () => {
      transport.bufferMetric(makeMetric({ name: "m1" }));
      transport.bufferMetric(makeMetric({ name: "m2" }));
      transport.bufferMetric(makeMetric({ name: "m3" }));

      transport.flushMetrics();

      expect(fetchSpy).toHaveBeenCalledTimes(1);
      const body = JSON.parse(fetchSpy.mock.calls[0][1]?.body as string);
      expect(body.metrics).toHaveLength(3);
      expect(body.metrics[0].name).toBe("m1");
      expect(body.metrics[2].name).toBe("m3");
    });

    it("does nothing when buffer is empty", () => {
      transport.flushMetrics();
      expect(fetchSpy).not.toHaveBeenCalled();
    });

    it("clears the buffer after flush", () => {
      transport.bufferMetric(makeMetric());
      transport.flushMetrics();
      expect(fetchSpy).toHaveBeenCalledTimes(1);

      // Second flush should do nothing
      transport.flushMetrics();
      expect(fetchSpy).toHaveBeenCalledTimes(1);
    });
  });

  describe("periodic flush", () => {
    it("flushes buffered metrics every 5 seconds", () => {
      transport.start();
      transport.bufferMetric(makeMetric({ name: "periodic" }));

      // Advance 5 seconds
      vi.advanceTimersByTime(5000);

      expect(fetchSpy).toHaveBeenCalledTimes(1);
      const body = JSON.parse(fetchSpy.mock.calls[0][1]?.body as string);
      expect(body.metrics[0].name).toBe("periodic");
    });

    it("flushes multiple times on subsequent intervals", () => {
      transport.start();

      transport.bufferMetric(makeMetric({ name: "batch1" }));
      vi.advanceTimersByTime(5000);
      expect(fetchSpy).toHaveBeenCalledTimes(1);

      transport.bufferMetric(makeMetric({ name: "batch2" }));
      vi.advanceTimersByTime(5000);
      expect(fetchSpy).toHaveBeenCalledTimes(2);
    });

    it("does not flush when buffer is empty on interval", () => {
      transport.start();
      vi.advanceTimersByTime(5000);
      expect(fetchSpy).not.toHaveBeenCalled();
    });
  });

  describe("visibilitychange / pagehide flush", () => {
    it("registers visibilitychange listener on start", () => {
      const addSpy = vi.spyOn(document, "addEventListener");
      transport.start();
      const eventTypes = addSpy.mock.calls.map((c) => c[0]);
      expect(eventTypes).toContain("visibilitychange");
    });

    it("registers pagehide listener on start", () => {
      const addSpy = vi.spyOn(window, "addEventListener");
      transport.start();
      const eventTypes = addSpy.mock.calls.map((c) => c[0]);
      expect(eventTypes).toContain("pagehide");
    });

    it("flushes with sendBeacon on pagehide when sendBeacon is available", () => {
      const sendBeaconSpy = vi.fn().mockReturnValue(true);
      Object.defineProperty(navigator, "sendBeacon", {
        value: sendBeaconSpy,
        writable: true,
        configurable: true,
      });

      transport.start();
      transport.bufferMetric(makeMetric({ name: "beacon_test" }));

      window.dispatchEvent(new Event("pagehide"));

      expect(sendBeaconSpy).toHaveBeenCalledTimes(1);
      const [url] = sendBeaconSpy.mock.calls[0];
      expect(url).toContain("/api/browser/metrics");
      expect(url).toContain("key=test-dsn-key");

      // Clean up
      delete (navigator as any).sendBeacon;
    });

    it("sends Blob with application/json content type via sendBeacon", () => {
      const sendBeaconSpy = vi.fn().mockReturnValue(true);
      Object.defineProperty(navigator, "sendBeacon", {
        value: sendBeaconSpy,
        writable: true,
        configurable: true,
      });

      transport.start();
      transport.bufferMetric(makeMetric());

      window.dispatchEvent(new Event("pagehide"));

      const blob = sendBeaconSpy.mock.calls[0][1] as Blob;
      expect(blob).toBeInstanceOf(Blob);
      expect(blob.type).toBe("application/json");

      delete (navigator as any).sendBeacon;
    });

    it("uses DSN as query parameter for sendBeacon (cannot set headers)", () => {
      const sendBeaconSpy = vi.fn().mockReturnValue(true);
      Object.defineProperty(navigator, "sendBeacon", {
        value: sendBeaconSpy,
        writable: true,
        configurable: true,
      });

      transport.start();
      transport.bufferMetric(makeMetric());

      window.dispatchEvent(new Event("pagehide"));

      const url = sendBeaconSpy.mock.calls[0][0] as string;
      expect(url).toContain("?key=test-dsn-key");

      delete (navigator as any).sendBeacon;
    });
  });

  describe("destroy", () => {
    it("stops the periodic flush timer", () => {
      transport.start();
      transport.destroy();

      transport.bufferMetric(makeMetric());
      // Advance well past the interval — no flush should happen since timer is stopped
      // But bufferMetric won't work after destroy either
      vi.advanceTimersByTime(10000);
      expect(fetchSpy).not.toHaveBeenCalled();
    });

    it("removes event listeners", () => {
      const docRemoveSpy = vi.spyOn(document, "removeEventListener");
      const winRemoveSpy = vi.spyOn(window, "removeEventListener");

      transport.start();
      transport.destroy();

      const docEvents = docRemoveSpy.mock.calls.map((c) => c[0]);
      const winEvents = winRemoveSpy.mock.calls.map((c) => c[0]);
      expect(docEvents).toContain("visibilitychange");
      expect(winEvents).toContain("pagehide");
    });

    it("flushes remaining metrics on destroy", () => {
      transport.bufferMetric(makeMetric({ name: "final_flush" }));
      transport.destroy();

      expect(fetchSpy).toHaveBeenCalledTimes(1);
      const body = JSON.parse(fetchSpy.mock.calls[0][1]?.body as string);
      expect(body.metrics[0].name).toBe("final_flush");
    });
  });

  describe("error handling", () => {
    it("does not throw when fetch rejects (graceful failure)", () => {
      fetchSpy.mockRejectedValue(new Error("network down"));

      expect(() => {
        transport.sendError(makeError());
      }).not.toThrow();
    });

    it("logs warning in debug mode when fetch fails", async () => {
      const debugConfig = makeConfig({ debug: true });
      const debugTransport = new Transport(debugConfig);
      const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      fetchSpy.mockRejectedValue(new Error("network down"));
      debugTransport.sendError(makeError());

      // Allow the promise rejection to be handled
      await vi.advanceTimersByTimeAsync(0);

      expect(warnSpy).toHaveBeenCalledWith(
        expect.stringContaining("[Monlight]"),
        expect.any(Error)
      );

      debugTransport.destroy();
    });
  });
});
