# Docker Port Activity Monitor

Self-contained Docker environment that runs an idle container and continuously detects new TCP/UDP listening ports opened at runtime (e.g., via `docker exec`). Also detects when previously-open ports are closed and tracks the owning PID(s).

## Quick start

- One-time build and start (detached):

```bash
make run
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
- Entrypoint script `listen_ports.sh` scans every `SCAN_INTERVAL` seconds (default 2) and logs:
  - Newly opened ports with timestamps, plus the owning process via `lsof`. It includes PID(s) for the port.
  - Ports that were present previously but disappeared since the last scan as "Port closed" events, including the last known PID(s).
- No Docker API access is required.

## Configuration

- Override scan interval:

```bash
make run SCAN_INTERVAL=1
```

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

End-to-end check with faster scan interval:

```bash
docker compose down --volumes --remove-orphans
make run SCAN_INTERVAL=1
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

## Limitations

- Ports that open and close between scans may be missed.
- Detects in-container listening sockets only.

## Repository layout

```
Dockerfile
Makefile
docker-compose.yml
listen_ports.sh
README.md
```
