## eBPF Port Watcher (Tracee)

This directory contains a companion, event-driven port watcher that uses eBPF via Tracee to observe `bind()`/`listen()`/`close()` and emit open/close events without polling.

It can run in two modes:
- Native eBPF using Tracee (preferred)
- Universal fallback (sampling) if eBPF is unavailable

### What it does

- Listens for bind/listen/close kernel events and correlates them to ports and PIDs.
- Emits logs similar to the polling watcher, e.g.:
  - `New port opened: 5000 (pid: 123, fd: 7)`
  - `Port closed: 5000 (last pid: 123)`
- When eBPF is not available, can fall back to an in-container sampler that uses `ss`/`lsof`.

## Prerequisites

- A Linux kernel with eBPF support (BPF, kprobes/tracepoints, BTF recommended).
- Container runtime capable of `privileged` containers, with these mounts available:
  - `/lib/modules` (ro)
  - `/usr/src` (ro)
  - `/sys/kernel/debug`
  - `/sys/fs/bpf`
- Running this on Docker Desktop for macOS is not supported for eBPF. Docker Desktop uses a LinuxKit VM where LSM/kprobe visibility and BTF availability may prevent Tracee from receiving the needed `bind`/`listen` events. Use a native Linux host for full fidelity.

## Files

- `docker-compose.ebpf.yml`: Service definition for the eBPF watcher container.
- `Dockerfile`: Minimal Alpine image that installs Tracee via a portable installer and runs under Supervisor.
- `entrypoint.sh`: Chooses Tracee (eBPF) or the universal fallback.
- `tracee_ports.sh`: Parses Tracee JSON output and prints open/close events.
- `universal_portwatcher.sh`: Sampling fallback (uses `ss`/`lsof`).
- `supervisord.tracee.conf`: Supervisor program config.

### Portable installer

- `install_tracee.sh`: Distro-agnostic installer that fetches a prebuilt Tracee (CO-RE) release and installs minimal runtime dependencies. Works on Debian/Ubuntu, Alpine, RHEL/CentOS/Fedora, and SUSE.

Usage inside any base image:

```Dockerfile
FROM ubuntu:22.04

# Minimal runtime deps. The script will install what is missing.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl tar && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY ebpf/install_tracee.sh /usr/local/bin/install_tracee.sh
RUN chmod +x /usr/local/bin/install_tracee.sh \
 && TRACEE_VERSION=latest /usr/local/bin/install_tracee.sh

# Optional: use our watcher scripts
COPY ebpf/tracee_ports.sh /usr/local/bin/tracee_ports.sh
COPY ebpf/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/tracee_ports.sh /usr/local/bin/entrypoint.sh
```

At runtime, you still need `--privileged`, `pid: host`, and mounts shown below.

## Quick start (Linux host)

From the repo root:

```bash
make ebpf-run     # build and start the eBPF watcher
make ebpf-logs    # tail logs
# ... later
make ebpf-stop    # stop the watcher
```

Build the eBPF watcher image (portable installer is the default):

```bash
DOCKER_BUILDKIT=1 docker build -f ebpf/Dockerfile ebpf \
  --build-arg TRACEE_VERSION=latest \
  -t ebpf-portwatcher:portable
```

Expected first log:

```
[ebpf] Starting Tracee-based watcher. events=bind,security_socket_bind,listen,close
```

### Generate test events

Open/close listeners in any container or on the host; with `pid: host` and `privileged`, Tracee will see host-wide events.

- Example (in another container):

```bash
docker run --rm -d --name tcp-test alpine sh -c "apk add --no-cache busybox-extras >/dev/null && nc -lk -p 7777"
docker run --rm -d --name udp-test alpine sh -c "apk add --no-cache busybox-extras >/dev/null && nc -luk -p 8888"
```

- Example (host):

```bash
python3 - <<'PY'
import socket, time
s=socket.socket(); s.setsockopt(1,2,1); s.bind(('0.0.0.0', 5000)); s.listen(1)
u=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.bind(('0.0.0.0', 5361))
print('listening...'); time.sleep(2)
s.close(); u.close(); print('closed')
PY
```

Watch the eBPF watcher logs:

```bash
make ebpf-logs
# or directly
docker compose -f ebpf/docker-compose.ebpf.yml logs -f
```

You should see lines like:

```
[... UTC ...] New port opened: 5000 (pid: <pid>, fd: <fd>)
[... UTC ...] New port opened: 5361 (pid: <pid>, fd: <fd>)
[... UTC ...] Port closed: 5000 (last pid: <pid>)
```

## Environment variables

Set via `docker-compose.ebpf.yml` or when invoking compose.

- `TRACE_EBPF_EVENTS`
  - Default: `bind,security_socket_bind,listen,close`
  - Events to request from Tracee. If your Tracee/kernel do not support all of these, you can try `bind,close` or just `security_socket_bind,close`.

- `EBPF_FALLBACK`
  - Default: `1`
  - Allow falling back to the universal sampler if eBPF is not possible.

- `EBPF_FORCE_FALLBACK`
  - Default: `0`
  - Force running the universal sampler even if Tracee is available.

- `EBPF_ONLY`
  - Default: not set (treated as `0`)
  - If `1`, run eBPF only; exit if Tracee is unavailable.

Example overrides:

```bash
TRACE_EBPF_EVENTS="bind,close" EBPF_FALLBACK=0 make ebpf-run
```

## How it works

1. Supervisor runs `entrypoint.sh`.
2. `entrypoint.sh` prefers Tracee; sets `LIBBPFGO_OSRELEASE_FILE=/etc/os-release-host` and execs `tracee_ports.sh`.
3. `tracee_ports.sh` starts Tracee with JSON output and parses each event to correlate `pid:fd -> port` and report opens/closes.
4. If Tracee cannot run or events are not available, the universal sampler (`universal_portwatcher.sh`) can be used.

## Troubleshooting

- No `New port opened` lines appear, but you see `[ebpf] Starting Tracee-based watcher`:
  - You might be on Docker Desktop macOS or a kernel/LSM configuration where `bind`/`listen` are not observable. Try on a native Linux host.
  - Reduce events to `bind,close`: `TRACE_EBPF_EVENTS="bind,close" make ebpf-run`.
  - Ensure required mounts exist and the container is `privileged` with `pid: host`.

- Verify Tracee can run and see events inside the container:

```bash
docker exec ebpf-portwatcher sh -lc 'timeout 5 /tracee/tracee --output json --events bind,close >/tmp/out 2>/tmp/err || true; echo ---ERR---; sed -n "1,60p" /tmp/err; echo ---SAMPLE---; sed -n "1,40p" /tmp/out'
```

- Check kernel and host info from inside the container:

```bash
docker exec ebpf-portwatcher sh -lc 'uname -a; cat /etc/os-release-host || true; ls -l /sys/fs/bpf || true; ls -l /sys/kernel/debug || true'
```

- Force universal fallback (sampling) to validate pipeline end-to-end even without eBPF:

```bash
EBPF_FORCE_FALLBACK=1 make ebpf-run
make ebpf-logs
```

## Known limitations

- Docker Desktop on macOS: The LinuxKit VM may not report the necessary events; expect the eBPF watcher to be silent for `bind`/`listen` while `close` and unrelated events may still appear. Use a native Linux host for accurate eBPF testing.
- This watcher observes the host namespace. In hardened or restricted environments, additional capabilities or different mounts may be required.

## Service controls

```bash
make ebpf-run     # start
make ebpf-logs    # tail logs
make ebpf-stop    # stop
```

Alternatively, direct compose:

```bash
docker compose -f ebpf/docker-compose.ebpf.yml up -d
docker compose -f ebpf/docker-compose.ebpf.yml logs -f
docker compose -f ebpf/docker-compose.ebpf.yml down
```

## Security notes

- The service runs as `privileged: true` with `pid: host` to access kernel events and host namespaces. Restrict usage to trusted, dedicated observability hosts.
- No host ports are exposed; logs are emitted to stdout.

## License / Credits

- Built around `aquasec/tracee` for eBPF event collection.
- This directory’s scripts adapt Tracee JSON for simple port open/close reporting.


