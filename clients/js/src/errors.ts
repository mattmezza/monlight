/**
 * Error capture module — global error handlers and manual capture
 */

import type { BrowserError, ResolvedConfig } from "./types";
import { Transport } from "./transport";
import { getSessionId } from "./session";

// Deduplication cache: fingerprint → timestamp
const dedupCache = new Map<string, number>();
const DEDUP_WINDOW_MS = 60_000;
const MAX_DEDUP_ENTRIES = 50;

function errorFingerprint(type: string, message: string, stack: string): string {
  const firstFrame = stack.split("\n").find((line) => line.trim().length > 0) || "";
  return `${type}:${message}:${firstFrame}`;
}

function isDuplicate(fingerprint: string): boolean {
  const now = Date.now();
  const lastSeen = dedupCache.get(fingerprint);
  if (lastSeen && now - lastSeen < DEDUP_WINDOW_MS) {
    return true;
  }
  // Evict old entries
  if (dedupCache.size >= MAX_DEDUP_ENTRIES) {
    const oldest = dedupCache.entries().next().value;
    if (oldest) dedupCache.delete(oldest[0]);
  }
  dedupCache.set(fingerprint, now);
  return false;
}

export class ErrorCapture {
  private config: ResolvedConfig;
  private transport: Transport;
  private userId: string | undefined;
  private extraContext: Record<string, unknown> = {};
  private originalConsoleError: typeof console.error | null = null;
  private originalConsoleWarn: typeof console.warn | null = null;

  constructor(config: ResolvedConfig, transport: Transport) {
    this.config = config;
    this.transport = transport;
  }

  /**
   * Install global error handlers
   */
  install(): void {
    if (typeof window === "undefined") return;

    window.addEventListener("error", this.onError);
    window.addEventListener("unhandledrejection", this.onUnhandledRejection);

    if (this.config.captureConsole) {
      this.patchConsole();
    }
  }

  /**
   * Remove global error handlers
   */
  destroy(): void {
    if (typeof window === "undefined") return;

    window.removeEventListener("error", this.onError);
    window.removeEventListener("unhandledrejection", this.onUnhandledRejection);
    this.restoreConsole();
    dedupCache.clear();
  }

  /**
   * Set user ID for subsequent events
   */
  setUser(userId: string): void {
    this.userId = userId;
  }

  /**
   * Add persistent context
   */
  addContext(key: string, value: unknown): void {
    this.extraContext[key] = value;
  }

  /**
   * Manually capture an error
   */
  captureError(error: Error, context?: Record<string, unknown>): void {
    const payload = this.buildPayload(
      error.name || "Error",
      error.message,
      error.stack || "",
      context
    );
    if (payload) {
      this.transport.sendError(payload);
    }
  }

  /**
   * Capture a message as an error
   */
  captureMessage(message: string, level?: string): void {
    const type = level === "warning" ? "ConsoleWarning" : "ConsoleError";
    const stack = new Error(message).stack || "";
    const payload = this.buildPayload(type, message, stack);
    if (payload) {
      this.transport.sendError(payload);
    }
  }

  private onError = (event: ErrorEvent): void => {
    const error = event.error;
    if (error instanceof Error) {
      const payload = this.buildPayload(
        error.name || "Error",
        error.message,
        error.stack || ""
      );
      if (payload) this.transport.sendError(payload);
    } else {
      // Non-Error thrown values
      const payload = this.buildPayload(
        "Error",
        String(event.message || error),
        ""
      );
      if (payload) this.transport.sendError(payload);
    }
  };

  private onUnhandledRejection = (event: PromiseRejectionEvent): void => {
    const reason = event.reason;
    if (reason instanceof Error) {
      const payload = this.buildPayload(
        reason.name || "UnhandledRejection",
        reason.message,
        reason.stack || ""
      );
      if (payload) this.transport.sendError(payload);
    } else {
      const payload = this.buildPayload(
        "UnhandledRejection",
        String(reason),
        ""
      );
      if (payload) this.transport.sendError(payload);
    }
  };

  private patchConsole(): void {
    if (typeof console === "undefined") return;

    this.originalConsoleError = console.error;
    this.originalConsoleWarn = console.warn;

    console.error = (...args: unknown[]) => {
      if (this.originalConsoleError) {
        this.originalConsoleError.apply(console, args);
      }
      const message = args.map(String).join(" ");
      const stack = new Error(message).stack || "";
      const payload = this.buildPayload("ConsoleError", message, stack);
      if (payload) this.transport.sendError(payload);
    };

    console.warn = (...args: unknown[]) => {
      if (this.originalConsoleWarn) {
        this.originalConsoleWarn.apply(console, args);
      }
      const message = args.map(String).join(" ");
      const stack = new Error(message).stack || "";
      const payload = this.buildPayload("ConsoleWarning", message, stack);
      if (payload) this.transport.sendError(payload);
    };
  }

  private restoreConsole(): void {
    if (this.originalConsoleError) {
      console.error = this.originalConsoleError;
      this.originalConsoleError = null;
    }
    if (this.originalConsoleWarn) {
      console.warn = this.originalConsoleWarn;
      this.originalConsoleWarn = null;
    }
  }

  private buildPayload(
    type: string,
    message: string,
    stack: string,
    context?: Record<string, unknown>
  ): BrowserError | null {
    const fingerprint = errorFingerprint(type, message, stack);
    if (isDuplicate(fingerprint)) return null;

    const payload: BrowserError = {
      type,
      message,
      stack,
      url: typeof window !== "undefined" ? window.location.href : undefined,
      user_agent:
        typeof navigator !== "undefined" ? navigator.userAgent : undefined,
      session_id: getSessionId(),
      context: {
        ...this.extraContext,
        ...context,
        environment: this.config.environment,
        ...(this.userId ? { user_id: this.userId } : {}),
      },
      release: this.config.release,
      timestamp: new Date().toISOString(),
    };

    if (this.config.beforeSend) {
      return this.config.beforeSend(payload);
    }

    return payload;
  }
}
