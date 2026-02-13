/**
 * Tests for session module — session ID generation and persistence
 */

import { describe, it, expect, beforeEach, vi } from "vitest";
import { getSessionId } from "./session";

const SESSION_KEY = "monlight_session_id";

// UUID v4 format: 8-4-4-4-12 hex chars, version nibble = 4, variant bits
const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

describe("session", () => {
  beforeEach(() => {
    sessionStorage.clear();
  });

  describe("getSessionId", () => {
    it("returns a valid UUID v4 string", () => {
      const id = getSessionId();
      expect(id).toMatch(UUID_REGEX);
    });

    it("returns the same ID on subsequent calls (sessionStorage persistence)", () => {
      const id1 = getSessionId();
      const id2 = getSessionId();
      expect(id1).toBe(id2);
    });

    it("stores the session ID in sessionStorage", () => {
      const id = getSessionId();
      expect(sessionStorage.getItem(SESSION_KEY)).toBe(id);
    });

    it("returns existing ID from sessionStorage if present", () => {
      const presetId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
      sessionStorage.setItem(SESSION_KEY, presetId);
      const id = getSessionId();
      expect(id).toBe(presetId);
    });

    it("generates a new ID when sessionStorage is cleared (simulates new tab)", () => {
      const id1 = getSessionId();
      sessionStorage.clear();
      const id2 = getSessionId();
      expect(id2).toMatch(UUID_REGEX);
      expect(id2).not.toBe(id1);
    });

    it("generates unique IDs across calls when storage is cleared between them", () => {
      const ids = new Set<string>();
      for (let i = 0; i < 20; i++) {
        sessionStorage.clear();
        ids.add(getSessionId());
      }
      // All 20 should be unique (collision probability is astronomically low)
      expect(ids.size).toBe(20);
    });

    it("never uses localStorage", () => {
      const setItemSpy = vi.spyOn(localStorage, "setItem");
      const getItemSpy = vi.spyOn(localStorage, "getItem");
      getSessionId();
      expect(setItemSpy).not.toHaveBeenCalled();
      expect(getItemSpy).not.toHaveBeenCalled();
      setItemSpy.mockRestore();
      getItemSpy.mockRestore();
    });

    it("never sets cookies", () => {
      getSessionId();
      expect(document.cookie).toBe("");
    });
  });

  describe("UUID v4 format", () => {
    it("has version 4 in the correct position (13th character)", () => {
      sessionStorage.clear();
      const id = getSessionId();
      // UUID format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
      // Position 14 (0-indexed) is the version nibble after the second dash
      expect(id[14]).toBe("4");
    });

    it("has correct variant bits (position 19 is 8, 9, a, or b)", () => {
      sessionStorage.clear();
      const id = getSessionId();
      // Position 19 (0-indexed) is the variant nibble
      expect("89ab").toContain(id[19]);
    });

    it("is exactly 36 characters long", () => {
      const id = getSessionId();
      expect(id.length).toBe(36);
    });

    it("has dashes at correct positions", () => {
      const id = getSessionId();
      expect(id[8]).toBe("-");
      expect(id[13]).toBe("-");
      expect(id[18]).toBe("-");
      expect(id[23]).toBe("-");
    });
  });

  describe("crypto.randomUUID fallback", () => {
    it("uses manual fallback when crypto.randomUUID is not available", () => {
      // Save original
      const originalRandomUUID = crypto.randomUUID;
      // Remove randomUUID
      (crypto as any).randomUUID = undefined;

      sessionStorage.clear();
      const id = getSessionId();
      expect(id).toMatch(UUID_REGEX);

      // Restore
      crypto.randomUUID = originalRandomUUID;
    });

    it("manual fallback generates valid UUID v4 format", () => {
      const originalRandomUUID = crypto.randomUUID;
      (crypto as any).randomUUID = undefined;

      // Generate several to check consistency
      for (let i = 0; i < 10; i++) {
        sessionStorage.clear();
        const id = getSessionId();
        expect(id).toMatch(UUID_REGEX);
        expect(id[14]).toBe("4");
        expect("89ab").toContain(id[19]);
      }

      crypto.randomUUID = originalRandomUUID;
    });

    it("manual fallback generates unique IDs", () => {
      const originalRandomUUID = crypto.randomUUID;
      (crypto as any).randomUUID = undefined;

      const ids = new Set<string>();
      for (let i = 0; i < 20; i++) {
        sessionStorage.clear();
        ids.add(getSessionId());
      }
      expect(ids.size).toBe(20);

      crypto.randomUUID = originalRandomUUID;
    });
  });
});
