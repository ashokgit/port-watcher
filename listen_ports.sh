#!/usr/bin/env bash
set -euo pipefail

#
# Tunables
# - SCAN_INTERVAL: base sleep interval between bursts (seconds, supports fractional; default 2)
# - BURST_SCANS: number of rapid scans per cycle to catch short-lived ports (default 1)
# - BURST_DELAY: delay between scans in a burst (seconds, supports fractional; default 0.05)
# - VERBOSE_LSOF: if set to 1, dump lsof details for each new port (default 0)
#
scan_interval="${SCAN_INTERVAL:-2}"
burst_scans="${BURST_SCANS:-1}"
burst_delay="${BURST_DELAY:-0.05}"
verbose_lsof="${VERBOSE_LSOF:-0}"
listener_url="${LISTENER_URL:-}"

# Prefer ss for sampling by default for broader compatibility and speed
# 1 = use /proc/net tcp/udp readers, 0 = use ss for each sample
use_proc_backend="${USE_PROC:-0}"

# Optional close debounce to reduce flapping; in milliseconds (0 = disabled)
close_grace_ms="${CLOSE_GRACE_MS:-0}"

# Persist last snapshot for restart continuity (in tmpfs if available)
snapshot_path="${SNAPSHOT_PATH:-/dev/shm/portwatcher.snapshot}"

prev_ports=""
declare -A port_to_pids
declare -A port_last_seen_ms

backend_label="ss"
if [[ "${use_proc_backend}" == "1" ]]; then backend_label="proc"; fi
echo "[portwatcher] Starting listener. Interval: ${scan_interval}s, burst_scans: ${burst_scans}, burst_delay: ${burst_delay}s, backend: ${backend_label}, close_grace_ms: ${close_grace_ms}"
if [[ -n "$listener_url" ]]; then
  echo "[portwatcher] Listener URL configured: $listener_url"
fi

# Time in milliseconds (best-effort)
now_ms() {
  local t
  t=$(date +%s%3N 2>/dev/null || true)
  if [[ -n "$t" && "$t" =~ ^[0-9]+$ ]]; then
    echo "$t"
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

# Collect currently listening TCP/UDP ports (numeric), one per line, sorted unique
collect_ports_once() {
  if [[ "$use_proc_backend" == "1" ]]; then
    collect_ports_from_proc
  else
    # -n: numeric; -l: listening; -t: TCP; -u: UDP; -H: no header
    ss -tulnH 2>/dev/null \
      | awk '{n=$5; sub(/^.*:/,"",n); if (n ~ /^[0-9]+$/) print n}' \
      | sort -u || true
  fi
}

# Parse /proc/net/{tcp,tcp6,udp,udp6} and return bound/listening ports (numeric)
collect_ports_from_proc() {
  (
    for f in /proc/net/tcp /proc/net/tcp6; do
      [[ -r "$f" ]] || continue
      awk 'NR>1 { split($2,a,":"); print a[2], $4 }' "$f" 2>/dev/null \
        | while read -r hex state; do
            [[ -z "$hex" ]] && continue
            # TCP LISTEN state is 0A
            if [[ "$state" == "0A" ]]; then
              # Convert hex to decimal using shell arithmetic
              echo $((16#$hex))
            fi
          done
    done
    for f in /proc/net/udp /proc/net/udp6; do
      [[ -r "$f" ]] || continue
      awk 'NR>1 { split($2,a,":"); print a[2] }' "$f" 2>/dev/null \
        | while read -r hex; do
            [[ -z "$hex" ]] && continue
            echo $((16#$hex))
          done
    done
  ) | grep -E '^[0-9]+$' | sort -u || true
}

# Resolve PIDs for a given port (best-effort). Prefer TCP LISTEN, then UDP, then any.
resolve_pids_for_port() {
  local port="$1"
  local pids
  # Try ss with process info first (faster than lsof); extract pid=...
  pids=$( { ss -tulnpH "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]\+' | cut -d= -f2 | sort -u | xargs echo; } || true )
  if [[ -z "${pids}" ]]; then
    # Fallback to lsof
    pids=$( { lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u | xargs echo; } || true )
  fi
  if [[ -z "${pids}" ]]; then
    pids=$( { lsof -nP -t -iUDP:"$port" 2>/dev/null | sort -u | xargs echo; } || true )
  fi
  if [[ -z "${pids}" ]]; then
    pids=$( { lsof -nP -t -i :"$port" 2>/dev/null | sort -u | xargs echo; } || true )
  fi
  echo "${pids}"
}

while true; do
  # Burst mode: run N quick scans; report new ports as soon as they appear within a burst
  ports_seen_in_burst=""
  burst_end_ports=""

  for ((i=1; i<=burst_scans; i++)); do
    ports_now=$(collect_ports_once)

    # On first scan, initialize burst_end_ports
    if [[ -z "$burst_end_ports" ]]; then
      burst_end_ports="$ports_now"
    else
      # Union with previously seen ports in this burst
      burst_end_ports=$(printf "%s\n%s\n" "$burst_end_ports" "$ports_now" | grep -E '^[0-9]+$' | sort -u || true)
    fi

    # Detect brand new ports during burst (relative to prev_ports and ports already reported in this burst)
    newly_seen=$(comm -13 <(echo "$prev_ports") <(echo "$ports_now") 2>/dev/null || true)
    if [[ -n "$ports_seen_in_burst" ]]; then
      newly_seen=$(comm -23 <(echo "$newly_seen") <(echo "$ports_seen_in_burst") 2>/dev/null || true)
    fi

    if [[ -n "$newly_seen" ]]; then
      while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        ports_seen_in_burst=$(printf "%s\n%s\n" "$ports_seen_in_burst" "$p" | grep -E '^[0-9]+$' | sort -u || true)

        pids=$(resolve_pids_for_port "$p")
        port_to_pids["$p"]="${pids}"
        if [[ -n "${pids}" ]]; then
          line="[$(date)] New port opened: $p (pids: ${pids})"
        else
          line="[$(date)] New port opened: $p (pids: unknown)"
        fi
        echo "$line"
        if [[ -n "$listener_url" ]]; then
          curl -sS -m 2 -H 'Content-Type: text/plain' --data "$line" "$listener_url" >/dev/null 2>&1 || true
        fi
        if [[ "${verbose_lsof}" == "1" ]]; then
          lsof -nP -i :"$p" 2>/dev/null || true
        fi
      done <<< "$newly_seen"
    fi

    # Short sleep between scans in a burst (supports fractional seconds)
    if (( i < burst_scans )); then
      sleep "$burst_delay"
    fi
  done

  # Closed ports: present in prev snapshot but not after burst consolidation
  if [[ -n "$prev_ports" ]]; then
    closed_ports=$(comm -23 <(echo "$prev_ports") <(echo "$burst_end_ports") 2>/dev/null || true)
    if [[ -n "$closed_ports" ]]; then
      nowts=$(now_ms)
      while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        # Debounce close if requested
        if [[ "$close_grace_ms" != "0" ]]; then
          last_seen=${port_last_seen_ms[$p]:-0}
          # If we still had it recently, skip for now
          if (( nowts - last_seen < close_grace_ms )); then
            continue
          fi
        fi
        last_pids="${port_to_pids[$p]:-}"
        if [[ -n "$last_pids" ]]; then
          line="[$(date)] Port closed: $p (last pids: ${last_pids})"
        else
          line="[$(date)] Port closed: $p"
        fi
        echo "$line"
        if [[ -n "$listener_url" ]]; then
          curl -sS -m 2 -H 'Content-Type: text/plain' --data "$line" "$listener_url" >/dev/null 2>&1 || true
        fi
        unset 'port_to_pids[$p]'
        unset 'port_last_seen_ms[$p]'
      done <<< "$closed_ports"
    fi
  fi

  # Update last-seen timestamps for all currently visible ports
  nowts=$(now_ms)
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    port_last_seen_ms[$p]="$nowts"
  done <<< "$burst_end_ports"

  prev_ports="$burst_end_ports"

  # Persist snapshot
  if [[ -n "$snapshot_path" ]]; then
    echo "$prev_ports" > "$snapshot_path" 2>/dev/null || true
  fi
  sleep "$scan_interval"
done


