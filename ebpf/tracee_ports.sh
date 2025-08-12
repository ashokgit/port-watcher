#!/usr/bin/env bash
set -euo pipefail

# Event-driven port watcher using Tracee (eBPF)
# - Detects bind()/listen()/close() events and emits open/close logs
# - Tracks pid+fd -> port mapping to infer closures reliably

# Default to minimal event set for efficiency; can be overridden via TRACE_EBPF_EVENTS
TRACE_EVENTS_DEFAULT="bind,close"
TRACE_EVENTS="${TRACE_EBPF_EVENTS:-$TRACE_EVENTS_DEFAULT}"
TRACEE_ARGS="${TRACEE_ARGS:-}"

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

listener_url="${LISTENER_URL:-}"

# Optional filter: only watch specific ports when provided
# Accepts comma/space separated list and ranges like 3000-3005
port_filter_raw="${WATCH_PORTS:-${DESIRED_PORTS:-}}"
port_filter_enabled=0
declare -A allowed_ports
allowed_ports_regex=""

expand_and_set_allowed_ports() {
  local raw="$1" tok a b p list
  raw="${raw//,/ }"; raw="${raw//$'\n'/ }"; raw="${raw//$'\t'/ }"
  for tok in $raw; do
    tok="${tok//[^0-9-]/}"
    if [[ -z "$tok" ]]; then continue; fi
    if [[ "$tok" =~ ^[0-9]+-[0-9]+$ ]]; then
      IFS='-' read -r a b <<<"$tok"
      if (( a <= b )); then
        for ((p=a; p<=b; p++)); do allowed_ports["$p"]=1; done
      else
        for ((p=b; p<=a; p++)); do allowed_ports["$p"]=1; done
      fi
    elif [[ "$tok" =~ ^[0-9]+$ ]]; then
      allowed_ports["$tok"]=1
    fi
  done
  if (( ${#allowed_ports[@]} > 0 )); then
    port_filter_enabled=1
    list="$(printf "%s|" "${!allowed_ports[@]}")"
    allowed_ports_regex="^(${list%|})$"
  fi
}

if [[ -n "$port_filter_raw" ]]; then
  expand_and_set_allowed_ports "$port_filter_raw"
fi
# Identify container
detect_container_id() {
  local cid
  cid=$(sed -nE 's#^.*/([0-9a-f]{12,64})(?:\\.scope)?$#\1#p' /proc/self/cgroup 2>/dev/null | tail -n1 || true)
  if [[ -z "$cid" ]]; then
    cid=$(sed -nE 's#^.*/containers/([0-9a-f]{12,64})/.*$#\1#p' /proc/self/mountinfo 2>/dev/null | head -n1 || true)
  fi
  echo "$cid"
}
container_name="${CONTAINER_NAME:-$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)}"
container_id="${CONTAINER_ID:-$(detect_container_id)}"
if [[ -z "$container_id" ]]; then container_id="$container_name"; fi
echo "[ebpf] Starting Tracee-based watcher. events=${TRACE_EVENTS}" >&2
if [[ -n "$listener_url" ]]; then
  echo "[ebpf] Listener URL configured: $listener_url" >&2
fi
if (( port_filter_enabled == 1 )); then
  echo "[ebpf] Port filter enabled. Watching ${#allowed_ports[@]} port(s): $(printf '%s ' "${!allowed_ports[@]}" | xargs -n100 echo)" >&2
fi

declare -A FD_PORT_BY_PIDFD   # key: "pid:fd" -> port
declare -A LAST_PID_BY_PORT    # key: port -> last pid (best-effort)

# Gracefully emit close events for any known open ports
graceful_shutdown() {
  if [[ "${__shutdown_done:-0}" == "1" ]]; then return; fi
  __shutdown_done=1
  echo "[ebpf] Received termination signal; flushing close events before exit" >&2
  for port in "${!LAST_PID_BY_PORT[@]}"; do
    [[ -z "$port" ]] && continue
    pid="${LAST_PID_BY_PORT[$port]:-0}"
    line="[$(date)] Port closed: ${port} (last pid: ${pid})"
    echo "$line"
    if [[ -n "$listener_url" ]]; then
      payload=$(printf '{"event":"close","port":%s,"last_pid":%s,"container_id":"%s","container_name":"%s","source":"shutdown-ebpf"}' "$port" "$pid" "$container_id" "$container_name")
      curl -sS -m 2 -H 'Content-Type: application/json' --data "$payload" "$listener_url" >/dev/null 2>&1 || true
    fi
  done
  exit 0
}

trap 'graceful_shutdown' TERM INT QUIT EXIT

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
  # Args: pid fd port family
  local pid="$1" fd="$2" port="$3" family="$4"

  [[ "$pid" == "null" || -z "$pid" ]] && pid=0
  [[ "$fd" == "null" || -z "$fd" ]] && fd=""
  [[ "$port" == "null" || -z "$port" ]] && port=""

  if [[ "$family" == "AF_UNIX" ]]; then return 0; fi
  if [[ -z "$port" || "$port" == "0" ]]; then return 0; fi
  if (( port_filter_enabled == 1 )) && [[ ! "$port" =~ $allowed_ports_regex ]]; then return 0; fi

  local key
  key="${pid}:${fd}"

  FD_PORT_BY_PIDFD["$key"]="$port"
  LAST_PID_BY_PORT["$port"]="$pid"

  line="[$(date)] New port opened: ${port} (pid: ${pid}, fd: ${fd})"
  echo "$line"
  if [[ -n "$listener_url" ]]; then
    payload=$(printf '{"event":"open","port":%s,"pid":%s,"fd":%s,"container_id":"%s","container_name":"%s","source":"ebpf"}' "$port" "$pid" "${fd:-0}" "$container_id" "$container_name")
    curl -sS -m 1 -H 'Content-Type: application/json' --data "$payload" "$listener_url" >/dev/null 2>&1 || true
  fi
}

process_listen_event() {
  # We could enrich/confirm bind events here if needed.
  return 0
}

process_close_event() {
  # Args: pid fd
  local pid="$1" fd="$2"
  [[ "$pid" == "null" || -z "$pid" ]] && pid=0
  [[ "$fd" == "null" || -z "$fd" ]] && fd=""

  local key port
  key="${pid}:${fd}"
  port="${FD_PORT_BY_PIDFD[$key]:-}"
  if [[ -n "$port" ]]; then
    if (( port_filter_enabled == 1 )) && [[ ! "$port" =~ $allowed_ports_regex ]]; then
      unset 'FD_PORT_BY_PIDFD[$key]'
      return 0
    fi
    line="[$(date)] Port closed: ${port} (last pid: ${pid})"
    echo "$line"
    if [[ -n "$listener_url" ]]; then
      payload=$(printf '{"event":"close","port":%s,"last_pid":%s,"container_id":"%s","container_name":"%s","source":"ebpf"}' "$port" "$pid" "$container_id" "$container_name")
      curl -sS -m 1 -H 'Content-Type: application/json' --data "$payload" "$listener_url" >/dev/null 2>&1 || true
    fi
    unset 'FD_PORT_BY_PIDFD[$key]'
  fi
}

# Start Tracee and process its JSON output line-by-line (avoid pipeline subshell)
while IFS= read -r line; do
  # Fast-path: ignore non-JSON
  [[ -z "$line" || "$line" != \{* ]] && continue

  # Determine event name
  ev=$(jq -r "${JQ_EVENT_NAME}" <<<"$line" 2>/dev/null || echo "")
  [[ "$ev" == "null" ]] && ev=""

  case "$ev" in
    security_socket_bind|bind)
      # Extract pid, fd, port, family in a single jq call
      read -r pid fd port family < <(jq -r "[${JQ_PID}, ${JQ_FD}, ${JQ_PORT}, ${JQ_FAMILY}] | @tsv" <<<"$line" 2>/dev/null || echo $'0\t\t\t')
      process_bind_event "$pid" "$fd" "$port" "$family"
      ;;
    listen)
      process_listen_event "$line"
      ;;
    close)
      # Extract pid, fd in a single jq call
      read -r pid fd < <(jq -r "[${JQ_PID}, ${JQ_FD}] | @tsv" <<<"$line" 2>/dev/null || echo $'0\t')
      process_close_event "$pid" "$fd"
      ;;
    *)
      # Ignore other events
      ;;
  esac
done < <(LIBBPFGO_OSRELEASE_FILE="/etc/os-release-host" "${TRACEE_BIN}" --output json --events "${TRACE_EVENTS}" ${TRACEE_ARGS} 2>/dev/null)


