/**
 * Session module — anonymous session ID management
 */

const SESSION_KEY = "monlight_session_id";

/**
 * Generate a UUID v4 string
 */
function generateUUID(): string {
  // Use crypto.randomUUID if available (modern browsers)
  if (
    typeof crypto !== "undefined" &&
    typeof crypto.randomUUID === "function"
  ) {
    return crypto.randomUUID();
  }
  // Fallback: manual UUID v4 generation
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

/**
 * Get or create a session ID.
 * Stored in sessionStorage so it persists across navigations
 * within the same tab, but a new tab gets a new ID.
 */
export function getSessionId(): string {
  if (typeof sessionStorage !== "undefined") {
    const existing = sessionStorage.getItem(SESSION_KEY);
    if (existing) {
      return existing;
    }
    const id = generateUUID();
    sessionStorage.setItem(SESSION_KEY, id);
    return id;
  }
  // Fallback if sessionStorage is not available
  return generateUUID();
}
