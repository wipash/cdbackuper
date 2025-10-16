FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    bash coreutils util-linux procps udev eject gddrescue \
    genisoimage jq rsync ca-certificates tzdata curl && \
    rm -rf /var/lib/apt/lists/*

ENV TZ=Pacific/Auckland

# Script will come from a ConfigMap; entrypoint just sleeps until it's mounted
ENTRYPOINT ["/bin/bash","-lc","sleep infinity"]
