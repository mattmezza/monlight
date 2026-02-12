/**
 * Transport module — batched beacon transport for sending data to the relay
 */

import type { BrowserError, BrowserMetric, ResolvedConfig } from "./types";

export class Transport {
  private config: ResolvedConfig;
  private metricsBuffer: BrowserMetric[] = [];
  private flushTimer: ReturnType<typeof setInterval> | null = null;
  private destroyed = false;

  constructor(config: ResolvedConfig) {
    this.config = config;
  }

  /**
   * Start the periodic flush timer
   */
  start(): void {
    if (this.flushTimer) return;
    this.flushTimer = setInterval(() => this.flushMetrics(), 5000);

    // Flush on page hide (reliable with sendBeacon)
    if (typeof document !== "undefined") {
      document.addEventListener("visibilitychange", this.onVisibilityChange);
    }
    if (typeof window !== "undefined") {
      window.addEventListener("pagehide", this.onPageHide);
    }
  }

  /**
   * Send an error immediately (not batched)
   */
  sendError(error: BrowserError): void {
    if (this.destroyed) return;
    const url = `${this.config.endpoint}/api/browser/errors`;
    const body = JSON.stringify(error);
    this.send(url, body);
  }

  /**
   * Buffer a metric for batched sending
   */
  bufferMetric(metric: BrowserMetric): void {
    if (this.destroyed) return;
    this.metricsBuffer.push(metric);
    if (this.metricsBuffer.length >= 10) {
      this.flushMetrics();
    }
  }

  /**
   * Flush buffered metrics
   */
  flushMetrics(): void {
    if (this.metricsBuffer.length === 0) return;
    const metrics = this.metricsBuffer;
    this.metricsBuffer = [];

    const url = `${this.config.endpoint}/api/browser/metrics`;
    const body = JSON.stringify({ metrics });
    this.send(url, body);
  }

  /**
   * Flush all pending data
   */
  flush(): void {
    this.flushMetrics();
  }

  /**
   * Tear down transport
   */
  destroy(): void {
    this.destroyed = true;
    if (this.flushTimer) {
      clearInterval(this.flushTimer);
      this.flushTimer = null;
    }
    if (typeof document !== "undefined") {
      document.removeEventListener("visibilitychange", this.onVisibilityChange);
    }
    if (typeof window !== "undefined") {
      window.removeEventListener("pagehide", this.onPageHide);
    }
    this.flush();
  }

  private onVisibilityChange = (): void => {
    if (document.visibilityState === "hidden") {
      this.flushWithBeacon();
    }
  };

  private onPageHide = (): void => {
    this.flushWithBeacon();
  };

  /**
   * Flush using sendBeacon (reliable on page unload)
   */
  private flushWithBeacon(): void {
    if (this.metricsBuffer.length === 0) return;
    const metrics = this.metricsBuffer;
    this.metricsBuffer = [];

    const url = `${this.config.endpoint}/api/browser/metrics?key=${encodeURIComponent(this.config.dsn)}`;
    const body = JSON.stringify({ metrics });

    if (typeof navigator !== "undefined" && navigator.sendBeacon) {
      const blob = new Blob([body], { type: "application/json" });
      navigator.sendBeacon(url, blob);
    } else {
      this.send(`${this.config.endpoint}/api/browser/metrics`, body);
    }
  }

  /**
   * Send data via fetch (with keepalive) or XHR fallback
   */
  private send(url: string, body: string): void {
    try {
      if (typeof fetch !== "undefined") {
        fetch(url, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Monlight-Key": this.config.dsn,
          },
          body,
          keepalive: true,
        }).catch((err) => {
          if (this.config.debug) {
            console.warn("[Monlight] Transport error:", err);
          }
        });
      } else if (typeof XMLHttpRequest !== "undefined") {
        const xhr = new XMLHttpRequest();
        xhr.open("POST", url, true);
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.setRequestHeader("X-Monlight-Key", this.config.dsn);
        xhr.send(body);
      }
    } catch (err) {
      if (this.config.debug) {
        console.warn("[Monlight] Transport error:", err);
      }
    }
  }
}
