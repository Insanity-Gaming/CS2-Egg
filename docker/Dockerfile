FROM registry.gitlab.steamos.cloud/steamrt/sniper/platform:latest-container-runtime-depot

LABEL org.opencontainers.image.description="Insanity Gaming CS2 — SteamRT3 Sniper egg for Pterodactyl/Pelican"

RUN mkdir -p /etc/sudoers.d && \
    echo "%sudo ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/flatdeb && \
    chmod 0440 /etc/sudoers.d/flatdeb

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        iproute2 \
        jq \
        unzip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY utils.sh      /utils.sh
COPY cleanup.sh    /cleanup.sh
COPY modsharp.sh   /modsharp.sh
COPY entrypoint.sh /entrypoint.sh

RUN chmod 555 /utils.sh /cleanup.sh /modsharp.sh /entrypoint.sh

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

CMD ["/bin/bash", "/entrypoint.sh"]
