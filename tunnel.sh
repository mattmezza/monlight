#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
VPS_HOST="${TUNNEL_HOST:-}"
VPS_USER="${TUNNEL_USER:-root}"
SSH_KEY="${TUNNEL_SSH_KEY:-}"
LOCAL_BIND="127.0.0.1"

# --- Cleanup ---
TUNNEL_PID=""
LOGS_PID=""

cleanup() {
  echo ""
  echo "Shutting down..."
  [[ -n "$LOGS_PID" ]]   && kill "$LOGS_PID"   2>/dev/null || true
  [[ -n "$TUNNEL_PID" ]] && kill "$TUNNEL_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  echo "Done."
}
trap cleanup EXIT INT TERM

# --- Helpers ---
usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [container] [port]

Forward a Docker container port from a remote VPS via SSH tunnel.

Options:
  -h, --host HOST    VPS hostname/IP  (or set TUNNEL_HOST)
  -u, --user USER    SSH user          (or set TUNNEL_USER, default: root)
  -k, --key  PATH    SSH key path      (or set TUNNEL_SSH_KEY)
  -l, --local PORT   Local port to bind (default: same as remote port)
  --no-logs          Don't tail container logs
  --help             Show this help

If container/port are omitted, you'll be prompted to pick interactively.

Examples:
  $(basename "$0") -h myserver.com redis 6379
  $(basename "$0") -h myserver.com                  # interactive picker
  TUNNEL_HOST=myserver.com $(basename "$0")           # using env vars
EOF
  exit 0
}

ssh_cmd() {
  local opts=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=3)
  [[ -n "$SSH_KEY" ]] && opts+=(-i "$SSH_KEY")
  ssh "${opts[@]}" "${VPS_USER}@${VPS_HOST}" "$@"
}

die() { echo "Error: $*" >&2; exit 1; }

# --- Parse args ---
CONTAINER=""
PORT=""
LOCAL_PORT=""
NO_LOGS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--host)  VPS_HOST="$2"; shift 2;;
    -u|--user)  VPS_USER="$2"; shift 2;;
    -k|--key)   SSH_KEY="$2";  shift 2;;
    -l|--local) LOCAL_PORT="$2"; shift 2;;
    --no-logs)  NO_LOGS=true; shift;;
    --help)     usage;;
    -*)         die "Unknown option: $1";;
    *)
      if [[ -z "$CONTAINER" ]]; then
        CONTAINER="$1"
      elif [[ -z "$PORT" ]]; then
        PORT="$1"
      else
        die "Unexpected argument: $1"
      fi
      shift;;
  esac
done

[[ -z "$VPS_HOST" ]] && die "No host specified. Use -h or set TUNNEL_HOST."

# --- Interactive container selection ---
if [[ -z "$CONTAINER" ]]; then
  echo "Fetching running containers from ${VPS_HOST}..."

  CONTAINERS=$(ssh_cmd 'docker ps --format "{{.Names}}\t{{.Image}}\t{{.Ports}}"')
  [[ -z "$CONTAINERS" ]] && die "No running containers found."

  if command -v fzf &>/dev/null; then
    SELECTION=$(echo "$CONTAINERS" | column -t -s $'\t' | fzf --header="NAMES  IMAGE  PORTS")
  else
    echo ""
    echo "Running containers:"
    echo "---"
    i=1
    while IFS= read -r line; do
      printf "  %d) %s\n" "$i" "$line"
      ((i++))
    done <<< "$CONTAINERS"
    echo ""
    read -rp "Pick a number: " choice
    SELECTION=$(echo "$CONTAINERS" | sed -n "${choice}p")
    [[ -z "$SELECTION" ]] && die "Invalid selection."
  fi

  CONTAINER=$(echo "$SELECTION" | awk '{print $1}')
  echo "Selected: $CONTAINER"
fi

# --- Resolve port ---
if [[ -z "$PORT" ]]; then
  echo "Inspecting exposed ports for ${CONTAINER}..."

  PORTS=$(ssh_cmd "docker inspect --format '{{range \$p, \$conf := .Config.ExposedPorts}}{{\$p}}{{\"\\n\"}}{{end}}' ${CONTAINER}" \
    | sed 's|/tcp||;s|/udp||' | grep -v '^$')

  [[ -z "$PORTS" ]] && die "No exposed ports found for ${CONTAINER}."

  PORT_COUNT=$(echo "$PORTS" | wc -l)
  if [[ "$PORT_COUNT" -eq 1 ]]; then
    PORT="$PORTS"
    echo "Port: $PORT"
  else
    echo ""
    echo "Available ports:"
    i=1
    while IFS= read -r p; do
      printf "  %d) %s\n" "$i" "$p"
      ((i++))
    done <<< "$PORTS"
    echo ""
    read -rp "Pick a port: " choice
    PORT=$(echo "$PORTS" | sed -n "${choice}p")
    [[ -z "$PORT" ]] && die "Invalid selection."
  fi
fi

LOCAL_PORT="${LOCAL_PORT:-$PORT}"

# --- Resolve container IP ---
CONTAINER_IP=$(ssh_cmd "docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CONTAINER}")
[[ -z "$CONTAINER_IP" ]] && die "Could not resolve IP for ${CONTAINER}."

# --- Open tunnel ---
echo ""
echo "Forwarding ${LOCAL_BIND}:${LOCAL_PORT} -> ${CONTAINER}(${CONTAINER_IP}):${PORT}"
echo "Press Ctrl-C to stop."
echo ""

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -N -L "${LOCAL_BIND}:${LOCAL_PORT}:${CONTAINER_IP}:${PORT}")
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY")

ssh "${SSH_OPTS[@]}" "${VPS_USER}@${VPS_HOST}" &
TUNNEL_PID=$!

sleep 1
if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
  die "SSH tunnel failed to start."
fi

echo "Tunnel is up: localhost:${LOCAL_PORT}"

# --- Tail logs ---
if [[ "$NO_LOGS" == false ]]; then
  echo "--- Logs for ${CONTAINER} ---"
  echo ""
  ssh_cmd docker logs -f --tail 50 "$CONTAINER" 2>&1 &
  LOGS_PID=$!
  wait "$LOGS_PID" 2>/dev/null || true
else
  wait "$TUNNEL_PID" 2>/dev/null || true
fi
