#!/usr/bin/env bash
# Runs on every VM. Installs SLURM, Puppet, and supporting utilities.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates \
    cron \
    curl \
    dnsutils \
    iproute2 \
    jq \
    munge \
    netcat-openbsd \
    openssh-client \
    procps \
    puppet \
    python3 \
    rsync \
    slurm-wlm \
    slurmctld \
    slurmd \
    unattended-upgrades

mkdir -p /opt/syscraft-slurm /etc/syscraft /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
chown -R slurm:slurm /var/spool/slurmctld /var/spool/slurmd /var/log/slurm

# Ensure Puppet's local environment directory exists so puppet apply works
# without invoking a puppetserver.
mkdir -p /etc/puppetlabs/code/environments/production/manifests
