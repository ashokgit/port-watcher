FROM alpine:3.20

# Version of Tracee to install (GitHub release tag or "latest")
ARG TRACEE_VERSION=latest
# Whether to install Tracee at build time (1=yes, 0=skip for fallback-only builds)
ARG INSTALL_TRACEE=1

RUN apk add --no-cache bash jq supervisor zlib libelf ca-certificates curl tar

WORKDIR /app

# Install Tracee via the portable installer (optional)
COPY install_tracee.sh /usr/local/bin/install_tracee.sh
RUN chmod +x /usr/local/bin/install_tracee.sh \
    && if [ "$INSTALL_TRACEE" = "1" ]; then \
         TRACEE_VERSION="$TRACEE_VERSION" /usr/local/bin/install_tracee.sh; \
       else \
         echo "Skipping Tracee install at build time (INSTALL_TRACEE=$INSTALL_TRACEE)"; \
       fi

COPY tracee_ports.sh /usr/local/bin/tracee_ports.sh
RUN chmod +x /usr/local/bin/tracee_ports.sh

COPY universal_portwatcher.sh /usr/local/bin/universal_portwatcher.sh
RUN chmod +x /usr/local/bin/universal_portwatcher.sh

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Supervisor config to manage the ebpf watcher
COPY supervisord.tracee.conf /etc/supervisor/conf.d/tracee.conf

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/tracee.conf"]


