.PHONY: help build run run-hf run-ss run-proc run-sv stop clean logs logs-since exec shell \
        test-http test-udp test-3000 kill-port \
        test-tcp-transient test-udp-transient test-tcp-burst test-udp-burst \
        verify-port-logs verify-suite

PROJECT := portwatcher
SCAN_INTERVAL ?= 2
BURST_SCANS ?= 1
BURST_DELAY ?= 0.05
VERBOSE_LSOF ?= 1
USE_PROC ?= 1
CLOSE_GRACE_MS ?= 0
SNAPSHOT_PATH ?= /dev/shm/portwatcher.snapshot

help:
	@echo "Targets:"
	@echo "  build        Build the Docker image"
	@echo "  run          Build and start the stack (detached)"
	@echo "  run-hf       Start with high-fidelity detection settings"
	@echo "  run-ss       Start using ss backend (USE_PROC=0)"
	@echo "  run-proc     Start using /proc backend (USE_PROC=1)"
	@echo "  run-sv       Start under Supervisor (supervisord)"
	@echo "  logs         Tail container logs"
	@echo "  logs-since   Show recent logs (VERIFY_SINCE, default 15s)"
	@echo "  exec         Exec into the container with bash"
	@echo "  shell        Alias for exec"
	@echo "  stop         Stop the stack"
	@echo "  clean        Stop and remove containers, volumes, and images"
	@echo "  test-http    Open a Node HTTP server on port 5000 inside the container"
	@echo "  test-udp     Open a UDP socket on port $(PORT) inside the container (default 5354)"
	@echo "  test-3000    Open a Node HTTP server on port 3000 inside the container (host exposed 3000:3000)"
	@echo "  kill-port    Kill the process listening on PORT inside the container (PORT=<n>)"
	@echo "  test-tcp-transient   Open a TCP listener briefly then close (TRANSIENT_PORT, TRANSIENT_MS)"
	@echo "  test-udp-transient   Open a UDP socket briefly then close (TRANSIENT_PORT, TRANSIENT_MS)"
	@echo "  test-tcp-burst       Open/close multiple TCP ports quickly (BURST_COUNT, BASE_PORT, HOLD_MS, INTERVAL_S)"
	@echo "  test-udp-burst       Open/close multiple UDP ports quickly (BURST_COUNT, BASE_PORT, HOLD_MS, INTERVAL_S)"
	@echo "  verify-port-logs     Grep recent logs for a specific PORT (VERIFY_SINCE, PORT)"
	@echo "  verify-suite         Run a sequence of tests and show recent logs"

build:
	SCAN_INTERVAL=$(SCAN_INTERVAL) docker compose build

run: build
	SCAN_INTERVAL=$(SCAN_INTERVAL) \
	BURST_SCANS=$(BURST_SCANS) BURST_DELAY=$(BURST_DELAY) \
	VERBOSE_LSOF=$(VERBOSE_LSOF) USE_PROC=$(USE_PROC) \
	CLOSE_GRACE_MS=$(CLOSE_GRACE_MS) SNAPSHOT_PATH=$(SNAPSHOT_PATH) \
	docker compose up -d
	@echo "\nContainer is running. Use 'make logs' to observe new ports."

run-hf: build
	@echo "Starting high-fidelity mode: SCAN_INTERVAL=0.5 BURST_SCANS=10 BURST_DELAY=0.02 USE_PROC=1 CLOSE_GRACE_MS=200 VERBOSE_LSOF=0"
	SCAN_INTERVAL=0.5 BURST_SCANS=10 BURST_DELAY=0.02 \
	VERBOSE_LSOF=0 USE_PROC=1 CLOSE_GRACE_MS=200 SNAPSHOT_PATH=$(SNAPSHOT_PATH) \
	docker compose up -d
	@echo "\nContainer is running in high-fidelity mode. Use 'make logs'."

run-ss: build
	@echo "Starting with ss backend (USE_PROC=0)"
	SCAN_INTERVAL=$(SCAN_INTERVAL) BURST_SCANS=$(BURST_SCANS) BURST_DELAY=$(BURST_DELAY) \
	VERBOSE_LSOF=$(VERBOSE_LSOF) USE_PROC=0 CLOSE_GRACE_MS=$(CLOSE_GRACE_MS) SNAPSHOT_PATH=$(SNAPSHOT_PATH) \
	docker compose up -d

run-proc: build
	@echo "Starting with /proc backend (USE_PROC=1)"
	SCAN_INTERVAL=$(SCAN_INTERVAL) BURST_SCANS=$(BURST_SCANS) BURST_DELAY=$(BURST_DELAY) \
	VERBOSE_LSOF=$(VERBOSE_LSOF) USE_PROC=1 CLOSE_GRACE_MS=$(CLOSE_GRACE_MS) SNAPSHOT_PATH=$(SNAPSHOT_PATH) \
	docker compose up -d

# Run under Supervisor by overriding the container command
run-sv: build
	@echo "Starting under Supervisor (supervisord)"
	SCAN_INTERVAL=$(SCAN_INTERVAL) BURST_SCANS=$(BURST_SCANS) BURST_DELAY=$(BURST_DELAY) \
	VERBOSE_LSOF=$(VERBOSE_LSOF) USE_PROC=$(USE_PROC) CLOSE_GRACE_MS=$(CLOSE_GRACE_MS) SNAPSHOT_PATH=$(SNAPSHOT_PATH) \
	docker compose up -d --force-recreate --no-deps
	# Restart container under supervisord entrypoint (publishes service ports)
	docker stop $(PROJECT) >/dev/null 2>&1 || true
	docker rm $(PROJECT) >/dev/null 2>&1 || true
	docker compose run -d --service-ports --name $(PROJECT) --entrypoint /usr/bin/supervisord portwatcher -c /etc/supervisor/conf.d/portwatcher.conf

logs:
	docker compose logs -f | cat

VERIFY_SINCE ?= 15
logs-since:
	@echo "Showing logs from the last $(VERIFY_SINCE)s"
	docker compose logs --no-color --since $(VERIFY_SINCE)s portwatcher | cat

exec shell:
	docker exec -it $(PROJECT) bash

stop:
	docker compose down

clean:
	docker compose down --volumes --remove-orphans
	docker image rm $$(docker images -q --filter=reference='*$(PROJECT)*') 2>/dev/null || true

# Convenience target to demonstrate a new port opening inside the container
test-http:
	docker exec -d $(PROJECT) node -e "require('http').createServer((req,res)=>res.end('Hi')).listen(5000)"
	@echo "Started HTTP server on port 5000 inside container. Check 'make logs'."

PORT ?= 5354
test-udp:
	docker exec -d $(PROJECT) node -e "require('dgram').createSocket('udp4').bind($(PORT))"
	@echo "Started UDP socket on port $(PORT) inside container. Check 'make logs'."

test-3000:
	docker exec -d $(PROJECT) node -e "require('http').createServer((req,res)=>res.end('Hello 3000')).listen(3000)"
	@echo "Started HTTP server on port 3000 inside container. Try: curl -s localhost:3000"

# Kill the process that listens on a given port inside the container
# Usage: make kill-port PORT=5000
kill-port:
	@if [ -z "$(PORT)" ]; then echo "PORT is required, e.g., make kill-port PORT=5000"; exit 1; fi
	docker exec $(PROJECT) bash -lc 'set -e; pid=$$(lsof -t -i :$(PORT) || true); if [ -n "$$pid" ]; then echo "Killing PID $$pid on port $(PORT)"; kill $$pid || true; else echo "No PID found on port $(PORT)"; fi'

# Transient tests
TRANSIENT_PORT ?= 5051
TRANSIENT_MS ?= 120
test-tcp-transient:
	@echo "Starting transient TCP listener on port $(TRANSIENT_PORT) for $(TRANSIENT_MS)ms"
	docker exec -d $(PROJECT) node -e "const p=$(TRANSIENT_PORT),ms=$(TRANSIENT_MS);const s=require('net').createServer(()=>{});s.listen(p,()=>setTimeout(()=>s.close(),ms));"

test-udp-transient:
	@echo "Starting transient UDP socket on port $(TRANSIENT_PORT) for $(TRANSIENT_MS)ms"
	docker exec -d $(PROJECT) node -e "const p=$(TRANSIENT_PORT),ms=$(TRANSIENT_MS);const d=require('dgram').createSocket('udp4');d.bind(p,()=>setTimeout(()=>d.close(),ms));"

# Burst tests using varying ports to avoid reuse conflicts
BURST_COUNT ?= 5
BASE_PORT ?= 5600
HOLD_MS ?= 120
INTERVAL_S ?= 0.05
test-tcp-burst:
	@echo "Starting TCP burst: count=$(BURST_COUNT), base=$(BASE_PORT), hold=$(HOLD_MS)ms, interval=$(INTERVAL_S)s"
	docker exec $(PROJECT) bash -lc 'set -e; for i in $$(seq 0 $$(($(BURST_COUNT)-1))); do port=$$(($(BASE_PORT)+i)); node -e "const p=$$port,ms=$(HOLD_MS);const s=require(\"net\").createServer(()=>{});s.listen(p,()=>setTimeout(()=>s.close(),ms));" & sleep $(INTERVAL_S); done; wait || true'

test-udp-burst:
	@echo "Starting UDP burst: count=$(BURST_COUNT), base=$(BASE_PORT), hold=$(HOLD_MS)ms, interval=$(INTERVAL_S)s"
	docker exec $(PROJECT) bash -lc 'set -e; for i in $$(seq 0 $$(($(BURST_COUNT)-1))); do port=$$(($(BASE_PORT)+i)); node -e "const p=$$port,ms=$(HOLD_MS);const d=require(\"dgram\").createSocket(\"udp4\");d.bind(p,()=>setTimeout(()=>d.close(),ms));" & sleep $(INTERVAL_S); done; wait || true'

# Verify logs for a specific port recently
verify-port-logs:
	@if [ -z "$(PORT)" ]; then echo "PORT is required, e.g., make verify-port-logs PORT=5000"; exit 1; fi
	@echo "Searching logs (last $(VERIFY_SINCE)s) for port $(PORT)"
	docker compose logs --no-color --since $(VERIFY_SINCE)s portwatcher | grep -E "New port opened: $(PORT)|Port closed: $(PORT)" || true

# Full verification sequence: start HF mode, run tests, then show logs
verify-suite: stop run-hf
	@echo "Running verification sequence..."
	$(MAKE) test-http
	sleep 0.2
	$(MAKE) kill-port PORT=5000
	$(MAKE) test-udp PORT=5361
	sleep 0.2
	$(MAKE) kill-port PORT=5361
	$(MAKE) test-3000
	$(MAKE) test-tcp-transient TRANSIENT_PORT=5701 TRANSIENT_MS=120
	$(MAKE) test-udp-transient TRANSIENT_PORT=5702 TRANSIENT_MS=120
	$(MAKE) test-tcp-burst BURST_COUNT=6 BASE_PORT=5800 HOLD_MS=120 INTERVAL_S=0.03
	$(MAKE) test-udp-burst BURST_COUNT=6 BASE_PORT=5900 HOLD_MS=120 INTERVAL_S=0.03
	@echo "\n--- Recent logs (last 20s) ---"
	$(MAKE) logs-since VERIFY_SINCE=20


