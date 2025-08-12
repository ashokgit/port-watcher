FROM node:18

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       iproute2 procps lsof net-tools ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Copy watcher scripts from repo at build context time
COPY ebpf/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY ebpf/universal_portwatcher.sh /usr/local/bin/universal_portwatcher.sh
COPY ebpf/tracee_ports.sh /usr/local/bin/tracee_ports.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    /usr/local/bin/universal_portwatcher.sh \
    /usr/local/bin/tracee_ports.sh

# Default: do not install tracee; run fallback sampler which works in Docker Desktop too
ENV EBPF_FORCE_FALLBACK=1 \
    EBPF_FALLBACK=1 \
    LISTENER_URL=http://listner-api:8080/ingest

# Start the watcher directly (fallback sampler by default)
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]


