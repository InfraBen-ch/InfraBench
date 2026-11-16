#!/usr/bin/env bash
# Reference recovery: fix the Puppet manifest so re-apply does not regress,
# remove the slurmd cgroup drop-in via Puppet, merge /etc/slurm/*.dpkg-dist
# into the live configs, and restart slurmctld + slurmd on every node.
set -euo pipefail

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
SOURCE_DIR="/opt/syscraft-slurm/managed-source"
MANIFEST_PATH="/etc/puppetlabs/code/environments/production/manifests/site.pp"
NODES=(node0 node1 node2)
COMPUTE_NODES=(node1 node2)

echo "Inspecting current SLURM incident state"
cat /etc/slurm/slurm.conf | grep -E '^(MaxJobCount|MaxStepCount|NodeName|PartitionName)' || true
ssh "${SSH_OPTS[@]}" node1 "cat /etc/systemd/system/slurmd.service.d/maintenance-cgroup.conf || true"

# ---- Repair the managed-source files (used by the Puppet manifest) ---------

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
MaxJobCount=10000
MaxStepCount=40000
NodeName=node1 CPUs=2 RealMemory=2800 State=UNKNOWN
NodeName=node2 CPUs=2 RealMemory=2800 State=UNKNOWN
PartitionName=debug Nodes=node[1-2] Default=YES MaxTime=INFINITE State=UP
EOF

cat >"${SOURCE_DIR}/cgroup.conf" <<'EOF'
CgroupPlugin=cgroup/v2
ConstrainCores=no
ConstrainRAMSpace=no
ConstrainDevices=no
EOF

# ---- Rewrite the Puppet manifest so the slurmd drop-in is purged -----------

cat >"$MANIFEST_PATH" <<MANIFEST
# syscraft-managed: SLURM configuration baseline (repaired)
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
  ensure => absent,
  notify => Exec['syscraft-daemon-reload'],
}

exec { 'syscraft-daemon-reload':
  command     => '/bin/systemctl daemon-reload',
  refreshonly => true,
}
MANIFEST

# ---- Propagate repair to every node, merge dpkg-dist residue, restart ------

for node in "${NODES[@]}"; do
    ssh "${SSH_OPTS[@]}" "$node" "mkdir -p ${SOURCE_DIR} $(dirname "$MANIFEST_PATH")"
    scp "${SSH_OPTS[@]}" "${SOURCE_DIR}/slurm.conf" "${node}:${SOURCE_DIR}/slurm.conf"
    scp "${SSH_OPTS[@]}" "${SOURCE_DIR}/cgroup.conf" "${node}:${SOURCE_DIR}/cgroup.conf"
    scp "${SSH_OPTS[@]}" "$MANIFEST_PATH" "${node}:${MANIFEST_PATH}"
    ssh "${SSH_OPTS[@]}" "$node" <<'REMOTE'
set -euo pipefail
rm -f /etc/slurm/slurm.conf.dpkg-dist /etc/slurm/cgroup.conf.dpkg-dist
/usr/bin/puppet apply /etc/puppetlabs/code/environments/production/manifests/site.pp >/var/log/syscraft-puppet.log 2>&1
systemctl daemon-reload
REMOTE
done

# ---- Restart SLURM services -----------------------------------------------

systemctl restart slurmctld
for node in "${COMPUTE_NODES[@]}"; do
    ssh "${SSH_OPTS[@]}" "$node" "systemctl restart slurmd"
done

sleep 5
scontrol update NodeName=node1 State=RESUME Reason=solve 2>/dev/null || true
scontrol update NodeName=node2 State=RESUME Reason=solve 2>/dev/null || true
sleep 3

echo "Validating cluster health"
sinfo -h -N -o '%N %T'
srun --ntasks=1 -t 1 hostname

echo "SLURM Puppet/unattended-upgrades cascade recovery complete"
