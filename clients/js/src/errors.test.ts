/**
 * Tests for error capture module — global handlers, deduplication, console capture
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { ErrorCapture } from "./errors";
import { Transport } from "./transport";
import type { ResolvedConfig, BrowserError } from "./types";

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

function makeTransport(config?: ResolvedConfig): Transport {
  return new Transport(config ?? makeConfig());
}

describe("ErrorCapture", () => {
  let config: ResolvedConfig;
  let transport: Transport;
  let sendErrorSpy: ReturnType<typeof vi.spyOn>;
  let capture: ErrorCapture;

  beforeEach(() => {
    config = makeConfig();
    transport = makeTransport(config);
    sendErrorSpy = vi.spyOn(transport, "sendError").mockImplementation(() => {});
    capture = new ErrorCapture(config, transport);
  });

  afterEach(() => {
    capture.destroy();
    vi.restoreAllMocks();
  });

  describe("install / destroy", () => {
    it("adds error and unhandledrejection listeners on install", () => {
      const addSpy = vi.spyOn(window, "addEventListener");
      capture.install();
      const eventTypes = addSpy.mock.calls.map((c) => c[0]);
      expect(eventTypes).toContain("error");
      expect(eventTypes).toContain("unhandledrejection");
    });

    it("removes error and unhandledrejection listeners on destroy", () => {
      capture.install();
      const removeSpy = vi.spyOn(window, "removeEventListener");
      capture.destroy();
      const eventTypes = removeSpy.mock.calls.map((c) => c[0]);
      expect(eventTypes).toContain("error");
      expect(eventTypes).toContain("unhandledrejection");
    });
  });

  describe("captureError (manual)", () => {
    it("sends an error payload via transport", () => {
      capture.install();
      const err = new Error("test error");
      err.name = "TypeError";
      capture.captureError(err);
      expect(sendErrorSpy).toHaveBeenCalledTimes(1);
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.type).toBe("TypeError");
      expect(payload.message).toBe("test error");
      expect(payload.stack).toBeTruthy();
    });

    it("includes session_id in the payload", () => {
      capture.install();
      capture.captureError(new Error("test"));
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.session_id).toBeTruthy();
      expect(payload.session_id!.length).toBe(36); // UUID
    });

    it("includes release from config", () => {
      capture.install();
      capture.captureError(new Error("test"));
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.release).toBe("1.0.0");
    });

    it("includes page URL", () => {
      capture.install();
      capture.captureError(new Error("test"));
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.url).toBeTruthy();
    });

    it("includes user agent", () => {
      capture.install();
      capture.captureError(new Error("test"));
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.user_agent).toBeTruthy();
    });

    it("includes ISO8601 timestamp", () => {
      capture.install();
      capture.captureError(new Error("test"));
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.timestamp).toBeTruthy();
      // ISO8601 format check
      expect(new Date(payload.timestamp!).toISOString()).toBe(
        payload.timestamp
      );
    });

    it("includes environment in context", () => {
      capture.install();
      capture.captureError(new Error("test"));
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.context?.environment).toBe("test");
    });

    it("includes additional context passed to captureError", () => {
      capture.install();
      capture.captureError(new Error("test"), { page: "home", count: 5 });
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.context?.page).toBe("home");
      expect(payload.context?.count).toBe(5);
    });

    it("uses 'Error' as type when error.name is empty", () => {
      capture.install();
      const err = new Error("unnamed");
      err.name = "";
      capture.captureError(err);
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.type).toBe("Error");
    });
  });

  describe("captureMessage", () => {
    it("sends message as ConsoleError type by default", () => {
      capture.install();
      capture.captureMessage("something bad happened");
      expect(sendErrorSpy).toHaveBeenCalledTimes(1);
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.type).toBe("ConsoleError");
      expect(payload.message).toBe("something bad happened");
    });

    it("sends message as ConsoleWarning when level is warning", () => {
      capture.install();
      capture.captureMessage("watch out", "warning");
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.type).toBe("ConsoleWarning");
    });

    it("includes a synthetic stack trace", () => {
      capture.install();
      capture.captureMessage("test msg");
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.stack).toBeTruthy();
      expect(payload.stack.length).toBeGreaterThan(0);
    });
  });

  describe("setUser", () => {
    it("includes user_id in context after setUser", () => {
      capture.install();
      capture.setUser("user-123");
      capture.captureError(new Error("test"));
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.context?.user_id).toBe("user-123");
    });

    it("user_id is absent before setUser", () => {
      capture.install();
      capture.captureError(new Error("test"));
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.context?.user_id).toBeUndefined();
    });
  });

  describe("addContext", () => {
    it("includes added context in subsequent payloads", () => {
      capture.install();
      capture.addContext("tenant", "acme");
      capture.addContext("feature", "checkout");
      capture.captureError(new Error("test"));
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.context?.tenant).toBe("acme");
      expect(payload.context?.feature).toBe("checkout");
    });

    it("per-error context overrides persistent context", () => {
      capture.install();
      capture.addContext("key", "persistent");
      capture.captureError(new Error("test"), { key: "override" });
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.context?.key).toBe("override");
    });
  });

  describe("deduplication", () => {
    it("suppresses duplicate errors within 60s window", () => {
      capture.install();
      const err1 = new Error("dup test");
      err1.name = "DedupType";
      const err2 = new Error("dup test");
      err2.name = "DedupType";

      capture.captureError(err1);
      capture.captureError(err2);
      // First one sends, second is deduplicated
      expect(sendErrorSpy).toHaveBeenCalledTimes(1);
    });

    it("allows different errors through", () => {
      capture.install();
      const err1 = new Error("error A");
      err1.name = "TypeA";
      const err2 = new Error("error B");
      err2.name = "TypeB";

      capture.captureError(err1);
      capture.captureError(err2);
      expect(sendErrorSpy).toHaveBeenCalledTimes(2);
    });

    it("allows same error through after dedup window expires", () => {
      capture.install();
      const err = new Error("timed dup");
      err.name = "TimedType";

      capture.captureError(err);
      expect(sendErrorSpy).toHaveBeenCalledTimes(1);

      // Advance time past the 60s window
      vi.spyOn(Date, "now").mockReturnValue(Date.now() + 61_000);
      const err2 = new Error("timed dup");
      err2.name = "TimedType";
      capture.captureError(err2);
      expect(sendErrorSpy).toHaveBeenCalledTimes(2);
    });

    it("clears dedup cache on destroy", () => {
      capture.install();
      const err = new Error("destroy dup");
      err.name = "DestroyType";
      capture.captureError(err);
      expect(sendErrorSpy).toHaveBeenCalledTimes(1);

      capture.destroy();
      // Re-create and re-install
      capture = new ErrorCapture(config, transport);
      capture.install();

      const err2 = new Error("destroy dup");
      err2.name = "DestroyType";
      capture.captureError(err2);
      expect(sendErrorSpy).toHaveBeenCalledTimes(2);
    });
  });

  describe("beforeSend callback", () => {
    it("calls beforeSend and uses the returned payload", () => {
      const modifiedConfig = makeConfig({
        beforeSend: (event: BrowserError) => ({
          ...event,
          type: "Modified",
        }),
      });
      const t = makeTransport(modifiedConfig);
      const spy = vi.spyOn(t, "sendError").mockImplementation(() => {});
      const c = new ErrorCapture(modifiedConfig, t);
      c.install();

      c.captureError(new Error("test"));
      const payload = spy.mock.calls[0][0] as BrowserError;
      expect(payload.type).toBe("Modified");

      c.destroy();
    });

    it("drops the event when beforeSend returns null", () => {
      const modifiedConfig = makeConfig({
        beforeSend: () => null,
      });
      const t = makeTransport(modifiedConfig);
      const spy = vi.spyOn(t, "sendError").mockImplementation(() => {});
      const c = new ErrorCapture(modifiedConfig, t);
      c.install();

      c.captureError(new Error("should be dropped"));
      expect(spy).not.toHaveBeenCalled();

      c.destroy();
    });
  });

  describe("global error handler (window.onerror)", () => {
    it("captures Error objects from ErrorEvent", () => {
      capture.install();
      const err = new Error("global error");
      err.name = "ReferenceError";
      const event = new ErrorEvent("error", {
        error: err,
        message: "global error",
      });
      window.dispatchEvent(event);

      expect(sendErrorSpy).toHaveBeenCalledTimes(1);
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.type).toBe("ReferenceError");
      expect(payload.message).toBe("global error");
    });

    it("handles non-Error thrown values", () => {
      capture.install();
      const event = new ErrorEvent("error", {
        error: "string thrown",
        message: "string thrown",
      });
      window.dispatchEvent(event);

      expect(sendErrorSpy).toHaveBeenCalledTimes(1);
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.type).toBe("Error");
      expect(payload.message).toBe("string thrown");
    });
  });

  describe("unhandledrejection handler", () => {
    // jsdom does not have PromiseRejectionEvent, so we create a CustomEvent
    // and set the `reason` property to simulate it.
    function createRejectionEvent(reason: unknown): Event {
      const event = new Event("unhandledrejection");
      (event as any).reason = reason;
      return event;
    }

    it("captures Error reasons from unhandledrejection", () => {
      capture.install();
      const err = new Error("rejected promise");
      err.name = "AsyncError";

      window.dispatchEvent(createRejectionEvent(err));

      expect(sendErrorSpy).toHaveBeenCalledTimes(1);
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.type).toBe("AsyncError");
      expect(payload.message).toBe("rejected promise");
    });

    it("handles non-Error rejection reasons", () => {
      capture.install();
      window.dispatchEvent(createRejectionEvent("plain string rejection"));

      expect(sendErrorSpy).toHaveBeenCalledTimes(1);
      const payload = sendErrorSpy.mock.calls[0][0] as BrowserError;
      expect(payload.type).toBe("UnhandledRejection");
      expect(payload.message).toBe("plain string rejection");
    });
  });

  describe("console capture", () => {
    let consoleCapture: ErrorCapture;
    let consoleTransport: Transport;
    let consoleSendSpy: ReturnType<typeof vi.spyOn>;

    beforeEach(() => {
      const cfg = makeConfig({ captureConsole: true });
      consoleTransport = makeTransport(cfg);
      consoleSendSpy = vi
        .spyOn(consoleTransport, "sendError")
        .mockImplementation(() => {});
      consoleCapture = new ErrorCapture(cfg, consoleTransport);
    });

    afterEach(() => {
      consoleCapture.destroy();
    });

    it("patches console.error when captureConsole is true", () => {
      const originalError = console.error;
      consoleCapture.install();
      expect(console.error).not.toBe(originalError);
    });

    it("patches console.warn when captureConsole is true", () => {
      const originalWarn = console.warn;
      consoleCapture.install();
      expect(console.warn).not.toBe(originalWarn);
    });

    it("does not patch console when captureConsole is false", () => {
      const noCaptureConfig = makeConfig({ captureConsole: false });
      const t = makeTransport(noCaptureConfig);
      const c = new ErrorCapture(noCaptureConfig, t);
      const originalError = console.error;
      const originalWarn = console.warn;
      c.install();
      expect(console.error).toBe(originalError);
      expect(console.warn).toBe(originalWarn);
      c.destroy();
    });

    it("calls original console.error when patched", () => {
      const originalError = console.error;
      const origSpy = vi.fn();
      console.error = origSpy;

      consoleCapture.install();
      console.error("test message");

      expect(origSpy).toHaveBeenCalledWith("test message");

      consoleCapture.destroy();
      console.error = originalError;
    });

    it("calls original console.warn when patched", () => {
      const originalWarn = console.warn;
      const origSpy = vi.fn();
      console.warn = origSpy;

      consoleCapture.install();
      console.warn("warn message");

      expect(origSpy).toHaveBeenCalledWith("warn message");

      consoleCapture.destroy();
      console.warn = originalWarn;
    });

    it("sends ConsoleError for console.error calls", () => {
      consoleCapture.install();
      console.error("captured error");

      expect(consoleSendSpy).toHaveBeenCalledTimes(1);
      const payload = consoleSendSpy.mock.calls[0][0] as BrowserError;
      expect(payload.type).toBe("ConsoleError");
      expect(payload.message).toBe("captured error");
    });

    it("sends ConsoleWarning for console.warn calls", () => {
      consoleCapture.install();
      console.warn("captured warning");

      expect(consoleSendSpy).toHaveBeenCalledTimes(1);
      const payload = consoleSendSpy.mock.calls[0][0] as BrowserError;
      expect(payload.type).toBe("ConsoleWarning");
      expect(payload.message).toBe("captured warning");
    });

    it("stringifies multiple console arguments", () => {
      consoleCapture.install();
      console.error("arg1", 42, { key: "val" });

      const payload = consoleSendSpy.mock.calls[0][0] as BrowserError;
      expect(payload.message).toContain("arg1");
      expect(payload.message).toContain("42");
    });

    it("includes synthetic stack trace for console captures", () => {
      consoleCapture.install();
      console.error("stack test");

      const payload = consoleSendSpy.mock.calls[0][0] as BrowserError;
      expect(payload.stack).toBeTruthy();
      expect(payload.stack.length).toBeGreaterThan(0);
    });

    it("restores original console methods on destroy", () => {
      const originalError = console.error;
      const originalWarn = console.warn;

      consoleCapture.install();
      expect(console.error).not.toBe(originalError);
      expect(console.warn).not.toBe(originalWarn);

      consoleCapture.destroy();
      expect(console.error).toBe(originalError);
      expect(console.warn).toBe(originalWarn);
    });
  });
});
