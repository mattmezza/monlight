/**
 * Core module — SDK initialization and MonlightClient implementation
 */

import type { MonlightConfig, MonlightClient, ResolvedConfig } from "./types";
import { Transport } from "./transport";
import { ErrorCapture } from "./errors";
import { MetricsCollector } from "./metrics";
import { VitalsCollector } from "./vitals";
import { NetworkMonitor } from "./network";

export type { MonlightConfig, MonlightClient, ResolvedConfig };
export type { BrowserError, BrowserMetric } from "./types";

function resolveConfig(config: MonlightConfig): ResolvedConfig {
  if (!config.dsn) {
    throw new Error("[Monlight] 'dsn' is required");
  }
  if (!config.endpoint) {
    throw new Error("[Monlight] 'endpoint' is required");
  }

  return {
    dsn: config.dsn,
    endpoint: config.endpoint.replace(/\/+$/, ""), // strip trailing slashes
    release: config.release,
    environment: config.environment ?? "prod",
    sampleRate: config.sampleRate ?? 1.0,
    debug: config.debug ?? false,
    beforeSend: config.beforeSend,
    enabled: config.enabled ?? true,
    captureConsole: config.captureConsole ?? false,
  };
}

class MonlightClientImpl implements MonlightClient {
  private transport: Transport;
  private errorCapture: ErrorCapture;
  private metricsCollector: MetricsCollector;
  private vitalsCollector: VitalsCollector;
  private networkMonitor: NetworkMonitor;

  constructor(resolved: ResolvedConfig) {
    this.transport = new Transport(resolved);
    this.errorCapture = new ErrorCapture(resolved, this.transport);
    this.metricsCollector = new MetricsCollector(this.transport);
    this.vitalsCollector = new VitalsCollector(resolved, this.metricsCollector);
    this.networkMonitor = new NetworkMonitor(
      resolved,
      this.errorCapture,
      this.metricsCollector
    );

    // Install interceptors
    this.transport.start();
    this.errorCapture.install();
    this.networkMonitor.install();
    this.vitalsCollector.start();
  }

  captureError(error: Error, context?: Record<string, unknown>): void {
    this.errorCapture.captureError(error, context);
  }

  captureMessage(message: string, level?: string): void {
    this.errorCapture.captureMessage(message, level);
  }

  setUser(userId: string): void {
    this.errorCapture.setUser(userId);
  }

  addContext(key: string, value: unknown): void {
    this.errorCapture.addContext(key, value);
  }

  destroy(): void {
    this.vitalsCollector.destroy();
    this.networkMonitor.destroy();
    this.errorCapture.destroy();
    this.transport.destroy();
  }
}

/**
 * Initialize the Monlight SDK
 */
export function init(config: MonlightConfig): MonlightClient {
  const resolved = resolveConfig(config);

  if (!resolved.enabled) {
    // Return a no-op client
    return {
      captureError: () => {},
      captureMessage: () => {},
      setUser: () => {},
      addContext: () => {},
      destroy: () => {},
    };
  }

  return new MonlightClientImpl(resolved);
}

// UMD auto-initialization from window.MonlightConfig
declare global {
  interface Window {
    MonlightConfig?: MonlightConfig;
    Monlight?: MonlightClient;
  }
}

if (typeof window !== "undefined" && window.MonlightConfig) {
  try {
    window.Monlight = init(window.MonlightConfig);
  } catch (e) {
    console.error("[Monlight] Auto-init failed:", e);
  }
}
