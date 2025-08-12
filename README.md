# Docker Port Activity Monitor (+ Listener API)

Self-contained multi-container setup for observing port open/close activity and forwarding events as JSON to a central Listener API for logging/consumption.

What's included:

- `portwatcher` – sampling-based watcher that detects TCP/UDP port opens/closes inside its container (via `ss`/`lsof`). Sends JSON to the Listener if configured.
- `listner-api` – FastAPI service that accepts events over HTTP (`POST /ingest`) and persists them to `/logs/portwatcher.log`.
- `ebpf/` – optional event-driven watcher (Tracee-based) with a universal fallback; also forwards JSON to the Listener.
- `nodejs-tester` and `python-tester` – minimal containers that run the watcher by default. You can exec into them to open/close ports manually to generate events.

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

## Services and how they work

- `portwatcher` image is based on `node:18` and includes `ss`, `lsof`, and related tools. Entrypoint script `listen_ports.sh` runs inside the container and:
  - Uses the `ss` backend by default to enumerate TCP/UDP sockets, with an optional `/proc` backend.
  - Supports burst scanning: multiple quick scans per cycle to catch short-lived ports between base intervals.
  - Resolves PID(s) primarily via `ss -p` and falls back to `lsof` if needed.
  - Optionally debounces close events via a grace period to reduce flapping.
  - Persists the most recent port snapshot to `/dev/shm/portwatcher.snapshot` (configurable) for continuity.
- When `LISTENER_URL` is set (defaults to `http://listner-api:8080/ingest` in `docker-compose.yml`), it POSTS JSON events to the Listener API.
- No Docker API access is required; each watcher only observes its own container's namespace.

- `listner-api` is a FastAPI app that exposes:
  - `GET /healthz` – health check
  - `POST /ingest` – accepts JSON or text (JSON preferred) and appends a log line to `/logs/portwatcher.log`

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

- Prefer `ss` backend (default) or `/proc` backend:

```bash
make run USE_PROC=0   # default (ss)
make run USE_PROC=1   # use /proc backend
```

- lsof verbosity (default off):

```bash
make run VERBOSE_LSOF=1   # enable detailed lsof dump on new ports
```

- Filter to specific ports only (comma/space separated list and/or ranges):

```bash
# watch only ports 3000, 5000-5002, and 7001
make run WATCH_PORTS="3000,5000-5002 7001"

# alias env name supported as well
make run DESIRED_PORTS="80 443 8080"
```

See `docker-compose.yml` for commented examples under `portwatcher`, `ebpf-portwatcher`, `nodejs-tester`, and `python-tester` services.

- Close-event debounce window (milliseconds):

```bash
make run CLOSE_GRACE_MS=200
```

- Snapshot persistence path (tmpfs recommended):

```bash
make run SNAPSHOT_PATH=/dev/shm/portwatcher.snapshot

- Listener URL and container identity (auto-detected, can override):

```bash
# Where watchers POST events (defaults to the service name URL)
LISTENER_URL=http://listner-api:8080/ingest
# Optionally override container identity presented in JSON
CONTAINER_ID=<id> CONTAINER_NAME=<name>
```

## Listener API

- Endpoint: `POST /ingest`
- Content-Type: `application/json`
- Example payloads:

```json
{"event":"open","port":5000,"pids":[123],"container_id":"<cid>","container_name":"<name>","source":"polling"}
{"event":"close","port":5000,"last_pids":[123],"container_id":"<cid>","container_name":"<name>","source":"polling"}
```

The Listener prefixes each entry with a server-side `ts` field and writes a compact JSON line to `/logs/portwatcher.log` (mounted volume).

Common ops:

```bash
# Clear listener log
docker exec listner-api sh -lc '> /logs/portwatcher.log'
# Tail log
docker exec -it listner-api sh -lc 'tail -f /logs/portwatcher.log'
```

## Test with the provided testers

Bring up the testers (already included in `docker compose up`): `nodejs-tester` and `python-tester` run the watcher by default and forward events to the Listener.

- Node.js tester (open/close port 7001):

```bash
docker exec -it nodejs-tester bash
node -e "require('http').createServer(()=>{}).listen(7001)"   # open
# in another terminal
docker exec nodejs-tester bash -lc 'pid=$(lsof -t -i :7001 || true); [ -n "$pid" ] && kill $pid || true'  # close
```

- Python tester (open/close port 7002):

```bash
docker exec -it python-tester bash
python - <<'PY'
import http.server, socketserver
PORT=7002
httpd=socketserver.TCPServer(('', PORT), http.server.SimpleHTTPRequestHandler)
httpd.serve_forever()
PY
# in another terminal
docker exec python-tester bash -lc 'pid=$(lsof -t -i :7002 || true); [ -n "$pid" ] && kill $pid || true'
```

Sample JSON lines you should see in the Listener log:

```json
{"ts":"...Z","event":"open","port":7001,"pids":[8],"container_id":"<cid>","container_name":"nodejs-tester","source":"fallback"}
{"ts":"...Z","event":"close","port":7001,"last_pids":[8],"container_id":"<cid>","container_name":"nodejs-tester","source":"fallback"}
```
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

### Graceful shutdown behavior

When the watcher container is stopped (SIGTERM/SIGINT/QUIT — e.g., `docker stop`), it flushes "close" events for all currently tracked open ports before exiting. This ensures consumers receive a final state update even if the container exits while listeners are still open.

- Sources in emitted events:
  - polling watcher (`listen_ports.sh`): `"source":"shutdown"`
  - universal fallback (eBPF sampler): `"source":"shutdown-fallback"`
  - Tracee eBPF watcher: `"source":"shutdown-ebpf"`

Quick test:

```bash
docker compose up -d --build

# Open a demo port inside the watcher container
docker exec -it portwatcher bash -lc "node -e \"require('http').createServer(()=>{}).listen(5000)\""

# Stop the container to trigger graceful shutdown
docker stop portwatcher

# Verify a close event with source=shutdown was recorded
docker exec listner-api sh -lc "tail -n 100 /logs/portwatcher.log | grep '\"event\":\"close\"' | tail -n 1"
```

### Event-driven alternatives (eBPF)

For near-zero-overhead and lossless detection, a companion eBPF watcher is available under `ebpf/` using Tracee. It listens to `bind()`/`listen()`/`close()` and emits events as ports are opened/closed (no polling).

- Tracee: runtime tracing focused on security/forensics (used here)
- Cilium Tetragon: security observability and runtime enforcement
- Falco: CNCF runtime security with an eBPF driver

Run the eBPF watcher (requires Linux with eBPF support; Docker Desktop on macOS will not expose kernel eBPF from the host):

```bash
make ebpf-run
# watch logs
make ebpf-logs
# stop
make ebpf-stop
```

Notes:
- The eBPF service runs under Supervisor inside `ebpf/` image and logs to stdout.
- The container is started with `privileged: true` and mounts `/lib/modules`, `/usr/src`, `/sys/kernel/debug`, `/sys/fs/bpf` for Tracee.
- When `LISTENER_URL` is set, eBPF watcher also POSTs JSON events with the same schema (source set to `"ebpf"` or `"fallback"`).

## Limitations

- Detects in-container listening sockets only. It does not observe the host or other containers' namespaces.
- Detection is still sampling-based. With burst scanning and a low-overhead backend, the capture rate for short-lived sockets is high, but an ultra-short listener that opens and closes entirely between all burst samples can still be missed. Lower `BURST_DELAY`, increase `BURST_SCANS`, or reduce `SCAN_INTERVAL` to increase fidelity.

### Most optimal setups (resource-wise)

- **Linux (preferred) — eBPF-only, host-wide, lossless**
  - Run only the eBPF watcher with the Listener; disable per-container polling to avoid duplicate events.
  - Recommended env for `ebpf-portwatcher` in `docker-compose.yml`:
    ```yaml
    services:
      ebpf-portwatcher:
        environment:
          TRACE_EBPF_EVENTS: "bind,close"   # minimal event set
          TRACEE_ARGS: ""                  # optional extra filters (e.g., --container)
          EBPF_ONLY: "1"
          EBPF_FALLBACK: "0"
          LISTENER_URL: "http://listner-api:8080/ingest"
    ```
  - Start only the Listener and eBPF services:
    ```bash
    docker compose up -d listner-api ebpf-portwatcher
    ```

- **macOS Docker Desktop or restricted Linux — lightweight polling per container**
  - Use `/proc` backend and modest interval; filter ports to reduce work.
  - Recommended env for `portwatcher`:
    ```yaml
    services:
      portwatcher:
        environment:
          USE_PROC: "1"
          SCAN_INTERVAL: "3"    # 3–5 keeps CPU low
          BURST_SCANS: "1"
          VERBOSE_LSOF: "0"
          CLOSE_GRACE_MS: "200"  # debounce close/reopen
          WATCH_PORTS: "80 443 3000-3005"  # narrow scope
          LISTENER_URL: "http://listner-api:8080/ingest"
    ```

- **High-fidelity (transient-heavy) without eBPF**
  - Polling with bursts (expect higher CPU):
    ```yaml
    services:
      portwatcher:
        environment:
          USE_PROC: "1"
          SCAN_INTERVAL: "1"
          BURST_SCANS: "5"
          BURST_DELAY: "0.02"
          CLOSE_GRACE_MS: "200"
    ```

#### Guidelines

- Do not run both eBPF and polling for the same scope; it doubles events.
- Keep `VERBOSE_LSOF=0`; rely on `ss -p` first.
- Prefer `WATCH_PORTS`/`DESIRED_PORTS` to reduce scanning work.
- On Linux, eBPF-only gives lowest CPU and lossless results; on macOS, optimized polling is the best option.

## Repository layout

```
Dockerfile                     # portwatcher image (sampling watcher)
docker-compose.yml             # full stack: watcher, listener API, testers
listen_ports.sh                # sampling watcher script (JSON forwarding)
listner-api/                   # FastAPI service (POST /ingest -> /logs/portwatcher.log)
ebpf/                          # Tracee-based watcher + universal fallback
nodejs-tester/                 # Node-based test container (watcher pre-wired)
python-tester/                 # Python-based test container (watcher pre-wired)
Makefile
README.md
```
