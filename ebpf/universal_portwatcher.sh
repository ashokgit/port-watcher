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

graceful_shutdown() {
  if [[ "${__shutdown_done:-0}" == "1" ]]; then return; fi
  __shutdown_done=1
  echo "[ebpf-fallback] Received termination signal; flushing close events before exit"
  if [[ -n "$prev_ports" ]]; then
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      last_pids="${port_to_pids[$p]:-}"
      if [[ -n "$last_pids" ]]; then
        line="[$(date)] Port closed: $p (last pids: ${last_pids})"
      else
        line="[$(date)] Port closed: $p"
      fi
      echo "$line"
      if [[ -n "$listener_url" ]]; then
        if [[ -n "$last_pids" ]]; then lpjson="[$(echo "$last_pids" | tr ' ' ',')]"; else lpjson="[]"; fi
        payload=$(printf '{"event":"close","port":%s,"last_pids":%s,"container_id":"%s","container_name":"%s","source":"shutdown-fallback"}' "$p" "$lpjson" "$container_id" "$container_name")
        curl -sS -m 2 -H 'Content-Type: application/json' --data "$payload" "$listener_url" >/dev/null 2>&1 || true
      fi
    done <<< "$prev_ports"
  fi
  exit 0
}

trap 'graceful_shutdown' TERM INT QUIT EXIT

now_ms() {
  local t
  t=$(date +%s%3N 2>/dev/null || true)
  if [[ -n "$t" && "$t" =~ ^[0-9]+$ ]]; then echo "$t"; else echo $(( $(date +%s) * 1000 )); fi
}

collect_ports_from_proc() {
  (
    for f in /proc/net/tcp /proc/net/tcp6; do
      [[ -r "$f" ]] || continue
      awk 'NR>1 { split($2,a,":"); print a[2], $4 }' "$f" 2>/dev/null \
        | while read -r hex state; do
            [[ -z "$hex" ]] && continue
            if [[ "$state" == "0A" ]]; then
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

collect_ports_once() {
  if command -v ss >/dev/null 2>&1; then
    ss -tulnH 2>/dev/null \
      | awk '{n=$5; sub(/^.*:/,"",n); if (n ~ /^[0-9]+$/) print n}' \
      | sort -u || true
  else
    collect_ports_from_proc
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

listener_url="${LISTENER_URL:-}"
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
echo "[ebpf-fallback] Starting universal watcher. Interval: ${scan_interval}s, burst_scans: ${burst_scans}, burst_delay: ${burst_delay}s"
if [[ -n "$listener_url" ]]; then
  echo "[ebpf-fallback] Listener URL configured: $listener_url"
fi

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
          line="[$(date)] New port opened: $p (pids: ${pids})"
        else
          line="[$(date)] New port opened: $p (pids: unknown)"
        fi
        echo "$line"
        if [[ -n "$listener_url" ]]; then
          if [[ -n "$pids" ]]; then pjson="[$(echo "$pids" | tr ' ' ',')]"; else pjson="[]"; fi
          payload=$(printf '{"event":"open","port":%s,"pids":%s,"container_id":"%s","container_name":"%s","source":"fallback"}' "$p" "$pjson" "$container_id" "$container_name")
          curl -sS -m 2 -H 'Content-Type: application/json' --data "$payload" "$listener_url" >/dev/null 2>&1 || true
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
          line="[$(date)] Port closed: $p (last pids: ${last_pids})"
        else
          line="[$(date)] Port closed: $p"
        fi
        echo "$line"
        if [[ -n "$listener_url" ]]; then
          if [[ -n "$last_pids" ]]; then lpjson="[$(echo "$last_pids" | tr ' ' ',')]"; else lpjson="[]"; fi
          payload=$(printf '{"event":"close","port":%s,"last_pids":%s,"container_id":"%s","container_name":"%s","source":"fallback"}' "$p" "$lpjson" "$container_id" "$container_name")
          curl -sS -m 2 -H 'Content-Type: application/json' --data "$payload" "$listener_url" >/dev/null 2>&1 || true
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


