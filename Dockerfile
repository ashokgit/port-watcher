FROM node:18

WORKDIR /app

# Install tools to inspect network ports
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       iproute2 procps lsof net-tools ca-certificates \
    && rm -rf /var/lib/apt/lists/*


EXPOSE 3080

# Copy the listener script into container
COPY listen_ports.sh /listen_ports.sh
RUN chmod +x /listen_ports.sh

# Scan interval (seconds) can be overridden at runtime
ENV SCAN_INTERVAL=2

# Run the listener as the main container process
CMD ["/listen_ports.sh"]


