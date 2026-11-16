#!/usr/bin/env bash
# Runs on every VM node. Installs the task-local database, pooler, and utilities.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    dnsutils \
    iproute2 \
    jq \
    netcat-openbsd \
    openssh-client \
    pgbouncer \
    postgresql \
    postgresql-client \
    procps \
    python3 \
    rsync

mkdir -p /opt/syscraft-pgbouncer /etc/syscraft
