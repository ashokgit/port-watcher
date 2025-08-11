#!/usr/bin/env bash
set -euo pipefail

scan_interval="${SCAN_INTERVAL:-2}"

prev_ports=""
declare -A port_to_pids

echo "[portwatcher] Starting listener. Scan interval: ${scan_interval}s"

while true; do
  # Get current listening ports (TCP/UDP), extract port numbers, unique & sorted
  # -n: don't resolve names, -l: listening, -t: TCP, -u: UDP
  ports=$(ss -tulnH | awk '{print $5}' | sed 's/.*://g' | grep -E '^[0-9]+$' | sort -u || true)

  if [[ -n "$prev_ports" ]]; then
    # Ports present now but not in previous snapshot
    new_ports=$(comm -13 <(echo "$prev_ports") <(echo "$ports") || true)
    if [[ -n "$new_ports" ]]; then
      while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        # Prefer listening TCP PIDs, then UDP, then generic (ignore non-zero exits)
        pids=$( { lsof -nP -t -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | sort -u | xargs echo; } || true )
        if [[ -z "${pids}" ]]; then
          pids=$( { lsof -nP -t -iUDP:"$p" 2>/dev/null | sort -u | xargs echo; } || true )
        fi
        if [[ -z "${pids}" ]]; then
          pids=$( { lsof -nP -t -i :"$p" 2>/dev/null | sort -u | xargs echo; } || true )
        fi

        port_to_pids["$p"]="${pids}"
        if [[ -n "${pids}" ]]; then
          echo "[$(date)] New port opened: $p (pids: ${pids})"
        else
          echo "[$(date)] New port opened: $p (pids: unknown)"
        fi
        lsof -nP -i :"$p" 2>/dev/null || true
      done <<< "$new_ports"
    fi

    # Ports that disappeared since last snapshot
    closed_ports=$(comm -23 <(echo "$prev_ports") <(echo "$ports") || true)
    if [[ -n "$closed_ports" ]]; then
      while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        last_pids="${port_to_pids[$p]:-}"
        if [[ -n "$last_pids" ]]; then
          echo "[$(date)] Port closed: $p (last pids: ${last_pids})"
        else
          echo "[$(date)] Port closed: $p"
        fi
        unset 'port_to_pids[$p]'
      done <<< "$closed_ports"
    fi
  fi

  prev_ports="$ports"
  sleep "$scan_interval"
done


