/**
 * Metrics module — convenience functions for emitting metrics
 */

import type { BrowserMetric } from "./types";
import { Transport } from "./transport";
import { getSessionId } from "./session";

export class MetricsCollector {
  private transport: Transport;

  constructor(transport: Transport) {
    this.transport = transport;
  }

  /**
   * Emit a counter metric
   */
  counter(
    name: string,
    labels?: Record<string, string>,
    value = 1
  ): void {
    this.emit(name, "counter", value, labels);
  }

  /**
   * Emit a histogram metric
   */
  histogram(
    name: string,
    value: number,
    labels?: Record<string, string>
  ): void {
    this.emit(name, "histogram", value, labels);
  }

  /**
   * Emit a gauge metric
   */
  gauge(
    name: string,
    value: number,
    labels?: Record<string, string>
  ): void {
    this.emit(name, "gauge", value, labels);
  }

  private emit(
    name: string,
    type: BrowserMetric["type"],
    value: number,
    labels?: Record<string, string>
  ): void {
    const metric: BrowserMetric = {
      name,
      type,
      value,
      labels: {
        ...labels,
        session_id: getSessionId(),
        page: typeof window !== "undefined" ? window.location.pathname : "/",
      },
      timestamp: new Date().toISOString(),
    };
    this.transport.bufferMetric(metric);
  }
}
