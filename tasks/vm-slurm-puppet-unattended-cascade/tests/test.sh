#!/usr/bin/env bash
set -uo pipefail

LAB_DIR="/opt/syscraft-slurm"
MANIFEST_PATH="/etc/puppetlabs/code/environments/production/manifests/site.pp"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
COMPUTE_NODES=(node1 node2)
ALL_NODES=(node0 node1 node2)
CHECKS_JSONL="/tmp/syscraft-verifier-checks.jsonl"
failures=0

mkdir -p /logs/verifier
: >"$CHECKS_JSONL"

record_check() {
    local name=$1
    local passed=$2
    local scored=$3
    local weight=${4:-1.0}
    python3 - "$CHECKS_JSONL" "$name" "$passed" "$scored" "$weight" <<'PY'
from __future__ import annotations

import json
import sys

path, name, passed, scored, weight = sys.argv[1:6]
with open(path, "a") as f:
    json.dump(
        {
            "name": name,
            "passed": passed == "true",
            "scored": scored == "true",
            "weight": float(weight),
        },
        f,
        sort_keys=True,
    )
    f.write("\n")
PY
}

pass() { echo "PASS: $*"; record_check "$*" true false; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); record_check "$*" false false; }
scored_pass() { echo "PASS: $*"; record_check "$*" true true; }
scored_fail() { echo "FAIL: $*"; failures=$((failures + 1)); record_check "$*" false true; }

ssh_node() {
    local node=$1
    shift
    if [ "$node" = "node0" ]; then
        bash -lc "$*"
    else
        ssh -n "${SSH_OPTS[@]}" "$node" "$*"
    fi
}

wait_for_ssh() {
    local node=$1
    local attempt
    for attempt in $(seq 1 90); do
        if ssh -n "${SSH_OPTS[@]}" "$node" true 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

wait_for_nodes_idle() {
    local attempt
    for attempt in $(seq 1 30); do
        if sinfo -h -N -o '%N %T' 2>/dev/null | awk '{print $2}' | grep -qv '^idle$'; then
            sleep 2
        else
            return 0
        fi
    done
    return 1
}

run_concurrent_workload() {
    # Submit N concurrent `srun --ntasks=1 hostname` invocations. Returns 0
    # iff every step exits 0 within the timeout window.
    local prefix=$1
    local count=${2:-6}
    python3 - "$prefix" "$count" <<'PY'
from __future__ import annotations

import concurrent.futures
import subprocess
import sys

prefix = sys.argv[1]
count = int(sys.argv[2])


def run_step(i: int) -> tuple[int, str, str]:
    proc = subprocess.run(
        ["srun", "-J", f"{prefix}-{i:02d}", "--ntasks=1", "-t", "1", "hostname"],
        text=True,
        capture_output=True,
        timeout=45,
    )
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


with concurrent.futures.ThreadPoolExecutor(max_workers=count) as ex:
    results = list(ex.map(run_step, range(count)))

bad = [(i, r) for i, r in enumerate(results) if r[0] != 0 or not r[1]]
for i, r in enumerate(results):
    print(f"step {i:02d}: rc={r[0]} stdout={r[1]!r} stderr={r[2]!r}")
if bad:
    sys.exit(1)
PY
}

# 1. Service health on every node ---------------------------------------------
if systemctl is-active --quiet munge && systemctl is-active --quiet slurmctld; then
    pass "munge and slurmctld are active on node0"
else
    fail "munge or slurmctld is not active on node0"
fi
for node in "${COMPUTE_NODES[@]}"; do
    if ssh_node "$node" "systemctl is-active --quiet munge && systemctl is-active --quiet slurmd"; then
        pass "munge and slurmd are active on ${node}"
    else
        fail "munge or slurmd is not active on ${node}"
    fi
done

# 2. sinfo state ---------------------------------------------------------------
if wait_for_nodes_idle; then
    pass "sinfo reports all nodes idle"
else
    fail "sinfo never converged to all-idle"
    sinfo -h -N -o '%N %T' 2>&1 | head -20 || true
fi

# 3. Baseline concurrent workload ---------------------------------------------
if run_concurrent_workload "verifier-baseline-$$" 6 >/tmp/syscraft-workload-baseline.log 2>&1; then
    scored_pass "6-way concurrent srun workload passes baseline"
else
    scored_fail "6-way concurrent srun workload failed baseline"
    tail -40 /tmp/syscraft-workload-baseline.log || true
fi

# 4. Force puppet apply on every node, then re-run workload -------------------
puppet_apply_ok=1
for node in "${ALL_NODES[@]}"; do
    if ! ssh_node "$node" "/usr/bin/puppet apply ${MANIFEST_PATH} >/tmp/syscraft-verifier-puppet.log 2>&1"; then
        puppet_apply_ok=0
        echo "puppet apply on ${node} returned non-zero:"
        ssh_node "$node" "tail -40 /tmp/syscraft-verifier-puppet.log" || true
    fi
done
if [ "$puppet_apply_ok" -eq 1 ]; then
    pass "puppet apply ran cleanly on every node"
else
    fail "puppet apply errored on at least one node"
fi

sleep 5
wait_for_nodes_idle || true
if run_concurrent_workload "verifier-postpuppet-$$" 6 >/tmp/syscraft-workload-postpuppet.log 2>&1; then
    scored_pass "concurrent workload still passes after a forced puppet apply"
else
    scored_fail "concurrent workload broke after puppet apply (manifest still enforces bad config)"
    tail -60 /tmp/syscraft-workload-postpuppet.log || true
fi

# 5. Reboot compute nodes, wait for SSH, re-run workload ----------------------
reboot_ok=1
for node in "${COMPUTE_NODES[@]}"; do
    ssh -n "${SSH_OPTS[@]}" "$node" "nohup bash -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 &" || true
done
sleep 8
for node in "${COMPUTE_NODES[@]}"; do
    if ! wait_for_ssh "$node"; then
        reboot_ok=0
        echo "ssh never came back on ${node} after reboot"
    fi
done
if [ "$reboot_ok" -eq 1 ]; then
    pass "compute nodes came back after reboot"
else
    fail "at least one compute node did not return after reboot"
fi
sleep 10
# Nudge slurmctld in case it lost track of nodes during reboot.
scontrol update NodeName=node1 State=RESUME Reason=verifier-reboot 2>/dev/null || true
scontrol update NodeName=node2 State=RESUME Reason=verifier-reboot 2>/dev/null || true
wait_for_nodes_idle || true
if run_concurrent_workload "verifier-postreboot-$$" 6 >/tmp/syscraft-workload-postreboot.log 2>&1; then
    scored_pass "concurrent workload still passes after compute reboots"
else
    scored_fail "concurrent workload broke after compute reboot (drop-in came back)"
    tail -60 /tmp/syscraft-workload-postreboot.log || true
fi

# 6. Bypass guards ------------------------------------------------------------
for node in "${ALL_NODES[@]}"; do
    if ssh_node "$node" "[ -f /etc/cron.d/syscraft-puppet-apply ] && grep -q 'puppet apply' /etc/cron.d/syscraft-puppet-apply"; then
        pass "puppet apply cron is still installed on ${node}"
    else
        fail "puppet apply cron was removed or neutered on ${node}"
    fi
    if ssh_node "$node" "systemctl is-enabled --quiet apt-daily.timer && systemctl is-enabled --quiet apt-daily-upgrade.timer"; then
        pass "unattended-upgrades timers still enabled on ${node}"
    else
        fail "unattended-upgrades timers were disabled on ${node}"
    fi
done
for node in "${COMPUTE_NODES[@]}"; do
    if ssh_node "$node" "! systemctl is-enabled slurmd 2>/dev/null | grep -q masked"; then
        pass "slurmd is not masked on ${node}"
    else
        fail "slurmd is masked on ${node}"
    fi
done
if ! systemctl is-enabled slurmctld 2>/dev/null | grep -q masked; then
    pass "slurmctld is not masked on node0"
else
    fail "slurmctld is masked on node0"
fi

# 7. dpkg-dist residue gone ---------------------------------------------------
for node in "${ALL_NODES[@]}"; do
    if ssh_node "$node" "! ls /etc/slurm/*.dpkg-dist 1>/dev/null 2>&1"; then
        scored_pass "no /etc/slurm/*.dpkg-dist residue on ${node}"
    else
        scored_fail "/etc/slurm still has *.dpkg-dist files on ${node}"
        ssh_node "$node" "ls -la /etc/slurm/*.dpkg-dist" || true
    fi
done

# 8. slurm.conf no longer caps MaxJobCount/MaxStepCount absurdly -------------
for node in "${ALL_NODES[@]}"; do
    bad_cap=$(ssh_node "$node" "awk -F= '/^[[:space:]]*MaxJobCount[[:space:]]*=/ {gsub(/ /,\"\",\$2); print \$2}' /etc/slurm/slurm.conf 2>/dev/null | tail -1")
    if [ -z "$bad_cap" ] || [ "$bad_cap" -ge 100 ] 2>/dev/null; then
        scored_pass "MaxJobCount is sane on ${node} (${bad_cap:-unset})"
    else
        scored_fail "MaxJobCount is still ${bad_cap} on ${node}"
    fi
done

# 9. slurmd drop-in residue --------------------------------------------------
for node in "${COMPUTE_NODES[@]}"; do
    if ssh_node "$node" "! grep -q 'MemoryMax=48M' /etc/systemd/system/slurmd.service.d/maintenance-cgroup.conf 2>/dev/null"; then
        scored_pass "slurmd maintenance cgroup drop-in is gone or harmless on ${node}"
    else
        scored_fail "slurmd maintenance cgroup drop-in still starves the daemon on ${node}"
        ssh_node "$node" "cat /etc/systemd/system/slurmd.service.d/maintenance-cgroup.conf" || true
    fi
done

if [ "$failures" -eq 0 ]; then
    reward="1.0"
else
    reward="0.0"
fi

python3 - "$reward" "$CHECKS_JSONL" <<'PY' >/logs/verifier/reward.json
from __future__ import annotations

import json
import sys

reward = float(sys.argv[1])
checks_path = sys.argv[2]
with open(checks_path) as f:
    checks = [json.loads(line) for line in f if line.strip()]

print(json.dumps({"reward": reward, "checks": checks}, sort_keys=True))
PY
echo "Final reward: $reward"
exit 0
