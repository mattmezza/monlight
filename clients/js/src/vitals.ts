/**
 * Web Vitals module — measure Core Web Vitals and additional performance metrics
 */

import type { ResolvedConfig } from "./types";
import { MetricsCollector } from "./metrics";

export class VitalsCollector {
  private metricsCollector: MetricsCollector;
  private observers: PerformanceObserver[] = [];
  private sampled: boolean;

  // CLS tracking
  private clsValue = 0;
  private clsSessionValue = 0;
  private clsSessionEntries: PerformanceEntry[] = [];

  // INP tracking
  private maxINP = 0;

  // LCP tracking
  private lcpValue = 0;

  constructor(config: ResolvedConfig, metricsCollector: MetricsCollector) {
    this.metricsCollector = metricsCollector;
    this.sampled = Math.random() < config.sampleRate;
  }

  /**
   * Start collecting Web Vitals
   */
  start(): void {
    if (!this.sampled) return;
    if (typeof PerformanceObserver === "undefined") return;

    this.observeLCP();
    this.observeINP();
    this.observeCLS();
    this.observeFCP();
    this.measureNavigationTiming();

    // Report vitals on page hide
    if (typeof document !== "undefined") {
      document.addEventListener("visibilitychange", this.onVisibilityChange);
    }
  }

  /**
   * Tear down all observers
   */
  destroy(): void {
    for (const observer of this.observers) {
      observer.disconnect();
    }
    this.observers = [];
    if (typeof document !== "undefined") {
      document.removeEventListener("visibilitychange", this.onVisibilityChange);
    }
  }

  private onVisibilityChange = (): void => {
    if (document.visibilityState === "hidden") {
      this.reportVitals();
    }
  };

  private reportVitals(): void {
    const page =
      typeof window !== "undefined" ? window.location.pathname : "/";
    const labels = { page };

    if (this.lcpValue > 0) {
      this.metricsCollector.histogram("web_vitals_lcp", this.lcpValue, labels);
    }
    if (this.maxINP > 0) {
      this.metricsCollector.histogram("web_vitals_inp", this.maxINP, labels);
    }
    this.metricsCollector.histogram("web_vitals_cls", this.clsValue, labels);
  }

  private observeLCP(): void {
    try {
      const observer = new PerformanceObserver((list) => {
        const entries = list.getEntries();
        const lastEntry = entries[entries.length - 1];
        if (lastEntry) {
          this.lcpValue = lastEntry.startTime;
        }
      });
      observer.observe({ type: "largest-contentful-paint", buffered: true });
      this.observers.push(observer);
    } catch (_e) {
      // Not supported in this browser
    }
  }

  private observeINP(): void {
    try {
      const observer = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          if (entry.duration > this.maxINP) {
            this.maxINP = entry.duration;
          }
        }
      });
      observer.observe({ type: "event", buffered: true, durationThreshold: 40 } as PerformanceObserverInit);
      this.observers.push(observer);
    } catch (_e) {
      // Not supported
    }
  }

  private observeCLS(): void {
    try {
      const observer = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          const layoutShift = entry as PerformanceEntry & {
            hadRecentInput: boolean;
            value: number;
          };
          if (layoutShift.hadRecentInput) continue;

          const lastEntry =
            this.clsSessionEntries[this.clsSessionEntries.length - 1];
          // New session window if gap > 1s or session > 5s
          if (
            lastEntry &&
            (entry.startTime - lastEntry.startTime > 1000 ||
              entry.startTime -
                this.clsSessionEntries[0].startTime >
                5000)
          ) {
            this.clsSessionValue = 0;
            this.clsSessionEntries = [];
          }

          this.clsSessionEntries.push(entry);
          this.clsSessionValue += layoutShift.value;

          if (this.clsSessionValue > this.clsValue) {
            this.clsValue = this.clsSessionValue;
          }
        }
      });
      observer.observe({ type: "layout-shift", buffered: true });
      this.observers.push(observer);
    } catch (_e) {
      // Not supported
    }
  }

  private observeFCP(): void {
    try {
      const observer = new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          if (entry.name === "first-contentful-paint") {
            const page =
              typeof window !== "undefined" ? window.location.pathname : "/";
            this.metricsCollector.histogram("web_vitals_fcp", entry.startTime, {
              page,
            });
          }
        }
      });
      observer.observe({ type: "paint", buffered: true });
      this.observers.push(observer);
    } catch (_e) {
      // Not supported
    }
  }

  private measureNavigationTiming(): void {
    if (typeof window === "undefined") return;
    // Wait for load event to complete
    const measure = () => {
      const nav = performance.getEntriesByType(
        "navigation"
      )[0] as PerformanceNavigationTiming | undefined;
      if (!nav) return;

      const page = window.location.pathname;
      const labels = { page };

      if (nav.responseStart > 0) {
        this.metricsCollector.histogram(
          "web_vitals_ttfb",
          nav.responseStart,
          labels
        );
      }

      if (nav.loadEventEnd > 0) {
        this.metricsCollector.histogram(
          "page_load_time",
          nav.loadEventEnd - nav.startTime,
          labels
        );
      }
    };

    if (document.readyState === "complete") {
      measure();
    } else {
      window.addEventListener("load", () => {
        // Small delay to ensure loadEventEnd is populated
        setTimeout(measure, 0);
      });
    }
  }
}
