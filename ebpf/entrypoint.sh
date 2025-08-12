#!/usr/bin/env bash
set -euo pipefail

# Chooses Tracee-based eBPF or universal fallback depending on env and runtime

EBPF_ONLY="${EBPF_ONLY:-0}"
FALLBACK_ENABLED="${EBPF_FALLBACK:-1}"
EBPF_FORCE_FALLBACK="${EBPF_FORCE_FALLBACK:-0}"

try_tracee() {
  if command -v /tracee/tracee >/dev/null 2>&1; then
    export LIBBPFGO_OSRELEASE_FILE="/etc/os-release-host"
    exec /usr/local/bin/tracee_ports.sh
  fi
  return 1
}

try_fallback() {
  if [[ "${FALLBACK_ENABLED}" == "1" ]]; then
    exec /usr/local/bin/universal_portwatcher.sh
  fi
  return 1
}

if [[ "${EBPF_FORCE_FALLBACK}" == "1" ]]; then
  try_fallback || { echo "[entrypoint] EBPF_FORCE_FALLBACK=1 but fallback unavailable" >&2; exit 1; }
fi

if [[ "${EBPF_ONLY}" == "1" ]]; then
  try_tracee
  echo "[entrypoint] eBPF_ONLY=1 but tracee is unavailable; exiting" >&2
  exit 1
fi

# Prefer Tracee; if it fails to exec, fallback to universal polling
try_tracee || try_fallback || { echo "[entrypoint] No suitable watcher available" >&2; exit 1; }


