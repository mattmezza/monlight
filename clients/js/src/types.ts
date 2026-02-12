/**
 * Type definitions for @monlight/browser SDK
 */

/** Configuration options for the Monlight SDK */
export interface MonlightConfig {
  /** Public key for authentication (DSN) */
  dsn: string;
  /** Browser Relay URL */
  endpoint: string;
  /** App version for source map matching */
  release?: string;
  /** Environment name (default: "prod") */
  environment?: string;
  /** Sampling rate for performance data (0.0-1.0, default: 1.0) */
  sampleRate?: number;
  /** Enable console debug logging (default: false) */
  debug?: boolean;
  /** Transform or drop events before sending; return null to drop */
  beforeSend?: (event: BrowserError) => BrowserError | null;
  /** Master kill switch (default: true) */
  enabled?: boolean;
  /** Capture console.error and console.warn (default: false) */
  captureConsole?: boolean;
}

/** Public client API */
export interface MonlightClient {
  /** Manually report an error */
  captureError(error: Error, context?: Record<string, unknown>): void;
  /** Report a message as an error */
  captureMessage(message: string, level?: string): void;
  /** Associate a user ID with subsequent events */
  setUser(userId: string): void;
  /** Add persistent context to all events */
  addContext(key: string, value: unknown): void;
  /** Tear down all listeners and flush pending data */
  destroy(): void;
}

/** Browser error payload sent to the relay */
export interface BrowserError {
  /** Error type (e.g. "TypeError", "Error") */
  type: string;
  /** Error message */
  message: string;
  /** Stack trace string */
  stack: string;
  /** Page URL where the error occurred */
  url?: string;
  /** Browser user agent */
  user_agent?: string;
  /** Anonymous session ID */
  session_id?: string;
  /** Additional context metadata */
  context?: Record<string, unknown>;
  /** App version for source map matching */
  release?: string;
  /** ISO8601 timestamp */
  timestamp?: string;
}

/** A single metric data point */
export interface BrowserMetric {
  /** Metric name */
  name: string;
  /** Metric type */
  type: "counter" | "histogram" | "gauge";
  /** Metric value */
  value: number;
  /** Optional labels */
  labels?: Record<string, string>;
  /** ISO8601 timestamp */
  timestamp?: string;
}

/** Metrics payload sent to the relay */
export interface BrowserMetricsPayload {
  /** Array of metric data points */
  metrics: BrowserMetric[];
  /** Anonymous session ID */
  session_id?: string;
  /** Current page URL */
  url?: string;
}

/** Internal resolved configuration with defaults applied */
export interface ResolvedConfig {
  dsn: string;
  endpoint: string;
  release: string | undefined;
  environment: string;
  sampleRate: number;
  debug: boolean;
  beforeSend: ((event: BrowserError) => BrowserError | null) | undefined;
  enabled: boolean;
  captureConsole: boolean;
}
