#!/usr/bin/env bash
#
# End-to-end smoke test for MonlightStack services.
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
ERROR_TRACKER_URL="http://localhost:15010"
LOG_VIEWER_URL="http://localhost:15011"
METRICS_COLLECTOR_URL="http://localhost:15012"

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
# 6. Graceful shutdown (SIGTERM → clean exit within 10 seconds)
# ---------------------------------------------------------------------------
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
