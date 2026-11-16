#!/usr/bin/env bash
# Runs on node0. Builds a 3-node SLURM cluster with a Puppet-enforced bad
# slurm.conf, a slurmd cgroup drop-in that starves the daemon, and dpkg-dist
# residue from a "half-finished" unattended-upgrades run. Each node carries a
# local puppet-apply cron so any in-place fix is reverted.
set -euo pipefail

LAB_DIR="/opt/syscraft-slurm"
SOURCE_DIR="${LAB_DIR}/managed-source"
INCIDENT_ID="slurm-puppet-cascade-20260518"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
NODES=(node0 node1 node2)
COMPUTE_NODES=(node1 node2)
MANIFEST_DIR="/etc/puppetlabs/code/environments/production/manifests"
MANIFEST_PATH="${MANIFEST_DIR}/site.pp"

require_ip() {
    local node=$1
    local ip
    ip=$(getent hosts "$node" | awk '{print $1; exit}')
    if [ -z "$ip" ]; then
        echo "failed to resolve ${node}" >&2
        exit 1
    fi
    printf '%s\n' "$ip"
}

run_on_node() {
    local node=$1
    if [ "$node" = "node0" ]; then
        bash -se
    else
        ssh "${SSH_OPTS[@]}" "$node" 'bash -se'
    fi
}

copy_to_node() {
    local source=$1
    local node=$2
    local target=$3
    if [ "$node" = "node0" ]; then
        if [ "$source" != "$target" ]; then
            mkdir -p "$(dirname "$target")"
            cp "$source" "$target"
        fi
    else
        ssh "${SSH_OPTS[@]}" "$node" "mkdir -p $(dirname "$target")"
        scp "${SSH_OPTS[@]}" "$source" "${node}:${target}"
    fi
}

wait_for_ssh() {
    local node=$1
    local attempt
    for attempt in $(seq 1 60); do
        if ssh "${SSH_OPTS[@]}" "$node" true 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    echo "ssh to ${node} never came up" >&2
    return 1
}

for node in "${NODES[@]}"; do
    require_ip "$node" >/dev/null
done

for node in "${COMPUTE_NODES[@]}"; do
    wait_for_ssh "$node"
done

# ---- Munge key sync ---------------------------------------------------------

for node in "${NODES[@]}"; do
    run_on_node "$node" <<'NODE'
set -euo pipefail
systemctl stop slurmctld slurmd munge 2>/dev/null || true
NODE
done

if [ ! -s /etc/munge/munge.key ]; then
    /usr/sbin/create-munge-key -f >/dev/null 2>&1 || dd if=/dev/urandom of=/etc/munge/munge.key bs=1 count=1024 2>/dev/null
fi
chown munge:munge /etc/munge/munge.key
chmod 400 /etc/munge/munge.key
for node in "${COMPUTE_NODES[@]}"; do
    copy_to_node /etc/munge/munge.key "$node" /etc/munge/munge.key
    ssh "${SSH_OPTS[@]}" "$node" "chown munge:munge /etc/munge/munge.key && chmod 400 /etc/munge/munge.key"
done

for node in "${NODES[@]}"; do
    run_on_node "$node" <<'NODE'
set -euo pipefail
systemctl enable munge >/dev/null
systemctl restart munge
NODE
done

# ---- Lab metadata + managed-source payloads ---------------------------------

mkdir -p "$LAB_DIR" "$SOURCE_DIR" "$MANIFEST_DIR" /etc/syscraft

cat >/etc/syscraft/slurm-cascade.env <<EOF
INCIDENT_ID=${INCIDENT_ID}
SLURMCTLD_NODE=node0
COMPUTE_NODES=node1,node2
MANIFEST_PATH=${MANIFEST_PATH}
EOF

# slurm.conf with MaxJobCount=2 / MaxStepCount=2: single steps succeed,
# concurrent submissions are rejected with "Maximum job count reached".
cat >"${SOURCE_DIR}/slurm.conf" <<'EOF'
ClusterName=syscraft
SlurmctldHost=node0
AuthType=auth/munge
StateSaveLocation=/var/spool/slurmctld
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
SlurmdSpoolDir=/var/spool/slurmd
SlurmUser=slurm
SlurmdUser=root
ProctrackType=proctrack/linuxproc
TaskPlugin=task/affinity
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
ReturnToService=2
MpiDefault=none
# --- syscraft-injected unsafe limits ---
MaxJobCount=2
MaxStepCount=2
# --- node + partition layout ---
NodeName=node1 CPUs=2 RealMemory=2800 State=UNKNOWN
NodeName=node2 CPUs=2 RealMemory=2800 State=UNKNOWN
PartitionName=debug Nodes=node[1-2] Default=YES MaxTime=INFINITE State=UP
EOF

cat >"${SOURCE_DIR}/cgroup.conf" <<'EOF'
CgroupPlugin=cgroup/v2
ConstrainCores=no
ConstrainRAMSpace=no
EOF

# slurmd drop-in: starves the daemon under sustained concurrent steps.
cat >"${SOURCE_DIR}/slurmd-maintenance-cgroup.conf" <<'EOF'
[Service]
CPUAccounting=true
MemoryAccounting=true
TasksAccounting=true
TasksMax=12
MemoryMax=48M
CPUQuota=10%
EOF

# ---- Puppet manifest --------------------------------------------------------

cat >"$MANIFEST_PATH" <<MANIFEST
# syscraft-managed: SLURM configuration baseline
# This manifest re-applies the maintenance-window configuration every
# puppet apply. Hand-editing /etc/slurm/* or the slurmd drop-in will be
# reverted on the next run.

file { ['/etc/slurm', '/etc/systemd/system/slurmd.service.d']:
  ensure => directory,
  owner  => 'root',
  group  => 'root',
  mode   => '0755',
}

file { '/etc/slurm/slurm.conf':
  ensure => file,
  owner  => 'slurm',
  group  => 'slurm',
  mode   => '0644',
  source => 'file://${SOURCE_DIR}/slurm.conf',
}

file { '/etc/slurm/cgroup.conf':
  ensure => file,
  owner  => 'slurm',
  group  => 'slurm',
  mode   => '0644',
  source => 'file://${SOURCE_DIR}/cgroup.conf',
}

file { '/etc/systemd/system/slurmd.service.d/maintenance-cgroup.conf':
  ensure  => file,
  owner   => 'root',
  group   => 'root',
  mode    => '0644',
  source  => 'file://${SOURCE_DIR}/slurmd-maintenance-cgroup.conf',
  notify  => Exec['syscraft-daemon-reload'],
  require => File['/etc/systemd/system/slurmd.service.d'],
}

exec { 'syscraft-daemon-reload':
  command     => '/bin/systemctl daemon-reload',
  refreshonly => true,
}
MANIFEST

# Distribute manifest, lab metadata, and managed-source files to every node.
for node in "${NODES[@]}"; do
    copy_to_node /etc/syscraft/slurm-cascade.env "$node" /etc/syscraft/slurm-cascade.env
    copy_to_node "${SOURCE_DIR}/slurm.conf" "$node" "${SOURCE_DIR}/slurm.conf"
    copy_to_node "${SOURCE_DIR}/cgroup.conf" "$node" "${SOURCE_DIR}/cgroup.conf"
    copy_to_node "${SOURCE_DIR}/slurmd-maintenance-cgroup.conf" "$node" "${SOURCE_DIR}/slurmd-maintenance-cgroup.conf"
    copy_to_node "$MANIFEST_PATH" "$node" "$MANIFEST_PATH"
    run_on_node "$node" <<NODE
set -euo pipefail
cat >/etc/cron.d/syscraft-puppet-apply <<'CRON'
# syscraft-managed: re-apply maintenance Puppet manifest every 5 minutes.
*/5 * * * * root /usr/bin/puppet apply ${MANIFEST_PATH} >/var/log/syscraft-puppet.log 2>&1
CRON
chmod 644 /etc/cron.d/syscraft-puppet-apply
systemctl enable cron >/dev/null
systemctl restart cron
/usr/bin/puppet apply ${MANIFEST_PATH} >/var/log/syscraft-puppet.log 2>&1 || true
NODE
done

# ---- dpkg-dist residue from a half-completed unattended-upgrades run --------

for node in "${NODES[@]}"; do
    run_on_node "$node" <<'NODE'
set -euo pipefail
cat >/etc/slurm/slurm.conf.dpkg-dist <<'EOF'
# Upstream-shipped slurm.conf packaged with slurm-wlm 23.11.x.
# Merge sensible defaults into /etc/slurm/slurm.conf.
ClusterName=syscraft
MaxJobCount=10000
MaxStepCount=40000
EOF
cat >/etc/slurm/cgroup.conf.dpkg-dist <<'EOF'
CgroupPlugin=cgroup/v2
ConstrainCores=no
ConstrainRAMSpace=no
ConstrainDevices=no
EOF
chmod 644 /etc/slurm/slurm.conf.dpkg-dist /etc/slurm/cgroup.conf.dpkg-dist
NODE
done

# ---- Enable unattended-upgrades timers (part of standing posture) -----------

for node in "${NODES[@]}"; do
    run_on_node "$node" <<'NODE'
set -euo pipefail
systemctl enable apt-daily.timer apt-daily-upgrade.timer unattended-upgrades >/dev/null 2>&1 || true
systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
NODE
done

# ---- Start SLURM services ---------------------------------------------------

systemctl daemon-reload
systemctl enable slurmctld >/dev/null
systemctl restart slurmctld

for node in "${COMPUTE_NODES[@]}"; do
    ssh "${SSH_OPTS[@]}" "$node" "systemctl daemon-reload && systemctl enable slurmd >/dev/null && systemctl restart slurmd"
done

# Give slurmd time to register; nodes may briefly be in DOWN* until first ping.
sleep 5
scontrol update NodeName=node1 State=RESUME Reason=bootstrap 2>/dev/null || true
scontrol update NodeName=node2 State=RESUME Reason=bootstrap 2>/dev/null || true
sleep 3

# ---- Sanity: short health checks must pass (intentionally misleading) -------

if ! sinfo -h -o '%T' >/tmp/syscraft-sinfo.txt; then
    echo "sinfo failed at bootstrap end" >&2
    exit 1
fi
if ! srun --ntasks=1 -t 1 hostname >/tmp/syscraft-srun.txt 2>&1; then
    echo "single-step srun failed at bootstrap end" >&2
    cat /tmp/syscraft-srun.txt >&2
    exit 1
fi

cat >"${LAB_DIR}/incident-note.txt" <<'EOF'
sinfo is green and a single srun hostname works. Concurrent submissions hit
"Maximum job count reached" and slurmd is starved by a maintenance cgroup
drop-in. The local puppet apply cron re-enforces the bad slurm.conf, cgroup
drop-in, and cgroup.conf every five minutes, and reboots re-load the drop-in.
EOF

echo "Injected SLURM Puppet/unattended-upgrades cascade incident"
