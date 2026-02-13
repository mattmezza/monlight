#!/usr/bin/env bash
#
# End-to-end smoke test for Monlight services.
#
# Prerequisites:
#   docker compose -f docker-compose.test.yml up --build -d
#
# Usage:
#   ./smoke-test.sh
#
# Exit codes:
#   0 - all tests passed
#   1 - one or more tests failed

set -euo pipefail

API_KEY="test_api_key_e2e_12345"
ADMIN_KEY="test_admin_key_e2e_12345"
ERROR_TRACKER_URL="http://localhost:15010"
LOG_VIEWER_URL="http://localhost:15011"
METRICS_COLLECTOR_URL="http://localhost:15012"
BROWSER_RELAY_URL="http://localhost:15013"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

section() {
  echo ""
  echo "=== $1 ==="
}

# ---------------------------------------------------------------------------
# Wait for services to be healthy
# ---------------------------------------------------------------------------
section "Waiting for services to be healthy"

wait_for_health() {
  local name="$1"
  local url="$2"
  local max_wait=60
  local waited=0

  while [ $waited -lt $max_wait ]; do
    if curl -sf "$url/health" > /dev/null 2>&1; then
      pass "$name is healthy (${waited}s)"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done

  fail "$name did not become healthy within ${max_wait}s"
  return 1
}

wait_for_health "Error Tracker" "$ERROR_TRACKER_URL"
wait_for_health "Log Viewer" "$LOG_VIEWER_URL"
wait_for_health "Metrics Collector" "$METRICS_COLLECTOR_URL"
wait_for_health "Browser Relay" "$BROWSER_RELAY_URL"

# ---------------------------------------------------------------------------
# 1. Health check endpoints (no auth required)
# ---------------------------------------------------------------------------
section "Health check endpoints"

check_health() {
  local name="$1"
  local url="$2"

  local response
  response=$(curl -sf "$url/health" 2>&1) || { fail "$name /health unreachable"; return; }

  if echo "$response" | grep -q '"status"'; then
    if echo "$response" | grep -q '"ok"'; then
      pass "$name /health returns status ok"
    else
      fail "$name /health response missing 'ok': $response"
    fi
  else
    fail "$name /health response missing 'status': $response"
  fi
}

check_health "Error Tracker" "$ERROR_TRACKER_URL"
check_health "Log Viewer" "$LOG_VIEWER_URL"
check_health "Metrics Collector" "$METRICS_COLLECTOR_URL"
check_health "Browser Relay" "$BROWSER_RELAY_URL"

# ---------------------------------------------------------------------------
# 2. Error Tracker: POST /api/errors returns 201
# ---------------------------------------------------------------------------
section "Error Tracker: POST /api/errors"

ERROR_PAYLOAD='{
  "project": "e2e-test",
  "environment": "test",
  "exception_type": "TestError",
  "message": "This is a smoke test error",
  "traceback": "Traceback (most recent call last):\n  File \"/app/test.py\", line 42, in test_func\n    raise TestError(\"smoke test\")\nTestError: This is a smoke test error"
}'

HTTP_CODE=$(curl -s -o /tmp/e2e_error_response.txt -w "%{http_code}" \
  -X POST "$ERROR_TRACKER_URL/api/errors" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d "$ERROR_PAYLOAD")

ERROR_RESPONSE=$(cat /tmp/e2e_error_response.txt)

if [ "$HTTP_CODE" = "201" ]; then
  pass "POST /api/errors returns 201 (new error created)"
else
  fail "POST /api/errors returned $HTTP_CODE, expected 201. Response: $ERROR_RESPONSE"
fi

if echo "$ERROR_RESPONSE" | grep -q '"status"'; then
  if echo "$ERROR_RESPONSE" | grep -q '"created"'; then
    pass "Response contains status=created"
  else
    fail "Response status is not 'created': $ERROR_RESPONSE"
  fi
else
  fail "Response missing 'status' field: $ERROR_RESPONSE"
fi

if echo "$ERROR_RESPONSE" | grep -q '"fingerprint"'; then
  pass "Response contains fingerprint"
else
  fail "Response missing 'fingerprint': $ERROR_RESPONSE"
fi

# Verify duplicate returns 200 with incremented count
HTTP_CODE2=$(curl -s -o /tmp/e2e_error_response2.txt -w "%{http_code}" \
  -X POST "$ERROR_TRACKER_URL/api/errors" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d "$ERROR_PAYLOAD")

ERROR_RESPONSE2=$(cat /tmp/e2e_error_response2.txt)

if [ "$HTTP_CODE2" = "200" ]; then
  pass "Duplicate POST /api/errors returns 200 (incremented)"
else
  fail "Duplicate POST returned $HTTP_CODE2, expected 200. Response: $ERROR_RESPONSE2"
fi

# Verify GET /api/errors returns the error
HTTP_CODE3=$(curl -s -o /tmp/e2e_error_list.txt -w "%{http_code}" \
  "$ERROR_TRACKER_URL/api/errors?project=e2e-test" \
  -H "X-API-Key: $API_KEY")

ERROR_LIST=$(cat /tmp/e2e_error_list.txt)

if [ "$HTTP_CODE3" = "200" ]; then
  pass "GET /api/errors returns 200"
else
  fail "GET /api/errors returned $HTTP_CODE3"
fi

if echo "$ERROR_LIST" | grep -q '"TestError"'; then
  pass "Error list contains the test error"
else
  fail "Error list missing TestError: $ERROR_LIST"
fi

# ---------------------------------------------------------------------------
# 3. Log Viewer: handles empty log directory gracefully
# ---------------------------------------------------------------------------
section "Log Viewer: empty log directory handling"

# The log viewer should already be running with an empty LOG_SOURCES volume.
# Verify it's still healthy (not crashed) and responds to API.
HTTP_CODE_LV=$(curl -s -o /tmp/e2e_lv_health.txt -w "%{http_code}" \
  "$LOG_VIEWER_URL/health")

if [ "$HTTP_CODE_LV" = "200" ]; then
  pass "Log Viewer is healthy with empty log directory"
else
  fail "Log Viewer /health returned $HTTP_CODE_LV"
fi

# Check the stats endpoint works
HTTP_CODE_STATS=$(curl -s -o /tmp/e2e_lv_stats.txt -w "%{http_code}" \
  "$LOG_VIEWER_URL/api/stats" \
  -H "X-API-Key: $API_KEY")

LV_STATS=$(cat /tmp/e2e_lv_stats.txt)

if [ "$HTTP_CODE_STATS" = "200" ]; then
  pass "GET /api/stats returns 200"
else
  fail "GET /api/stats returned $HTTP_CODE_STATS. Response: $LV_STATS"
fi

# Check containers endpoint
HTTP_CODE_CONT=$(curl -s -o /tmp/e2e_lv_containers.txt -w "%{http_code}" \
  "$LOG_VIEWER_URL/api/containers" \
  -H "X-API-Key: $API_KEY")

if [ "$HTTP_CODE_CONT" = "200" ]; then
  pass "GET /api/containers returns 200"
else
  fail "GET /api/containers returned $HTTP_CODE_CONT"
fi

# Check logs endpoint with no data
HTTP_CODE_LOGS=$(curl -s -o /tmp/e2e_lv_logs.txt -w "%{http_code}" \
  "$LOG_VIEWER_URL/api/logs" \
  -H "X-API-Key: $API_KEY")

if [ "$HTTP_CODE_LOGS" = "200" ]; then
  pass "GET /api/logs returns 200 (empty)"
else
  fail "GET /api/logs returned $HTTP_CODE_LOGS"
fi

# ---------------------------------------------------------------------------
# 4. Metrics Collector: POST /api/metrics returns 202
# ---------------------------------------------------------------------------
section "Metrics Collector: POST /api/metrics"

METRICS_PAYLOAD='{
  "metrics": [
    {
      "name": "http_requests_total",
      "type": "counter",
      "labels": {"method": "GET", "endpoint": "/test", "status": "200"},
      "value": 1
    },
    {
      "name": "http_request_duration_seconds",
      "type": "histogram",
      "labels": {"method": "GET", "endpoint": "/test", "status": "200"},
      "value": 0.042
    },
    {
      "name": "active_connections",
      "type": "gauge",
      "labels": {},
      "value": 5
    }
  ]
}'

HTTP_CODE_MC=$(curl -s -o /tmp/e2e_mc_response.txt -w "%{http_code}" \
  -X POST "$METRICS_COLLECTOR_URL/api/metrics" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d "$METRICS_PAYLOAD")

MC_RESPONSE=$(cat /tmp/e2e_mc_response.txt)

if [ "$HTTP_CODE_MC" = "202" ]; then
  pass "POST /api/metrics returns 202 (accepted)"
else
  fail "POST /api/metrics returned $HTTP_CODE_MC, expected 202. Response: $MC_RESPONSE"
fi

if echo "$MC_RESPONSE" | grep -q '"accepted"'; then
  pass "Response contains status=accepted"
else
  fail "Response missing 'accepted': $MC_RESPONSE"
fi

if echo "$MC_RESPONSE" | grep -q '"count"'; then
  pass "Response contains count field"
else
  fail "Response missing 'count': $MC_RESPONSE"
fi

# Verify GET /api/metrics/names returns the metrics
HTTP_CODE_MN=$(curl -s -o /tmp/e2e_mc_names.txt -w "%{http_code}" \
  "$METRICS_COLLECTOR_URL/api/metrics/names" \
  -H "X-API-Key: $API_KEY")

MC_NAMES=$(cat /tmp/e2e_mc_names.txt)

if [ "$HTTP_CODE_MN" = "200" ]; then
  pass "GET /api/metrics/names returns 200"
else
  fail "GET /api/metrics/names returned $HTTP_CODE_MN"
fi

# ---------------------------------------------------------------------------
# 5. Web UIs are accessible and render HTML
# ---------------------------------------------------------------------------
section "Web UIs render HTML"

check_web_ui() {
  local name="$1"
  local url="$2"

  local response
  HTTP_CODE_UI=$(curl -s -o /tmp/e2e_ui_response.txt -w "%{http_code}" "$url")
  response=$(cat /tmp/e2e_ui_response.txt)

  if [ "$HTTP_CODE_UI" = "200" ]; then
    pass "$name returns 200"
  else
    fail "$name returned $HTTP_CODE_UI"
    return
  fi

  if echo "$response" | grep -qi '<html'; then
    pass "$name renders HTML (contains <html)"
  else
    fail "$name response does not contain <html"
  fi

  if echo "$response" | grep -qi 'tailwind\|class='; then
    pass "$name uses CSS styling"
  else
    fail "$name response has no CSS styling detected"
  fi
}

check_web_ui "Error Tracker UI" "$ERROR_TRACKER_URL/"
check_web_ui "Log Viewer UI" "$LOG_VIEWER_URL/"
check_web_ui "Metrics Collector UI" "$METRICS_COLLECTOR_URL/"

# ---------------------------------------------------------------------------
# 6. Browser Relay: DSN key management
# ---------------------------------------------------------------------------
section "Browser Relay: DSN key management"

# Create a DSN key
HTTP_CODE_DSN=$(curl -s -o /tmp/e2e_dsn_response.txt -w "%{http_code}" \
  -X POST "$BROWSER_RELAY_URL/api/dsn-keys" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $ADMIN_KEY" \
  -d '{"project": "e2e-test"}')

DSN_RESPONSE=$(cat /tmp/e2e_dsn_response.txt)

if [ "$HTTP_CODE_DSN" = "201" ]; then
  pass "POST /api/dsn-keys returns 201 (key created)"
else
  fail "POST /api/dsn-keys returned $HTTP_CODE_DSN, expected 201. Response: $DSN_RESPONSE"
fi

# Extract the public key
DSN_KEY=$(echo "$DSN_RESPONSE" | grep -o '"public_key":"[^"]*"' | cut -d'"' -f4)

if [ -n "$DSN_KEY" ] && [ ${#DSN_KEY} -eq 32 ]; then
  pass "DSN key is a 32-character hex string: $DSN_KEY"
else
  fail "DSN key is missing or malformed: $DSN_KEY"
fi

# List DSN keys
HTTP_CODE_DSNL=$(curl -s -o /tmp/e2e_dsn_list.txt -w "%{http_code}" \
  "$BROWSER_RELAY_URL/api/dsn-keys" \
  -H "X-API-Key: $ADMIN_KEY")

DSN_LIST=$(cat /tmp/e2e_dsn_list.txt)

if [ "$HTTP_CODE_DSNL" = "200" ]; then
  pass "GET /api/dsn-keys returns 200"
else
  fail "GET /api/dsn-keys returned $HTTP_CODE_DSNL"
fi

if echo "$DSN_LIST" | grep -q "$DSN_KEY"; then
  pass "DSN key list contains the created key"
else
  fail "DSN key list missing the created key: $DSN_LIST"
fi

# ---------------------------------------------------------------------------
# 7. Browser Relay: submit browser error via DSN key
# ---------------------------------------------------------------------------
section "Browser Relay: submit browser error"

BROWSER_ERROR_PAYLOAD='{
  "type": "TypeError",
  "message": "Cannot read property of undefined",
  "stack": "TypeError: Cannot read property of undefined\n    at onClick (app.min.js:1:2345)\n    at HTMLButtonElement.dispatch (vendor.min.js:2:6789)",
  "url": "https://example.com/dashboard",
  "user_agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
  "session_id": "e2e-test-session-001",
  "environment": "test"
}'

HTTP_CODE_BE=$(curl -s -o /tmp/e2e_browser_error.txt -w "%{http_code}" \
  -X POST "$BROWSER_RELAY_URL/api/browser/errors" \
  -H "Content-Type: application/json" \
  -H "X-Monlight-Key: $DSN_KEY" \
  -H "Origin: http://localhost:3000" \
  -d "$BROWSER_ERROR_PAYLOAD")

BE_RESPONSE=$(cat /tmp/e2e_browser_error.txt)

if [ "$HTTP_CODE_BE" = "201" ]; then
  pass "POST /api/browser/errors returns 201 (error forwarded)"
else
  fail "POST /api/browser/errors returned $HTTP_CODE_BE, expected 201. Response: $BE_RESPONSE"
fi

# ---------------------------------------------------------------------------
# 8. Browser Relay: submit browser metrics via DSN key
# ---------------------------------------------------------------------------
section "Browser Relay: submit browser metrics"

BROWSER_METRICS_PAYLOAD='{
  "metrics": [
    {"name": "web_vitals_lcp", "type": "histogram", "value": 2500},
    {"name": "web_vitals_inp", "type": "histogram", "value": 150},
    {"name": "web_vitals_cls", "type": "histogram", "value": 0.05}
  ],
  "session_id": "e2e-test-session-001",
  "url": "https://example.com/dashboard?tab=1"
}'

HTTP_CODE_BM=$(curl -s -o /tmp/e2e_browser_metrics.txt -w "%{http_code}" \
  -X POST "$BROWSER_RELAY_URL/api/browser/metrics" \
  -H "Content-Type: application/json" \
  -H "X-Monlight-Key: $DSN_KEY" \
  -H "Origin: http://localhost:3000" \
  -d "$BROWSER_METRICS_PAYLOAD")

BM_RESPONSE=$(cat /tmp/e2e_browser_metrics.txt)

if [ "$HTTP_CODE_BM" = "202" ]; then
  pass "POST /api/browser/metrics returns 202 (metrics forwarded)"
else
  fail "POST /api/browser/metrics returned $HTTP_CODE_BM, expected 202. Response: $BM_RESPONSE"
fi

if echo "$BM_RESPONSE" | grep -q '"accepted"'; then
  pass "Metrics response contains status=accepted"
else
  fail "Metrics response missing 'accepted': $BM_RESPONSE"
fi

# ---------------------------------------------------------------------------
# 9. Verify browser error appears in Error Tracker
# ---------------------------------------------------------------------------
section "Verify browser error in Error Tracker"

# Give error-tracker a moment to process
sleep 1

HTTP_CODE_VE=$(curl -s -o /tmp/e2e_verify_error.txt -w "%{http_code}" \
  "$ERROR_TRACKER_URL/api/errors?project=e2e-test&source=browser" \
  -H "X-API-Key: $API_KEY")

VERIFY_ERROR=$(cat /tmp/e2e_verify_error.txt)

if [ "$HTTP_CODE_VE" = "200" ]; then
  pass "GET /api/errors?source=browser returns 200"
else
  fail "GET /api/errors?source=browser returned $HTTP_CODE_VE"
fi

if echo "$VERIFY_ERROR" | grep -q '"TypeError"'; then
  pass "Error Tracker contains the browser TypeError"
else
  fail "Error Tracker missing browser error: $VERIFY_ERROR"
fi

# ---------------------------------------------------------------------------
# 10. Verify browser metrics appear in Metrics Collector
# ---------------------------------------------------------------------------
section "Verify browser metrics in Metrics Collector"

HTTP_CODE_VM=$(curl -s -o /tmp/e2e_verify_metrics.txt -w "%{http_code}" \
  "$METRICS_COLLECTOR_URL/api/metrics/names" \
  -H "X-API-Key: $API_KEY")

VERIFY_METRICS=$(cat /tmp/e2e_verify_metrics.txt)

if [ "$HTTP_CODE_VM" = "200" ]; then
  pass "GET /api/metrics/names returns 200"
else
  fail "GET /api/metrics/names returned $HTTP_CODE_VM"
fi

if echo "$VERIFY_METRICS" | grep -q 'web_vitals_lcp'; then
  pass "Metrics Collector has web_vitals_lcp metric"
else
  fail "Metrics Collector missing web_vitals_lcp: $VERIFY_METRICS"
fi

# ---------------------------------------------------------------------------
# 11. Browser Relay: source map upload
# ---------------------------------------------------------------------------
section "Browser Relay: source map upload"

SOURCE_MAP_PAYLOAD='{
  "project": "e2e-test",
  "release": "1.0.0",
  "file_url": "/static/app.min.js",
  "map_content": "{\"version\":3,\"sources\":[\"app.ts\"],\"mappings\":\"AAAA\"}"
}'

HTTP_CODE_SM=$(curl -s -o /tmp/e2e_source_map.txt -w "%{http_code}" \
  -X POST "$BROWSER_RELAY_URL/api/source-maps" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $ADMIN_KEY" \
  -d "$SOURCE_MAP_PAYLOAD")

SM_RESPONSE=$(cat /tmp/e2e_source_map.txt)

if [ "$HTTP_CODE_SM" = "201" ]; then
  pass "POST /api/source-maps returns 201 (source map uploaded)"
else
  fail "POST /api/source-maps returned $HTTP_CODE_SM, expected 201. Response: $SM_RESPONSE"
fi

if echo "$SM_RESPONSE" | grep -q '"uploaded"'; then
  pass "Source map response contains status=uploaded"
else
  fail "Source map response missing 'uploaded': $SM_RESPONSE"
fi

# ---------------------------------------------------------------------------
# 12. Browser Relay: CORS headers present
# ---------------------------------------------------------------------------
section "Browser Relay: CORS headers"

CORS_RESPONSE=$(curl -s -D - -o /dev/null \
  -X OPTIONS "$BROWSER_RELAY_URL/api/browser/errors" \
  -H "Origin: http://localhost:3000" \
  -H "Access-Control-Request-Method: POST" 2>&1)

if echo "$CORS_RESPONSE" | grep -qi "access-control-allow-origin"; then
  pass "CORS preflight includes Access-Control-Allow-Origin"
else
  fail "CORS preflight missing Access-Control-Allow-Origin header"
fi

if echo "$CORS_RESPONSE" | grep -qi "access-control-allow-methods"; then
  pass "CORS preflight includes Access-Control-Allow-Methods"
else
  fail "CORS preflight missing Access-Control-Allow-Methods header"
fi

# ---------------------------------------------------------------------------
# 13. Browser Relay: rate limiting works
# ---------------------------------------------------------------------------
section "Browser Relay: rate limiting"

# Send 301 requests rapidly (rate limit is 300 per 60s window)
RATE_LIMITED=false
for i in $(seq 1 301); do
  HTTP_CODE_RL=$(curl -s -o /dev/null -w "%{http_code}" \
    "$BROWSER_RELAY_URL/api/browser/errors" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Monlight-Key: $DSN_KEY" \
    -d '{"type":"RateTest","message":"test","stack":"test"}')

  if [ "$HTTP_CODE_RL" = "429" ]; then
    RATE_LIMITED=true
    pass "Rate limited at request $i (got 429)"
    break
  fi
done

if ! $RATE_LIMITED; then
  fail "No rate limiting after 301 requests (expected 429)"
fi

section "Graceful shutdown"
section "Graceful shutdown"

check_graceful_shutdown() {
  local name="$1"
  local container="$2"

  # Send SIGTERM to main process (PID 1) inside the container
  docker kill --signal=SIGTERM "$container" > /dev/null 2>&1

  # Wait up to 10 seconds for the container to stop
  local waited=0
  while [ $waited -lt 10 ]; do
    local state
    state=$(docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null || echo "removed")
    if [ "$state" = "false" ] || [ "$state" = "removed" ]; then
      # Check exit code
      local exit_code
      exit_code=$(docker inspect --format='{{.State.ExitCode}}' "$container" 2>/dev/null || echo "unknown")
      if [ "$exit_code" = "0" ]; then
        pass "$name exited cleanly with code 0 (${waited}s)"
      else
        fail "$name exited with code $exit_code (expected 0)"
      fi
      return
    fi
    sleep 1
    waited=$((waited + 1))
  done

  fail "$name did not stop within 10 seconds after SIGTERM"
  # Force kill if still running
  docker kill "$container" > /dev/null 2>&1 || true
}

check_graceful_shutdown "Browser Relay" "e2e_browser_relay"
check_graceful_shutdown "Error Tracker" "e2e_error_tracker"
check_graceful_shutdown "Log Viewer" "e2e_log_viewer"
check_graceful_shutdown "Metrics Collector" "e2e_metrics_collector"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "==========================================="

# Cleanup temp files
rm -f /tmp/e2e_*.txt

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Some tests failed. Check the output above for details."
  echo "Container logs can be viewed with:"
  echo "  docker compose -f docker-compose.test.yml logs"
  exit 1
fi

echo ""
echo "All smoke tests passed!"
exit 0
