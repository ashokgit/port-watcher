# Docker Port Activity Monitor

Self-contained Docker environment that runs an idle container and continuously detects new TCP/UDP listening ports opened at runtime (e.g., via `docker exec`). Also detects when previously-open ports are closed and tracks the owning PID(s).

## Quick start

- One-time build and start (detached):

```bash
make run
```

- Run as a managed background service (Supervisor):

```bash
make run-sv
```

- High-fidelity mode (tuned for transient ports, still in-container only):

```bash
make run-hf
```

- Watch logs for detected ports:

```bash
make logs
```

- Open a demo HTTP server on port 5000 inside the container:

```bash
make test-http
```

- Open a UDP socket (default 5354) inside the container:

```bash
make test-udp PORT=5354
```

- Open a demo HTTP server on port 3000 (exposed on host 3000:3000):

```bash
make test-3000
```

- Kill the process listening on a port inside the container (to trigger closed-port detection):

```bash
make kill-port PORT=5000
```

- Test very short-lived sockets (transient):

```bash
make test-tcp-transient TRANSIENT_PORT=5701 TRANSIENT_MS=120
make test-udp-transient TRANSIENT_PORT=5702 TRANSIENT_MS=120
```

- Burst open/close across multiple ports quickly:

```bash
make test-tcp-burst BURST_COUNT=6 BASE_PORT=5800 HOLD_MS=120 INTERVAL_S=0.03
make test-udp-burst BURST_COUNT=6 BASE_PORT=5900 HOLD_MS=120 INTERVAL_S=0.03
```

- Exec into the container shell:

```bash
make shell
```

- Stop the stack:

```bash
make stop
```

- Clean everything (containers, orphans, and matching images):

```bash
make clean
```

## How it works

- Image is based on `node:18` and includes `ss`, `lsof`, and related tools.
- Entrypoint script `listen_ports.sh` runs inside the container and:
  - Uses a low-overhead `/proc` backend by default to enumerate TCP/UDP sockets, with optional `ss` backend.
  - Supports burst scanning: multiple quick scans per cycle to catch short-lived ports between base intervals.
  - Resolves PID(s) primarily via `ss -p` and falls back to `lsof` if needed.
  - Optionally debounces close events via a grace period to reduce flapping.
  - Persists the most recent port snapshot to `/dev/shm/portwatcher.snapshot` (configurable) for continuity.
- No Docker API access is required; everything runs in-container, watching only the container itself.

You can run the watcher directly (default `CMD`) or under Supervisor (PID 1 process supervising the watcher and restarting it on failure).

## Configuration

- Override scan interval:

```bash
make run SCAN_INTERVAL=1
```

- Burst scanning (catch short-lived opens between intervals):

```bash
make run BURST_SCANS=5 BURST_DELAY=0.03
```

- Prefer `/proc` backend (default) or `ss` backend:

```bash
make run USE_PROC=1   # default
make run USE_PROC=0   # use ss for sampling
```

- Reduce lsof verbosity (fewer log details):

```bash
make run VERBOSE_LSOF=0
```

- Close-event debounce window (milliseconds):

```bash
make run CLOSE_GRACE_MS=200
```

- Snapshot persistence path (tmpfs recommended):

```bash
make run SNAPSHOT_PATH=/dev/shm/portwatcher.snapshot
```

## Run as a background service with Supervisor

Start the container under Supervisor (manages the watcher process and restarts on failure):

```bash
make run-sv
```

Check the service is running:

```bash
docker exec portwatcher ps aux | grep -E 'supervisord|listen_ports' | cat
```

View logs (supervisor and watcher logs are forwarded to stdout/stderr):

```bash
docker logs portwatcher
```

Notes:
- The Dockerfile installs `supervisor` and includes a program config to run `/listen_ports.sh`.
- `make run-sv` starts the same container image but uses Supervisor as entrypoint.

## Manual test

In another terminal:

```bash
docker exec -it portwatcher bash
node -e "require('http').createServer((req,res)=>res.end('Hi')).listen(5000)"
```

Expected in logs:

```
[... UTC ...] New port opened: 5000 (pids: <pid>)
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
node      <pid> root ... TCP *:5000 (LISTEN)
```

Then close it:

```bash
make kill-port PORT=5000
```

Expected in logs:

```
[... UTC ...] Port closed: 5000 (last pids: <pid>)
```

## Verification (example)

End-to-end check with high-fidelity settings:

```bash
docker compose down --volumes --remove-orphans
make run-hf
make test-http              # TCP 5000
make test-udp PORT=5361     # UDP 5361
make test-3000              # TCP 3000 (host 3000:3000)
make kill-port PORT=5000
make kill-port PORT=5361
curl -s http://localhost:3000
```

Expected logs contain entries similar to:

```
[... UTC ...] New port opened: 5000 (pids: 60)
[... UTC ...] New port opened: 5361 (pids: 94)
[... UTC ...] New port opened: 3000 (pids: 133)
[... UTC ...] Port closed: 5000 (last pids: 60)
[... UTC ...] Port closed: 5361 (last pids: 94)
```

And the curl output should be:

```
Hello 3000
```

## Automated verification suite

Run a sequence of steady-state, transient, and burst tests and show recent logs:

```bash
make verify-suite
```

Other useful helpers:

```bash
make logs-since VERIFY_SINCE=30                  # show last 30s logs
make verify-port-logs PORT=5801 VERIFY_SINCE=60  # grep events for a specific port
```

## Limitations

- Detects in-container listening sockets only. It does not observe the host or other containers' namespaces.
- Detection is still sampling-based. With burst scanning and a low-overhead backend, the capture rate for short-lived sockets is high, but an ultra-short listener that opens and closes entirely between all burst samples can still be missed. Lower `BURST_DELAY`, increase `BURST_SCANS`, or reduce `SCAN_INTERVAL` to increase fidelity.

## Repository layout

```
Dockerfile
Makefile
docker-compose.yml
listen_ports.sh
README.md
```
