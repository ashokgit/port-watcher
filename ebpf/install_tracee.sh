#!/usr/bin/env bash
set -euo pipefail

# Portable installer for Tracee (CO-RE) eBPF collector
# - Works on common base images (Debian/Ubuntu, Alpine, RHEL/CentOS/Fedora, SUSE)
# - Installs minimal runtime deps (curl/wget, tar, ca-certificates, jq, libelf, zlib)
# - Downloads a prebuilt Tracee release tarball and installs the binary
#
# Environment variables:
# - TRACEE_VERSION: tag like "v0.15.0"; default: "latest"
# - TRACEE_DEST: install location for the tracee binary (default: /tracee/tracee)
# - TRACEE_URL_OVERRIDE: fully-qualified URL to a tarball to use instead of GitHub release
# - INSTALL_JQ: if set to 0, skip installing jq (default: 1)
# - INSTALL_LIBS: if set to 0, skip installing libelf/zlib (default: 1)
#
# Notes:
# - Container must run with required privileges for eBPF; this script only installs binaries.

TRACEE_VERSION="${TRACEE_VERSION:-latest}"
TRACEE_DEST="${TRACEE_DEST:-/tracee/tracee}"
TRACEE_URL_OVERRIDE="${TRACEE_URL_OVERRIDE:-}"
INSTALL_JQ="${INSTALL_JQ:-1}"
INSTALL_LIBS="${INSTALL_LIBS:-1}"

log() { echo "[install-tracee] $*" >&2; }

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
  if command -v apk >/dev/null 2>&1; then echo apk; return; fi
  if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
  if command -v microdnf >/dev/null 2>&1; then echo microdnf; return; fi
  if command -v yum >/dev/null 2>&1; then echo yum; return; fi
  if command -v zypper >/dev/null 2>&1; then echo zypper; return; fi
  echo none
}

ensure_packages() {
  local pm="$1"; shift || true
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      # core tools
      apt-get install -y --no-install-recommends ca-certificates curl tar
      if [[ "$INSTALL_JQ" != "0" ]]; then apt-get install -y --no-install-recommends jq; fi
      if [[ "$INSTALL_LIBS" != "0" ]]; then apt-get install -y --no-install-recommends libelf1 zlib1g; fi
      rm -rf /var/lib/apt/lists/*
      ;;
    apk)
      apk add --no-cache ca-certificates curl tar
      if [[ "$INSTALL_JQ" != "0" ]]; then apk add --no-cache jq; fi
      if [[ "$INSTALL_LIBS" != "0" ]]; then apk add --no-cache libelf zlib; fi
      ;;
    dnf)
      dnf install -y ca-certificates curl tar
      if [[ "$INSTALL_JQ" != "0" ]]; then dnf install -y jq; fi
      if [[ "$INSTALL_LIBS" != "0" ]]; then dnf install -y elfutils-libelf zlib; fi
      dnf clean all -y || true
      ;;
    microdnf)
      microdnf install -y ca-certificates curl tar
      if [[ "$INSTALL_JQ" != "0" ]]; then microdnf install -y jq; fi
      if [[ "$INSTALL_LIBS" != "0" ]]; then microdnf install -y elfutils-libelf zlib; fi
      microdnf clean all || true
      ;;
    yum)
      yum install -y ca-certificates curl tar
      if [[ "$INSTALL_JQ" != "0" ]]; then yum install -y jq; fi
      if [[ "$INSTALL_LIBS" != "0" ]]; then yum install -y elfutils-libelf zlib; fi
      yum clean all -y || true
      ;;
    zypper)
      zypper --non-interactive refresh || true
      zypper --non-interactive install --no-recommends ca-certificates curl tar
      if [[ "$INSTALL_JQ" != "0" ]]; then zypper --non-interactive install --no-recommends jq; fi
      if [[ "$INSTALL_LIBS" != "0" ]]; then zypper --non-interactive install --no-recommends libelf1 libz1 || true; fi
      ;;
    *)
      log "Unknown package manager; assuming dependencies already present"
      ;;
  esac
}

arch_triplet() {
  local m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "$m" ;;
  esac
}

download_tracee_tarball() {
  local out_tar="$1"
  local arch="$(arch_triplet)"

  if [[ -n "$TRACEE_URL_OVERRIDE" ]]; then
    curl -fsSL "$TRACEE_URL_OVERRIDE" -o "$out_tar" && return 0 || true
  fi

  local base="https://github.com/aquasecurity/tracee/releases"
  local tag_path
  if [[ "$TRACEE_VERSION" == "latest" ]]; then tag_path="latest"; else tag_path="download/${TRACEE_VERSION}"; fi

  # Try a sequence of likely asset names to be resilient across releases
  local candidates=(
    "${base}/${tag_path}/tracee.tar.gz"
    "${base}/${tag_path}/tracee-${arch}.tar.gz"
    "${base}/${tag_path}/tracee_linux_${arch}.tar.gz"
    "${base}/${tag_path}/tracee-${arch}-linux.tar.gz"
  )

  for url in "${candidates[@]}"; do
    log "Trying ${url}"
    if curl -fsSL "$url" -o "$out_tar"; then
      log "Downloaded: $url"
      return 0
    fi
  done

  log "Failed to download Tracee tarball for arch=${arch} version=${TRACEE_VERSION}"
  return 1
}

install_tracee_binary() {
  local dest="$1"
  local tmpdir; tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  mkdir -p "$tmpdir"

  local tarball="$tmpdir/tracee.tgz"
  download_tracee_tarball "$tarball"

  tar -xzf "$tarball" -C "$tmpdir"
  # Find a file named exactly 'tracee' or path ending with '/tracee'
  local found
  found="$(
    { find "$tmpdir" -type f -name tracee -perm -u+x -print 2>/dev/null || true; } |
    head -n1
  )"
  if [[ -z "$found" ]]; then
    # Sometimes tarball contains root without exec bit; try to locate and chmod
    found="$(find "$tmpdir" -type f -name tracee -print 2>/dev/null | head -n1 || true)"
    if [[ -n "$found" ]]; then chmod +x "$found"; fi
  fi
  if [[ -z "$found" ]]; then
    log "tracee binary not found in the tarball"
    return 1
  fi

  install -d "$(dirname "$dest")"
  install -m 0755 "$found" "$dest"
  log "Installed tracee to $dest"

  # Also symlink into PATH for convenience
  if command -v install >/dev/null 2>&1; then
    install -D -m 0755 "$dest" /usr/local/bin/tracee || cp -f "$dest" /usr/local/bin/tracee || true
  else
    cp -f "$dest" /usr/local/bin/tracee 2>/dev/null || true
  fi
}

main() {
  local pm; pm="$(detect_pkg_manager)"
  ensure_packages "$pm"

  install_tracee_binary "$TRACEE_DEST"

  # Print version for verification (best-effort)
  if /usr/local/bin/tracee --version >/dev/null 2>&1; then
    /usr/local/bin/tracee --version || true
  elif "$TRACEE_DEST" --version >/dev/null 2>&1; then
    "$TRACEE_DEST" --version || true
  fi

  log "Done. Ensure container runs privileged and mounts required paths for eBPF."
}

main "$@"


