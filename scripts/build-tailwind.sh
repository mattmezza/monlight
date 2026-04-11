#!/usr/bin/env bash
# Compile Tailwind CSS for log-viewer, metrics-collector, error-tracker.
#
# Tailwind v4 resolves `@import "tailwindcss"` relative to the input CSS
# directory, so the entry CSS files live under tools/tailwind/ alongside the
# package.json that owns node_modules. Each entry uses @source to point at
# the html files in the corresponding service. Output is written to that
# service's src/static/tailwind.css and is committed to git so the docker
# build does not need Node.
#
# Usage:
#   scripts/build-tailwind.sh                 # build all services
#   scripts/build-tailwind.sh log-viewer      # build a specific service

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAILWIND_DIR="$REPO_ROOT/tools/tailwind"
TAILWIND_BIN="$TAILWIND_DIR/node_modules/.bin/tailwindcss"

if [ ! -x "$TAILWIND_BIN" ]; then
  echo "==> installing tailwind tooling under $TAILWIND_DIR"
  (cd "$TAILWIND_DIR" && npm install --silent)
fi

build_service() {
  local service="$1"
  local input="$TAILWIND_DIR/${service}.in.css"
  local output="$REPO_ROOT/$service/src/static/tailwind.css"
  if [ ! -f "$input" ]; then
    echo "skip: $service (no $input)"
    return
  fi
  echo "==> building tailwind for $service"
  (cd "$TAILWIND_DIR" && "$TAILWIND_BIN" -i "$input" -o "$output" --minify)
}

if [ "$#" -eq 0 ]; then
  build_service log-viewer
  build_service metrics-collector
  build_service error-tracker
else
  for s in "$@"; do
    build_service "$s"
  done
fi
