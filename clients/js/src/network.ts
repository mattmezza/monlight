/**
 * Network monitoring module — intercept fetch and XHR for metrics and error reporting
 */

import type { ResolvedConfig } from "./types";
import { ErrorCapture } from "./errors";
import { MetricsCollector } from "./metrics";

/**
 * Sanitize a URL: strip query params and fragments, collapse ID-like segments
 */
export function sanitizeUrl(url: string): string {
  try {
    const parsed = new URL(url);
    let path = parsed.pathname;
    // Collapse numeric IDs and UUIDs into {id}
    path = path.replace(
      /\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi,
      "/{id}"
    );
    path = path.replace(/\/\d+/g, "/{id}");
    return `${parsed.origin}${path}`;
  } catch {
    return url;
  }
}

function extractHost(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return "unknown";
  }
}

export class NetworkMonitor {
  private config: ResolvedConfig;
  private errorCapture: ErrorCapture;
  private metricsCollector: MetricsCollector;
  private originalFetch: typeof fetch | null = null;
  private originalXHROpen: typeof XMLHttpRequest.prototype.open | null = null;
  private originalXHRSend: typeof XMLHttpRequest.prototype.send | null = null;

  constructor(
    config: ResolvedConfig,
    errorCapture: ErrorCapture,
    metricsCollector: MetricsCollector
  ) {
    this.config = config;
    this.errorCapture = errorCapture;
    this.metricsCollector = metricsCollector;
  }

  /**
   * Install network interception
   */
  install(): void {
    this.patchFetch();
    this.patchXHR();
  }

  /**
   * Restore original network functions
   */
  destroy(): void {
    this.restoreFetch();
    this.restoreXHR();
  }

  private isMonitoringEndpoint(url: string): boolean {
    try {
      return url.startsWith(this.config.endpoint);
    } catch {
      return false;
    }
  }

  private patchFetch(): void {
    if (typeof window === "undefined" || typeof fetch === "undefined") return;

    this.originalFetch = window.fetch;
    const self = this;

    window.fetch = function (
      input: RequestInfo | URL,
      init?: RequestInit
    ): Promise<Response> {
      const url =
        typeof input === "string"
          ? input
          : input instanceof URL
            ? input.toString()
            : input.url;
      const method = init?.method || "GET";

      if (self.isMonitoringEndpoint(url)) {
        return self.originalFetch!.call(window, input, init);
      }

      const startTime = performance.now();

      return self.originalFetch!.call(window, input, init).then(
        (response) => {
          const duration = performance.now() - startTime;
          const status = String(response.status);
          const host = extractHost(url);
          const sanitized = sanitizeUrl(url);

          self.metricsCollector.counter("browser_http_requests_total", {
            method,
            status,
            host,
          });
          self.metricsCollector.histogram(
            "browser_http_request_duration_ms",
            duration,
            { method, status, host }
          );

          if (response.status >= 500) {
            self.errorCapture.captureError(
              new Error(
                `${method} ${sanitized} failed with status ${response.status}`
              ),
              { type: "NetworkError" }
            );
          }

          return response;
        },
        (error: Error) => {
          const duration = performance.now() - startTime;
          const host = extractHost(url);
          const sanitized = sanitizeUrl(url);

          self.metricsCollector.counter("browser_http_requests_total", {
            method,
            status: "0",
            host,
          });
          self.metricsCollector.histogram(
            "browser_http_request_duration_ms",
            duration,
            { method, status: "0", host }
          );

          self.errorCapture.captureError(
            new Error(
              `${method} ${sanitized} network error: ${error.message}`
            ),
            { type: "NetworkError" }
          );

          throw error;
        }
      );
    };
  }

  private restoreFetch(): void {
    if (this.originalFetch && typeof window !== "undefined") {
      window.fetch = this.originalFetch;
      this.originalFetch = null;
    }
  }

  private patchXHR(): void {
    if (typeof XMLHttpRequest === "undefined") return;

    this.originalXHROpen = XMLHttpRequest.prototype.open;
    this.originalXHRSend = XMLHttpRequest.prototype.send;
    const self = this;

    XMLHttpRequest.prototype.open = function (
      method: string,
      url: string | URL,
      ...args: unknown[]
    ) {
      (this as XMLHttpRequest & { _monlight_method: string })._monlight_method =
        method;
      (this as XMLHttpRequest & { _monlight_url: string })._monlight_url =
        String(url);
      return self.originalXHROpen!.apply(this, [method, url, ...args] as Parameters<typeof XMLHttpRequest.prototype.open>);
    };

    XMLHttpRequest.prototype.send = function (body?: Document | XMLHttpRequestBodyInit | null) {
      const xhr = this as XMLHttpRequest & {
        _monlight_method: string;
        _monlight_url: string;
      };
      const url = xhr._monlight_url;
      const method = xhr._monlight_method;

      if (self.isMonitoringEndpoint(url)) {
        return self.originalXHRSend!.call(this, body);
      }

      const startTime = performance.now();

      xhr.addEventListener("loadend", () => {
        const duration = performance.now() - startTime;
        const status = String(xhr.status);
        const host = extractHost(url);
        const sanitized = sanitizeUrl(url);

        self.metricsCollector.counter("browser_http_requests_total", {
          method,
          status,
          host,
        });
        self.metricsCollector.histogram(
          "browser_http_request_duration_ms",
          duration,
          { method, status, host }
        );

        if (xhr.status >= 500 || xhr.status === 0) {
          self.errorCapture.captureError(
            new Error(
              xhr.status === 0
                ? `${method} ${sanitized} network error`
                : `${method} ${sanitized} failed with status ${xhr.status}`
            ),
            { type: "NetworkError" }
          );
        }
      });

      return self.originalXHRSend!.call(this, body);
    };
  }

  private restoreXHR(): void {
    if (typeof XMLHttpRequest === "undefined") return;
    if (this.originalXHROpen) {
      XMLHttpRequest.prototype.open = this.originalXHROpen;
      this.originalXHROpen = null;
    }
    if (this.originalXHRSend) {
      XMLHttpRequest.prototype.send = this.originalXHRSend;
      this.originalXHRSend = null;
    }
  }
}
