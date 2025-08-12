FROM aquasec/tracee:latest as tracee_src

FROM alpine:3.20

RUN apk add --no-cache bash jq supervisor zlib libelf ca-certificates

WORKDIR /app

COPY --from=tracee_src /tracee/tracee /tracee/tracee
RUN chmod +x /tracee/tracee

COPY tracee_ports.sh /usr/local/bin/tracee_ports.sh
RUN chmod +x /usr/local/bin/tracee_ports.sh

COPY universal_portwatcher.sh /usr/local/bin/universal_portwatcher.sh
RUN chmod +x /usr/local/bin/universal_portwatcher.sh

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Supervisor config to manage the ebpf watcher
COPY supervisord.tracee.conf /etc/supervisor/conf.d/tracee.conf

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/tracee.conf"]


