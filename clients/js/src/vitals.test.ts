/**
 * Tests for Web Vitals module — LCP, INP, CLS, FCP, TTFB, page load time
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { VitalsCollector } from "./vitals";
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

// Mock PerformanceObserver since jsdom doesn't support it
type ObserverCallback = (list: { getEntries: () => any[] }) => void;
let observerCallbacks: Map<string, ObserverCallback>;
let mockObserverInstances: Array<{ disconnect: ReturnType<typeof vi.fn> }>;

function setupPerformanceObserverMock() {
  observerCallbacks = new Map();
  mockObserverInstances = [];

  (globalThis as any).PerformanceObserver = class MockPerformanceObserver {
    private callback: ObserverCallback;
    disconnect = vi.fn();

    constructor(callback: ObserverCallback) {
      this.callback = callback;
      mockObserverInstances.push(this);
    }

    observe(options: any) {
      const type = options.type || options.entryTypes?.[0];
      if (type) {
        observerCallbacks.set(type, this.callback);
      }
    }
  };
}

function simulateEntries(type: string, entries: any[]) {
  const callback = observerCallbacks.get(type);
  if (callback) {
    callback({ getEntries: () => entries });
  }
}

describe("VitalsCollector", () => {
  let config: ResolvedConfig;
  let transport: Transport;
  let metricsCollector: MetricsCollector;
  let histogramSpy: ReturnType<typeof vi.spyOn>;
  let vitals: VitalsCollector;

  beforeEach(() => {
    // Ensure sampleRate is 1.0 so sampling always passes
    vi.spyOn(Math, "random").mockReturnValue(0.5);
    setupPerformanceObserverMock();

    config = makeConfig();
    transport = new Transport(config);
    vi.spyOn(transport, "bufferMetric").mockImplementation(() => {});
    metricsCollector = new MetricsCollector(transport);
    histogramSpy = vi.spyOn(metricsCollector, "histogram");

    vitals = new VitalsCollector(config, metricsCollector);
  });

  afterEach(() => {
    vitals.destroy();
    vi.restoreAllMocks();
    delete (globalThis as any).PerformanceObserver;
  });

  describe("sampling", () => {
    it("collects vitals when sample rate is met", () => {
      vi.spyOn(Math, "random").mockReturnValue(0.3);
      const v = new VitalsCollector(makeConfig({ sampleRate: 0.5 }), metricsCollector);
      v.start();
      // Should have registered observers
      expect(observerCallbacks.size).toBeGreaterThan(0);
      v.destroy();
    });

    it("skips collection when sample rate is not met", () => {
      vi.spyOn(Math, "random").mockReturnValue(0.8);
      const v = new VitalsCollector(makeConfig({ sampleRate: 0.5 }), metricsCollector);
      observerCallbacks.clear();
      v.start();
      // No observers should be registered since sampling decided to skip
      expect(observerCallbacks.size).toBe(0);
      v.destroy();
    });

    it("sampleRate 0 skips all collection", () => {
      vi.spyOn(Math, "random").mockReturnValue(0.001);
      const v = new VitalsCollector(makeConfig({ sampleRate: 0 }), metricsCollector);
      observerCallbacks.clear();
      v.start();
      expect(observerCallbacks.size).toBe(0);
      v.destroy();
    });

    it("sampleRate 1 always collects", () => {
      vi.spyOn(Math, "random").mockReturnValue(0.99);
      const v = new VitalsCollector(makeConfig({ sampleRate: 1.0 }), metricsCollector);
      v.start();
      expect(observerCallbacks.size).toBeGreaterThan(0);
      v.destroy();
    });
  });

  describe("LCP (Largest Contentful Paint)", () => {
    it("tracks LCP value from PerformanceObserver", () => {
      vitals.start();
      simulateEntries("largest-contentful-paint", [
        { startTime: 1500 },
        { startTime: 2500 },
      ]);
      // Trigger report via visibilitychange
      Object.defineProperty(document, "visibilityState", {
        value: "hidden",
        writable: true,
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));

      expect(histogramSpy).toHaveBeenCalledWith(
        "web_vitals_lcp",
        2500,
        expect.objectContaining({ page: expect.any(String) })
      );
    });

    it("uses the last LCP entry (the final value)", () => {
      vitals.start();
      // First batch
      simulateEntries("largest-contentful-paint", [{ startTime: 1000 }]);
      // Second batch — browser updates LCP
      simulateEntries("largest-contentful-paint", [{ startTime: 3000 }]);

      Object.defineProperty(document, "visibilityState", {
        value: "hidden",
        writable: true,
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));

      const lcpCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "web_vitals_lcp"
      );
      expect(lcpCall?.[1]).toBe(3000);
    });

    it("does not report LCP if value is 0", () => {
      vitals.start();
      // No LCP entries
      Object.defineProperty(document, "visibilityState", {
        value: "hidden",
        writable: true,
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));

      const lcpCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "web_vitals_lcp"
      );
      expect(lcpCall).toBeUndefined();
    });
  });

  describe("INP (Interaction to Next Paint)", () => {
    it("tracks the highest interaction duration", () => {
      vitals.start();
      simulateEntries("event", [
        { duration: 50 },
        { duration: 200 },
        { duration: 100 },
      ]);

      Object.defineProperty(document, "visibilityState", {
        value: "hidden",
        writable: true,
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));

      const inpCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "web_vitals_inp"
      );
      expect(inpCall?.[1]).toBe(200);
    });

    it("does not report INP if no interactions occurred", () => {
      vitals.start();
      Object.defineProperty(document, "visibilityState", {
        value: "hidden",
        writable: true,
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));

      const inpCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "web_vitals_inp"
      );
      expect(inpCall).toBeUndefined();
    });

    it("updates INP with new higher interactions", () => {
      vitals.start();
      simulateEntries("event", [{ duration: 80 }]);
      simulateEntries("event", [{ duration: 300 }]);

      Object.defineProperty(document, "visibilityState", {
        value: "hidden",
        writable: true,
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));

      const inpCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "web_vitals_inp"
      );
      expect(inpCall?.[1]).toBe(300);
    });
  });

  describe("CLS (Cumulative Layout Shift)", () => {
    it("accumulates layout shift values", () => {
      vitals.start();
      simulateEntries("layout-shift", [
        { startTime: 100, hadRecentInput: false, value: 0.05 },
        { startTime: 200, hadRecentInput: false, value: 0.03 },
      ]);

      Object.defineProperty(document, "visibilityState", {
        value: "hidden",
        writable: true,
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));

      const clsCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "web_vitals_cls"
      );
      expect(clsCall?.[1]).toBeCloseTo(0.08, 4);
    });

    it("ignores layout shifts with recent user input", () => {
      vitals.start();
      simulateEntries("layout-shift", [
        { startTime: 100, hadRecentInput: false, value: 0.05 },
        { startTime: 200, hadRecentInput: true, value: 0.5 },
      ]);

      Object.defineProperty(document, "visibilityState", {
        value: "hidden",
        writable: true,
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));

      const clsCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "web_vitals_cls"
      );
      expect(clsCall?.[1]).toBeCloseTo(0.05, 4);
    });

    it("starts new session window when gap > 1s", () => {
      vitals.start();
      simulateEntries("layout-shift", [
        { startTime: 100, hadRecentInput: false, value: 0.1 },
        { startTime: 200, hadRecentInput: false, value: 0.1 },
      ]);
      // Gap > 1s → new window
      simulateEntries("layout-shift", [
        { startTime: 1500, hadRecentInput: false, value: 0.02 },
      ]);

      Object.defineProperty(document, "visibilityState", {
        value: "hidden",
        writable: true,
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));

      const clsCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "web_vitals_cls"
      );
      // Max window is the first (0.2), not the second (0.02)
      expect(clsCall?.[1]).toBeCloseTo(0.2, 4);
    });

    it("starts new session window when total > 5s", () => {
      vitals.start();
      simulateEntries("layout-shift", [
        { startTime: 100, hadRecentInput: false, value: 0.05 },
        { startTime: 500, hadRecentInput: false, value: 0.05 },
        // Total window duration > 5s (5200 - 100 = 5100)
        { startTime: 5200, hadRecentInput: false, value: 0.01 },
      ]);

      Object.defineProperty(document, "visibilityState", {
        value: "hidden",
        writable: true,
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));

      const clsCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "web_vitals_cls"
      );
      // Max window is the first (0.10), not the third entry alone (0.01)
      expect(clsCall?.[1]).toBeCloseTo(0.1, 4);
    });

    it("reports CLS of 0 when no layout shifts occurred", () => {
      vitals.start();
      Object.defineProperty(document, "visibilityState", {
        value: "hidden",
        writable: true,
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));

      const clsCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "web_vitals_cls"
      );
      expect(clsCall?.[1]).toBe(0);
    });
  });

  describe("FCP (First Contentful Paint)", () => {
    it("reports FCP immediately when observed", () => {
      vitals.start();
      simulateEntries("paint", [
        { name: "first-contentful-paint", startTime: 800 },
      ]);

      expect(histogramSpy).toHaveBeenCalledWith(
        "web_vitals_fcp",
        800,
        expect.objectContaining({ page: expect.any(String) })
      );
    });

    it("ignores non-FCP paint entries", () => {
      vitals.start();
      simulateEntries("paint", [{ name: "first-paint", startTime: 500 }]);

      const fcpCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "web_vitals_fcp"
      );
      expect(fcpCall).toBeUndefined();
    });
  });

  describe("Navigation Timing (TTFB + page load time)", () => {
    it("reports TTFB from responseStart", () => {
      // Mock navigation timing
      vi.spyOn(performance, "getEntriesByType").mockReturnValue([
        {
          entryType: "navigation",
          responseStart: 350,
          loadEventEnd: 1500,
          startTime: 0,
          name: "",
          duration: 0,
          toJSON: () => ({}),
        } as unknown as PerformanceEntry,
      ]);

      // document.readyState is 'complete' in jsdom by default
      Object.defineProperty(document, "readyState", {
        value: "complete",
        writable: true,
        configurable: true,
      });

      vitals.start();

      const ttfbCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "web_vitals_ttfb"
      );
      expect(ttfbCall?.[1]).toBe(350);
    });

    it("reports page load time from loadEventEnd - startTime", () => {
      vi.spyOn(performance, "getEntriesByType").mockReturnValue([
        {
          entryType: "navigation",
          responseStart: 350,
          loadEventEnd: 2000,
          startTime: 100,
          name: "",
          duration: 0,
          toJSON: () => ({}),
        } as unknown as PerformanceEntry,
      ]);

      Object.defineProperty(document, "readyState", {
        value: "complete",
        writable: true,
        configurable: true,
      });

      vitals.start();

      const loadCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "page_load_time"
      );
      expect(loadCall?.[1]).toBe(1900); // 2000 - 100
    });

    it("skips TTFB if responseStart is 0", () => {
      vi.spyOn(performance, "getEntriesByType").mockReturnValue([
        {
          entryType: "navigation",
          responseStart: 0,
          loadEventEnd: 1500,
          startTime: 0,
          name: "",
          duration: 0,
          toJSON: () => ({}),
        } as unknown as PerformanceEntry,
      ]);

      Object.defineProperty(document, "readyState", {
        value: "complete",
        writable: true,
        configurable: true,
      });

      vitals.start();

      const ttfbCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "web_vitals_ttfb"
      );
      expect(ttfbCall).toBeUndefined();
    });

    it("skips page load time if loadEventEnd is 0", () => {
      vi.spyOn(performance, "getEntriesByType").mockReturnValue([
        {
          entryType: "navigation",
          responseStart: 350,
          loadEventEnd: 0,
          startTime: 0,
          name: "",
          duration: 0,
          toJSON: () => ({}),
        } as unknown as PerformanceEntry,
      ]);

      Object.defineProperty(document, "readyState", {
        value: "complete",
        writable: true,
        configurable: true,
      });

      vitals.start();

      const loadCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "page_load_time"
      );
      expect(loadCall).toBeUndefined();
    });
  });

  describe("destroy", () => {
    it("disconnects all PerformanceObservers", () => {
      vitals.start();
      const observerCount = mockObserverInstances.length;
      expect(observerCount).toBeGreaterThan(0);

      vitals.destroy();

      for (const obs of mockObserverInstances) {
        expect(obs.disconnect).toHaveBeenCalled();
      }
    });

    it("removes visibilitychange listener", () => {
      const removeSpy = vi.spyOn(document, "removeEventListener");
      vitals.start();
      vitals.destroy();

      const eventTypes = removeSpy.mock.calls.map((c) => c[0]);
      expect(eventTypes).toContain("visibilitychange");
    });
  });

  describe("reporting on page hide", () => {
    it("reports all vitals when page becomes hidden", () => {
      vitals.start();
      simulateEntries("largest-contentful-paint", [{ startTime: 2000 }]);
      simulateEntries("event", [{ duration: 150 }]);
      simulateEntries("layout-shift", [
        { startTime: 100, hadRecentInput: false, value: 0.05 },
      ]);

      Object.defineProperty(document, "visibilityState", {
        value: "hidden",
        writable: true,
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));

      const metricNames = histogramSpy.mock.calls.map((c) => c[0]);
      expect(metricNames).toContain("web_vitals_lcp");
      expect(metricNames).toContain("web_vitals_inp");
      expect(metricNames).toContain("web_vitals_cls");
    });

    it("does not report when page becomes visible", () => {
      vitals.start();
      simulateEntries("largest-contentful-paint", [{ startTime: 2000 }]);

      // Reset spy call count
      histogramSpy.mockClear();

      Object.defineProperty(document, "visibilityState", {
        value: "visible",
        writable: true,
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));

      // No LCP/INP/CLS should be reported on "visible"
      const vitalCalls = histogramSpy.mock.calls.filter((c) =>
        ["web_vitals_lcp", "web_vitals_inp", "web_vitals_cls"].includes(c[0] as string)
      );
      expect(vitalCalls.length).toBe(0);
    });

    it("includes page path as label", () => {
      vitals.start();
      simulateEntries("layout-shift", [
        { startTime: 100, hadRecentInput: false, value: 0.01 },
      ]);

      Object.defineProperty(document, "visibilityState", {
        value: "hidden",
        writable: true,
        configurable: true,
      });
      document.dispatchEvent(new Event("visibilitychange"));

      const clsCall = histogramSpy.mock.calls.find(
        (c) => c[0] === "web_vitals_cls"
      );
      expect(clsCall?.[2]).toHaveProperty("page");
    });
  });
});
