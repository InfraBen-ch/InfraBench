#!/usr/bin/env bash
# Runs on every VM. Installs mdadm, device-mapper, NFS, and supporting tools.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates \
    coreutils \
    curl \
    dmsetup \
    iproute2 \
    jq \
    mdadm \
    netcat-openbsd \
    nfs-common \
    nfs-kernel-server \
    openssh-client \
    procps \
    python3 \
    rsync \
    util-linux

mkdir -p /opt/syscraft-raid /var/lib/syscraft-disks /srv/storage /etc/syscraft
