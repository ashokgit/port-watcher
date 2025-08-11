.PHONY: help build run stop clean logs exec shell test-http test-udp test-3000 kill-port

PROJECT := portwatcher
SCAN_INTERVAL ?= 2

help:
	@echo "Targets:"
	@echo "  build        Build the Docker image"
	@echo "  run          Build and start the stack (detached)"
	@echo "  logs         Tail container logs"
	@echo "  exec         Exec into the container with bash"
	@echo "  shell        Alias for exec"
	@echo "  stop         Stop the stack"
	@echo "  clean        Stop and remove containers, volumes, and images"
	@echo "  test-http    Open a Node HTTP server on port 5000 inside the container"
	@echo "  test-udp     Open a UDP socket on port $(PORT) inside the container (default 5354)"
	@echo "  test-3000    Open a Node HTTP server on port 3000 inside the container (host exposed 3000:3000)"
	@echo "  kill-port    Kill the process listening on PORT inside the container (PORT=<n>)"

build:
	SCAN_INTERVAL=$(SCAN_INTERVAL) docker compose build

run: build
	SCAN_INTERVAL=$(SCAN_INTERVAL) docker compose up -d
	@echo "\nContainer is running. Use 'make logs' to observe new ports."

logs:
	docker compose logs -f | cat

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


