#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    chrony \
    curl \
    dnsutils \
    iproute2 \
    jq \
    less \
    netcat-openbsd \
    openssl \
    podman \
    procps \
    python3 \
    sqlite3 \
    vim-tiny

systemctl enable --now chrony || true

mkdir -p /etc/containers/registries.conf.d
cat >/etc/containers/registries.conf.d/syscraft-pelican.conf <<'EOF'
unqualified-search-registries = ["docker.io"]
EOF

mkdir -p /opt/syscraft-pelican/bin /etc/syscraft
