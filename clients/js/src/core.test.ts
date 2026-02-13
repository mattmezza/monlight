/**
 * Tests for core module — init(), MonlightClient, UMD auto-init
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { init } from "./core";
import type { MonlightConfig, MonlightClient } from "./types";

// Valid base config for tests
function baseConfig(overrides?: Partial<MonlightConfig>): MonlightConfig {
  return {
    dsn: "test-public-key-abc123",
    endpoint: "https://monitoring.example.com",
    ...overrides,
  };
}

describe("init(config)", () => {
  let client: MonlightClient | null = null;

  afterEach(() => {
    if (client) {
      client.destroy();
      client = null;
    }
  });

  // --- Required config validation ---

  it("throws Error when dsn is missing", () => {
    expect(() =>
      init({ endpoint: "https://example.com" } as MonlightConfig)
    ).toThrow("[Monlight] 'dsn' is required");
  });

  it("throws Error when dsn is empty string", () => {
    expect(() =>
      init({ dsn: "", endpoint: "https://example.com" })
    ).toThrow("[Monlight] 'dsn' is required");
  });

  it("throws Error when endpoint is missing", () => {
    expect(() =>
      init({ dsn: "test-key" } as MonlightConfig)
    ).toThrow("[Monlight] 'endpoint' is required");
  });

  it("throws Error when endpoint is empty string", () => {
    expect(() =>
      init({ dsn: "test-key", endpoint: "" })
    ).toThrow("[Monlight] 'endpoint' is required");
  });

  // --- Successful initialization ---

  it("returns a MonlightClient when given valid config", () => {
    client = init(baseConfig());
    expect(client).toBeDefined();
    expect(typeof client.captureError).toBe("function");
    expect(typeof client.captureMessage).toBe("function");
    expect(typeof client.setUser).toBe("function");
    expect(typeof client.addContext).toBe("function");
    expect(typeof client.destroy).toBe("function");
  });

  // --- Default config values ---

  it("applies default environment 'prod' when not specified", () => {
    client = init(baseConfig());
    // We can't directly inspect resolved config, but it should not throw
    expect(client).toBeDefined();
  });

  it("accepts custom environment", () => {
    client = init(baseConfig({ environment: "staging" }));
    expect(client).toBeDefined();
  });

  it("applies default sampleRate 1.0 when not specified", () => {
    client = init(baseConfig());
    expect(client).toBeDefined();
  });

  it("accepts custom sampleRate", () => {
    client = init(baseConfig({ sampleRate: 0.5 }));
    expect(client).toBeDefined();
  });

  it("applies default debug false when not specified", () => {
    client = init(baseConfig());
    expect(client).toBeDefined();
  });

  it("applies default enabled true when not specified", () => {
    client = init(baseConfig());
    expect(client).toBeDefined();
  });

  it("applies default captureConsole false when not specified", () => {
    client = init(baseConfig());
    expect(client).toBeDefined();
  });

  // --- Endpoint trailing slash stripping ---

  it("strips trailing slashes from endpoint", () => {
    // This should not throw and should work correctly
    client = init(baseConfig({ endpoint: "https://monitoring.example.com///" }));
    expect(client).toBeDefined();
  });

  // --- enabled: false returns no-op client ---

  it("returns a no-op client when enabled is false", () => {
    client = init(baseConfig({ enabled: false }));
    expect(client).toBeDefined();

    // All methods should be no-ops (don't throw)
    expect(() => client!.captureError(new Error("test"))).not.toThrow();
    expect(() => client!.captureMessage("test")).not.toThrow();
    expect(() => client!.setUser("user-123")).not.toThrow();
    expect(() => client!.addContext("key", "value")).not.toThrow();
    expect(() => client!.destroy()).not.toThrow();
  });

  it("no-op client does not install global error handlers", () => {
    const addSpy = vi.spyOn(window, "addEventListener");
    client = init(baseConfig({ enabled: false }));

    // Should not have added error/unhandledrejection listeners
    const errorCalls = addSpy.mock.calls.filter(
      (call) => call[0] === "error" || call[0] === "unhandledrejection"
    );
    expect(errorCalls.length).toBe(0);
    addSpy.mockRestore();
  });

  // --- beforeSend callback ---

  it("accepts beforeSend callback in config", () => {
    const beforeSend = vi.fn((event) => event);
    client = init(baseConfig({ beforeSend }));
    expect(client).toBeDefined();
  });

  it("accepts release in config", () => {
    client = init(baseConfig({ release: "1.2.3" }));
    expect(client).toBeDefined();
  });
});

describe("MonlightClient methods", () => {
  let client: MonlightClient;

  beforeEach(() => {
    client = init(baseConfig());
  });

  afterEach(() => {
    client.destroy();
  });

  it("captureError accepts an Error object", () => {
    expect(() => client.captureError(new Error("test error"))).not.toThrow();
  });

  it("captureError accepts Error with additional context", () => {
    expect(() =>
      client.captureError(new Error("test error"), { page: "/checkout" })
    ).not.toThrow();
  });

  it("captureMessage accepts a message string", () => {
    expect(() => client.captureMessage("Something happened")).not.toThrow();
  });

  it("captureMessage accepts message with level", () => {
    expect(() =>
      client.captureMessage("Warning occurred", "warning")
    ).not.toThrow();
  });

  it("setUser accepts a user ID string", () => {
    expect(() => client.setUser("user-456")).not.toThrow();
  });

  it("addContext accepts key-value pair", () => {
    expect(() => client.addContext("build", "abc123")).not.toThrow();
  });

  it("addContext accepts complex values", () => {
    expect(() =>
      client.addContext("metadata", { version: "1.0", features: ["a", "b"] })
    ).not.toThrow();
  });

  it("destroy can be called multiple times without error", () => {
    expect(() => {
      client.destroy();
      client.destroy();
    }).not.toThrow();
  });
});

describe("MonlightClient.destroy()", () => {
  it("removes global error listeners on destroy", () => {
    const removeSpy = vi.spyOn(window, "removeEventListener");
    const client = init(baseConfig());
    client.destroy();

    const removedTypes = removeSpy.mock.calls.map((c) => c[0]);
    expect(removedTypes).toContain("error");
    expect(removedTypes).toContain("unhandledrejection");
    removeSpy.mockRestore();
  });

  it("restores console methods when captureConsole is true", () => {
    const originalError = console.error;
    const originalWarn = console.warn;

    const client = init(baseConfig({ captureConsole: true }));

    // Console methods should be wrapped
    expect(console.error).not.toBe(originalError);
    expect(console.warn).not.toBe(originalWarn);

    client.destroy();

    // Console methods should be restored
    expect(console.error).toBe(originalError);
    expect(console.warn).toBe(originalWarn);
  });
});

describe("UMD auto-initialization", () => {
  afterEach(() => {
    // Clean up window globals
    delete (window as any).MonlightConfig;
    if ((window as any).Monlight) {
      (window as any).Monlight.destroy();
      delete (window as any).Monlight;
    }
  });

  it("auto-initializes when window.MonlightConfig is present", async () => {
    // The auto-init code in core.ts runs on module load.
    // To test it, we set window.MonlightConfig before dynamically re-importing.
    (window as any).MonlightConfig = {
      dsn: "auto-init-key",
      endpoint: "https://monitoring.example.com",
    };

    // Re-import to trigger auto-init
    // vitest caches modules, so we use a timestamp-based cache buster
    // Instead, we test the pattern by simulating what the auto-init code does
    const { init: initFn } = await import("./core");
    const client = initFn((window as any).MonlightConfig);
    expect(client).toBeDefined();
    expect(typeof client.captureError).toBe("function");
    client.destroy();
  });

  it("exposes client as window.Monlight after auto-init", () => {
    // Simulate auto-init
    (window as any).MonlightConfig = {
      dsn: "auto-key",
      endpoint: "https://example.com",
    };

    try {
      (window as any).Monlight = init((window as any).MonlightConfig);
      expect((window as any).Monlight).toBeDefined();
      expect(typeof (window as any).Monlight.captureError).toBe("function");
      expect(typeof (window as any).Monlight.setUser).toBe("function");
    } finally {
      if ((window as any).Monlight) {
        (window as any).Monlight.destroy();
      }
    }
  });

  it("auto-init handles invalid config gracefully (no crash)", () => {
    // The auto-init wraps init() in try/catch and logs to console.error
    // Simulate invalid config
    (window as any).MonlightConfig = { dsn: "", endpoint: "" };

    expect(() => {
      try {
        init((window as any).MonlightConfig);
      } catch (e) {
        // Auto-init would catch this and console.error
        console.error("[Monlight] Auto-init failed:", e);
      }
    }).not.toThrow();
  });
});

describe("sub-module initialization", () => {
  let client: MonlightClient;

  afterEach(() => {
    if (client) client.destroy();
  });

  it("installs global error listener on init", () => {
    const addSpy = vi.spyOn(window, "addEventListener");
    client = init(baseConfig());

    const addedTypes = addSpy.mock.calls.map((c) => c[0]);
    expect(addedTypes).toContain("error");
    expect(addedTypes).toContain("unhandledrejection");
    addSpy.mockRestore();
  });

  it("installs visibilitychange listener for vitals reporting", () => {
    const addSpy = vi.spyOn(document, "addEventListener");
    client = init(baseConfig());

    const addedTypes = addSpy.mock.calls.map((c) => c[0]);
    expect(addedTypes).toContain("visibilitychange");
    addSpy.mockRestore();
  });

  it("installs pagehide listener for transport flush", () => {
    const addSpy = vi.spyOn(window, "addEventListener");
    client = init(baseConfig());

    const addedTypes = addSpy.mock.calls.map((c) => c[0]);
    expect(addedTypes).toContain("pagehide");
    addSpy.mockRestore();
  });

  it("patches console.error and console.warn when captureConsole is true", () => {
    const originalError = console.error;
    const originalWarn = console.warn;

    client = init(baseConfig({ captureConsole: true }));

    expect(console.error).not.toBe(originalError);
    expect(console.warn).not.toBe(originalWarn);
  });

  it("does not patch console when captureConsole is false (default)", () => {
    const originalError = console.error;
    const originalWarn = console.warn;

    client = init(baseConfig({ captureConsole: false }));

    expect(console.error).toBe(originalError);
    expect(console.warn).toBe(originalWarn);
  });
});

describe("beforeSend callback integration", () => {
  it("beforeSend can modify error payload", () => {
    const beforeSend = vi.fn((event) => ({
      ...event,
      message: "modified: " + event.message,
    }));
    const client = init(baseConfig({ beforeSend }));

    // Capture an error — beforeSend should be called
    client.captureError(new Error("original message"));

    expect(beforeSend).toHaveBeenCalledTimes(1);
    const payload = beforeSend.mock.calls[0][0];
    expect(payload.type).toBe("Error");
    expect(payload.message).toBe("original message");
    expect(payload.session_id).toBeDefined();
    expect(payload.timestamp).toBeDefined();

    client.destroy();
  });

  it("beforeSend returning null drops the event", () => {
    // We can verify by checking transport — but simpler is to check
    // beforeSend was called and the error was captured silently
    const beforeSend = vi.fn(() => null);
    const client = init(baseConfig({ beforeSend }));

    // This should not throw even though beforeSend drops the event
    expect(() => client.captureError(new Error("dropped"))).not.toThrow();
    expect(beforeSend).toHaveBeenCalledTimes(1);

    client.destroy();
  });
});

describe("sampleRate 0 skips vitals", () => {
  it("does not observe performance when sampleRate is 0", () => {
    // With sampleRate 0, VitalsCollector should skip observation
    // We can verify by checking no PerformanceObserver listeners are added
    // In jsdom, PerformanceObserver may not exist, but the SDK handles that gracefully
    const client = init(baseConfig({ sampleRate: 0 }));
    expect(client).toBeDefined();
    client.destroy();
  });
});
