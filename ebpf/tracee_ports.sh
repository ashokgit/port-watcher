#!/usr/bin/env bash
set -euo pipefail

# Event-driven port watcher using Tracee (eBPF)
# - Detects bind()/listen()/close() events and emits open/close logs
# - Tracks pid+fd -> port mapping to infer closures reliably

TRACE_EVENTS_DEFAULT="security_socket_bind,close"
TRACE_EVENTS="${TRACE_EBPF_EVENTS:-$TRACE_EVENTS_DEFAULT}"

# Find tracee binary (works with aquasec/tracee image or locally installed tracee)
find_tracee() {
  if command -v tracee >/dev/null 2>&1; then
    command -v tracee
    return 0
  fi
  for p in /tracee/tracee /usr/local/bin/tracee /usr/bin/tracee; do
    if [[ -x "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  echo "[ebpf] ERROR: tracee binary not found in PATH or known locations" >&2
  exit 1
}

TRACEE_BIN="$(find_tracee)"

# Ensure musl libc is found if Tracee was linked against it
if ldd "${TRACEE_BIN}" 2>/dev/null | grep -q 'musl'; then
  export LD_LIBRARY_PATH="/lib:/lib/aarch64-linux-musl:${LD_LIBRARY_PATH:-}"
fi

echo "[ebpf] Starting Tracee-based watcher. events=${TRACE_EVENTS}" >&2

declare -A FD_PORT_BY_PIDFD   # key: "pid:fd" -> port
declare -A LAST_PID_BY_PORT    # key: port -> last pid (best-effort)

# jq helpers that are resilient to schema differences across Tracee versions
JQ_EVENT_NAME='(.eventName // .event_name // .event.name // .name // "")'
JQ_PID='(.processId // .pid // .process.pid // .threadId // .tid // 0)'
JQ_FD='(.args[]? | select((.name=="sockfd") or (.name=="fd")) | .value // empty)'
# Extract address object and infer port for IPv4/IPv6
JQ_ADDR_OBJ='(.args[]? | select((.name=="local_addr") or (.name=="addr") or (.name=="address")) | .value // empty)'
JQ_PORT='(
  (${JQ_ADDR_OBJ} | .sin6_port // .sin_port // .port // empty) //
  (.args[]? | select((.name=="port") or (.name=="dport") or (.name=="sport")) | .value // empty) //
  # Fallback: parse trailing :<port>
  ((${JQ_ADDR_OBJ}) | tostring | capture(":(?<p>[0-9]+)$").p // empty)
)'
JQ_FAMILY='((${JQ_ADDR_OBJ}) | .sa_family // "")'

process_bind_event() {
  local json="$1"
  local pid fd port family
  pid=$(jq -r "${JQ_PID}" <<<"$json" 2>/dev/null || echo 0)
  fd=$(jq -r "${JQ_FD}" <<<"$json" 2>/dev/null || echo "")
  port=$(jq -r "${JQ_PORT}" <<<"$json" 2>/dev/null || echo "")
  family=$(jq -r "${JQ_FAMILY}" <<<"$json" 2>/dev/null || echo "")

  # Normalize
  [[ "$pid" == "null" || -z "$pid" ]] && pid=0
  [[ "$fd" == "null" || -z "$fd" ]] && fd=""
  [[ "$port" == "null" || -z "$port" ]] && port=""

  # Ignore families without concept of numeric port
  if [[ "$family" == "AF_UNIX" ]]; then
    return 0
  fi

  # Basic sanity
  if [[ -z "$port" || "$port" == "0" ]]; then
    return 0
  fi

  local key
  key="${pid}:${fd}"

  FD_PORT_BY_PIDFD["$key"]="$port"
  LAST_PID_BY_PORT["$port"]="$pid"

  echo "[$(date)] New port opened: ${port} (pid: ${pid}, fd: ${fd})"
}

process_listen_event() {
  # We could enrich/confirm bind events here if needed.
  return 0
}

process_close_event() {
  local json="$1"
  local pid fd
  pid=$(jq -r "${JQ_PID}" <<<"$json" 2>/dev/null || echo 0)
  fd=$(jq -r "${JQ_FD}" <<<"$json" 2>/dev/null || echo "")
  [[ "$pid" == "null" || -z "$pid" ]] && pid=0
  [[ "$fd" == "null" || -z "$fd" ]] && fd=""

  local key port
  key="${pid}:${fd}"
  port="${FD_PORT_BY_PIDFD[$key]:-}"
  if [[ -n "$port" ]]; then
    echo "[$(date)] Port closed: ${port} (last pid: ${pid})"
    unset 'FD_PORT_BY_PIDFD[$key]'
  fi
}

# Start Tracee and process its JSON output line-by-line
LIBBPFGO_OSRELEASE_FILE="/etc/os-release-host" \
"${TRACEE_BIN}" --output json --events "${TRACE_EVENTS}" 2>/dev/null |
while IFS= read -r line; do
  # Fast-path: ignore non-JSON
  [[ -z "$line" || "$line" != \{* ]] && continue

  # Determine event name
  ev=$(jq -r "${JQ_EVENT_NAME}" <<<"$line" 2>/dev/null || echo "")
  [[ "$ev" == "null" ]] && ev=""

  case "$ev" in
    security_socket_bind|bind)
      process_bind_event "$line"
      ;;
    listen)
      process_listen_event "$line"
      ;;
    close)
      process_close_event "$line"
      ;;
    *)
      # Ignore other events
      ;;
  esac
done


