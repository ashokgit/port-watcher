#!/usr/bin/env bash
set -euo pipefail

# Universal polling fallback for port open/close events
# Emits logs compatible with listen_ports.sh

scan_interval="${SCAN_INTERVAL:-1}"
burst_scans="${BURST_SCANS:-3}"
burst_delay="${BURST_DELAY:-0.05}"
close_grace_ms="${CLOSE_GRACE_MS:-0}"
verbose_lsof="${VERBOSE_LSOF:-0}"

declare -A port_to_pids
declare -A port_last_seen_ms
prev_ports=""

now_ms() {
  local t
  t=$(date +%s%3N 2>/dev/null || true)
  if [[ -n "$t" && "$t" =~ ^[0-9]+$ ]]; then echo "$t"; else echo $(( $(date +%s) * 1000 )); fi
}

collect_ports_once() {
  if command -v ss >/dev/null 2>&1; then
    ss -tulnH 2>/dev/null \
      | awk '{n=$5; sub(/^.*:/,"",n); if (n ~ /^[0-9]+$/) print n}' \
      | sort -u || true
  else
    { cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk 'NR>1 { split($2,a,":"); if ($4=="0A") print strtonum("0x" a[2]) }'; \
      cat /proc/net/udp /proc/net/udp6 2>/dev/null | awk 'NR>1 { split($2,a,":"); print strtonum("0x" a[2]) }'; } \
      | grep -E '^[0-9]+$' | sort -u || true
  fi
}

resolve_pids_for_port() {
  local port="$1"
  local pids
  pids=$( { ss -tulnpH "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]\+' | cut -d= -f2 | sort -u | xargs echo; } || true )
  if [[ -z "$pids" ]]; then
    pids=$( { lsof -nP -t -i :"$port" 2>/dev/null | sort -u | xargs echo; } || true )
  fi
  echo "$pids"
}

echo "[ebpf-fallback] Starting universal watcher. Interval: ${scan_interval}s, burst_scans: ${burst_scans}, burst_delay: ${burst_delay}s"

while true; do
  ports_seen_in_burst=""
  burst_end_ports=""

  for ((i=1; i<=burst_scans; i++)); do
    ports_now=$(collect_ports_once)

    if [[ -z "$burst_end_ports" ]]; then
      burst_end_ports="$ports_now"
    else
      burst_end_ports=$(printf "%s\n%s\n" "$burst_end_ports" "$ports_now" | grep -E '^[0-9]+$' | sort -u || true)
    fi

    newly_seen=$(comm -13 <(echo "$prev_ports") <(echo "$ports_now") 2>/dev/null || true)
    if [[ -n "$ports_seen_in_burst" ]]; then
      newly_seen=$(comm -23 <(echo "$newly_seen") <(echo "$ports_seen_in_burst") 2>/dev/null || true)
    fi

    if [[ -n "$newly_seen" ]]; then
      while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        ports_seen_in_burst=$(printf "%s\n%s\n" "$ports_seen_in_burst" "$p" | grep -E '^[0-9]+$' | sort -u || true)
        pids=$(resolve_pids_for_port "$p")
        port_to_pids["$p"]="$pids"
        if [[ -n "$pids" ]]; then
          echo "[$(date)] New port opened: $p (pids: ${pids})"
        else
          echo "[$(date)] New port opened: $p (pids: unknown)"
        fi
        if [[ "$verbose_lsof" == "1" ]]; then lsof -nP -i :"$p" 2>/dev/null || true; fi
      done <<< "$newly_seen"
    fi

    if (( i < burst_scans )); then sleep "$burst_delay"; fi
  done

  if [[ -n "$prev_ports" ]]; then
    closed_ports=$(comm -23 <(echo "$prev_ports") <(echo "$burst_end_ports") 2>/dev/null || true)
    if [[ -n "$closed_ports" ]]; then
      nowts=$(now_ms)
      while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        if [[ "$close_grace_ms" != "0" ]]; then
          last_seen=${port_last_seen_ms[$p]:-0}
          if (( nowts - last_seen < close_grace_ms )); then continue; fi
        fi
        last_pids="${port_to_pids[$p]:-}"
        if [[ -n "$last_pids" ]]; then
          echo "[$(date)] Port closed: $p (last pids: ${last_pids})"
        else
          echo "[$(date)] Port closed: $p"
        fi
        unset 'port_to_pids[$p]'
        unset 'port_last_seen_ms[$p]'
      done <<< "$closed_ports"
    fi
  fi

  nowts=$(now_ms)
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    port_last_seen_ms[$p]="$nowts"
  done <<< "$burst_end_ports"

  prev_ports="$burst_end_ports"
  sleep "$scan_interval"
done


