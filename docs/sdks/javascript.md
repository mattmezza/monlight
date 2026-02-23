---
layout: default
title: JavaScript SDK
parent: Client SDKs
nav_order: 1
---

# JavaScript SDK

`@monlight/browser` -- zero-dependency browser SDK for error tracking, Web Vitals, and custom metrics. ~5KB gzipped.

## Installation

**npm:**

```bash
npm install @monlight/browser
```

```javascript
import { init } from "@monlight/browser";

const monlight = init({
  dsn: "<your-dsn-public-key>",
  endpoint: "https://monitoring.example.com",
});
```

**Script tag:**

```html
<script>
  window.MonlightConfig = {
    dsn: "<your-dsn-public-key>",
    endpoint: "https://monitoring.example.com",
  };
</script>
<script src="https://unpkg.com/@monlight/browser/dist/monlight.min.js"></script>
```

With the script tag approach, the SDK auto-initializes and exposes `window.Monlight`.

## Configuration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `dsn` | string | **(required)** | DSN public key from the browser relay |
| `endpoint` | string | **(required)** | Browser relay URL |
| `release` | string | -- | App version (used for source map matching) |
| `environment` | string | `"prod"` | Environment name |
| `sampleRate` | number | `1.0` | Sampling rate for Web Vitals (0.0-1.0) |
| `debug` | boolean | `false` | Log SDK activity to console |
| `enabled` | boolean | `true` | Master kill switch |
| `captureConsole` | boolean | `false` | Capture `console.error` and `console.warn` |
| `beforeSend` | function | -- | `(event) => event \| null` -- transform or drop events |

## Client API

```javascript
const monlight = init({ dsn: "...", endpoint: "..." });

// Manual error capture with optional context
monlight.captureError(new Error("checkout failed"), { page: "/checkout" });

// Capture a message
monlight.captureMessage("rate limit hit", "warning");

// Set user identity (attached to all subsequent errors)
monlight.setUser("user-456");

// Add persistent context to all subsequent errors
monlight.addContext("tenant", "acme");

// Tear down (removes listeners, flushes pending data)
monlight.destroy();
```

## What's captured automatically

### Errors

- Unhandled exceptions (`window.onerror`)
- Unhandled promise rejections (`unhandledrejection`)
- `console.error` and `console.warn` (when `captureConsole: true`)

Errors are deduplicated using a fingerprint of `{type}:{message}:{first_stack_frame}` with a 60-second suppression window.

### Web Vitals

When `sampleRate > 0` and `PerformanceObserver` is available:

| Metric | Name | Type |
|--------|------|------|
| Largest Contentful Paint | `web_vitals_lcp` | histogram |
| Interaction to Next Paint | `web_vitals_inp` | histogram |
| Cumulative Layout Shift | `web_vitals_cls` | histogram |
| First Contentful Paint | `web_vitals_fcp` | histogram |
| Time to First Byte | `web_vitals_ttfb` | histogram |
| Page Load Time | `page_load_time` | histogram |

Vitals are reported on page hide (visibility change), not immediately. CLS uses the session window algorithm (1s gap, 5s max window).

### Network monitoring

The SDK patches `fetch` and `XMLHttpRequest` to automatically collect:

| Metric | Name | Type | Labels |
|--------|------|------|--------|
| Request count | `browser_http_requests_total` | counter | `method`, `status`, `host` |
| Duration | `browser_http_request_duration_ms` | histogram | `method`, `status`, `host` |

HTTP 500+ responses and network failures are captured as `NetworkError` events.

Requests to the monitoring endpoint itself are excluded to prevent infinite loops.

**URL sanitization:** Query parameters, fragments, numeric path segments, and UUIDs are stripped from URLs to reduce label cardinality.

## Transport

- Errors are sent immediately (not batched)
- Metrics are buffered and flushed every 5 seconds or when the buffer reaches 10 items
- On page hide, `navigator.sendBeacon` is used for reliability
- The DSN is sent as `X-Monlight-Key` header (or `?key=` query param for sendBeacon)
- Transport errors are silently caught (never thrown to the host page)

## Sessions

An anonymous UUID v4 session ID is generated per browser tab and stored in `sessionStorage`. No cookies or localStorage are used. A new tab gets a new session ID.

## beforeSend

Filter or modify events before they are sent:

```javascript
const monlight = init({
  dsn: "...",
  endpoint: "...",
  beforeSend: (event) => {
    // Drop events from browser extensions
    if (event.stack && event.stack.includes("chrome-extension://")) {
      return null;
    }
    return event;
  },
});
```

Returning `null` drops the event.
