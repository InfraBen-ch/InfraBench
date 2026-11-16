#!/usr/bin/env bash
set -uo pipefail

LAB_DIR="/opt/syscraft-raid"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
P95_THRESHOLD_MS=100
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

ssh_node1() {
    ssh -n "${SSH_OPTS[@]}" node1 "$*"
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

remount_client() {
    umount -f /mnt/storage 2>/dev/null || true
    for attempt in $(seq 1 30); do
        if mount -t nfs -o rw,_netdev,noatime node1:/srv/storage /mnt/storage 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# Helper: concurrent O_DIRECT-ish latency probe on node1 against /srv/storage.
# Runs entirely on node1 to isolate storage latency from NFS overhead.
run_latency_probe() {
    ssh -n "${SSH_OPTS[@]}" node1 'python3 - <<PY
from __future__ import annotations

import concurrent.futures
import os
import random
import subprocess
import time

FILE = "/srv/storage/baseline/big.bin"
SIZE = os.path.getsize(FILE)
BLOCK = 4096
MAX_BLOCK = SIZE // BLOCK - 1
SAMPLES = 200
CONCURRENCY = 8


def read_once(_: int) -> float:
    skip = random.randint(0, MAX_BLOCK)
    t0 = time.perf_counter()
    proc = subprocess.run(
        [
            "dd",
            f"if={FILE}",
            "of=/dev/null",
            "bs=4096",
            "count=1",
            f"skip={skip}",
            "iflag=direct",
        ],
        capture_output=True,
    )
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    if proc.returncode != 0:
        return -1.0
    return elapsed_ms


with concurrent.futures.ThreadPoolExecutor(max_workers=CONCURRENCY) as ex:
    raw = list(ex.map(read_once, range(SAMPLES)))

errors = sum(1 for v in raw if v < 0)
times = sorted(v for v in raw if v >= 0)
if not times:
    print("p95_ms=inf errors=", errors)
    raise SystemExit(2)

p95 = times[int(0.95 * (len(times) - 1))]
median = times[len(times) // 2]
print(f"p95_ms={p95:.2f} median_ms={median:.2f} errors={errors} n={len(times)}")
PY'
}

# 1. NFS server health and client visibility ---------------------------------
if ssh_node1 "systemctl is-active --quiet nfs-server"; then
    pass "nfs-server is active on node1"
else
    fail "nfs-server is not active on node1"
fi

remount_client || true
if mountpoint -q /mnt/storage; then
    pass "node1 NFS export mounts on node0"
else
    fail "could not mount node1:/srv/storage on node0"
fi

# 2. Baseline data integrity --------------------------------------------------
if (cd /mnt/storage/baseline && md5sum -c "$LAB_DIR/baseline-md5.txt") >/tmp/syscraft-baseline.log 2>&1; then
    pass "baseline data checksums match"
else
    fail "baseline data has changed or is missing"
    cat /tmp/syscraft-baseline.log | head -20 || true
fi

# 3. mdadm reports a clean raid10 with 4 active / 0 failed --------------------
if ssh_node1 "mdadm --detail /dev/md0" >/tmp/syscraft-mdadm.log 2>/tmp/syscraft-mdadm.err; then
    if grep -q 'Raid Level : raid10' /tmp/syscraft-mdadm.log \
        && grep -Eq 'Active Devices : 4' /tmp/syscraft-mdadm.log \
        && grep -Eq 'Failed Devices : 0' /tmp/syscraft-mdadm.log \
        && grep -Eq 'State : clean( |$)' /tmp/syscraft-mdadm.log; then
        pass "mdadm reports raid10 clean with 4/4 active and 0 failed"
    else
        fail "mdadm detail is not raid10 / 4 active / 0 failed / clean"
        cat /tmp/syscraft-mdadm.log | head -40 || true
    fi
else
    fail "mdadm --detail /dev/md0 errored"
    cat /tmp/syscraft-mdadm.err || true
fi

# 4. No dm-delay target remains underneath the array members ------------------
if ssh_node1 "dmsetup table" >/tmp/syscraft-dmtable.log 2>/dev/null; then
    if grep -E '^disk[0-3]: .* delay ' /tmp/syscraft-dmtable.log >/dev/null; then
        scored_fail "a dm-delay target is still in place under an array member"
        grep -E '^disk[0-3]:' /tmp/syscraft-dmtable.log || true
    else
        scored_pass "no dm-delay target remains under any disk[0-3]"
    fi
else
    scored_fail "could not enumerate dmsetup table on node1"
fi

# 5. Latency probe before reboot ---------------------------------------------
if probe_out=$(run_latency_probe 2>/tmp/syscraft-probe.err); then
    p95=$(echo "$probe_out" | awk -F'[= ]' '/p95_ms/ {print $2}')
    p95_int=${p95%.*}
    echo "latency probe (pre-reboot): $probe_out"
    if [ -n "$p95_int" ] && [ "$p95_int" -lt "$P95_THRESHOLD_MS" ] 2>/dev/null; then
        pass "pre-reboot p95 latency ${p95}ms < ${P95_THRESHOLD_MS}ms"
    else
        fail "pre-reboot p95 latency ${p95}ms exceeds ${P95_THRESHOLD_MS}ms"
    fi
else
    fail "latency probe failed pre-reboot"
    cat /tmp/syscraft-probe.err || true
fi

# 6. Reboot the fileserver and re-validate -----------------------------------
ssh -n "${SSH_OPTS[@]}" node1 "nohup bash -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 &" || true
sleep 10
if wait_for_ssh node1; then
    pass "node1 came back after reboot"
else
    fail "node1 did not return after reboot"
fi
sleep 8

# Wait for nfs-server to come up after the assemble service finishes.
for _ in $(seq 1 30); do
    if ssh_node1 "systemctl is-active --quiet nfs-server"; then
        break
    fi
    sleep 2
done

remount_client || true
if mountpoint -q /mnt/storage; then
    pass "NFS export is reachable again after reboot"
else
    fail "NFS export not reachable after reboot"
fi

if (cd /mnt/storage/baseline && md5sum -c "$LAB_DIR/baseline-md5.txt") >/tmp/syscraft-baseline-post.log 2>&1; then
    pass "baseline data still matches after reboot"
else
    fail "baseline data missing or wrong after reboot"
    head -20 /tmp/syscraft-baseline-post.log || true
fi

if ssh_node1 "mdadm --detail /dev/md0" >/tmp/syscraft-mdadm-post.log 2>&1; then
    if grep -q 'Raid Level : raid10' /tmp/syscraft-mdadm-post.log \
        && grep -Eq 'Active Devices : 4' /tmp/syscraft-mdadm-post.log \
        && grep -Eq 'Failed Devices : 0' /tmp/syscraft-mdadm-post.log; then
        pass "mdadm still raid10 4/0 after reboot"
    else
        fail "mdadm state regressed after reboot"
        head -40 /tmp/syscraft-mdadm-post.log || true
    fi
else
    fail "mdadm --detail failed after reboot"
fi

if ssh_node1 "dmsetup table" >/tmp/syscraft-dmtable-post.log 2>/dev/null; then
    if grep -E '^disk[0-3]: .* delay ' /tmp/syscraft-dmtable-post.log >/dev/null; then
        scored_fail "dm-delay target reappeared after reboot - assemble script was not fixed"
        grep -E '^disk[0-3]:' /tmp/syscraft-dmtable-post.log || true
    else
        scored_pass "no dm-delay target reappeared after reboot"
    fi
else
    scored_fail "could not enumerate dmsetup table after reboot"
fi

if probe_out2=$(run_latency_probe 2>/tmp/syscraft-probe-post.err); then
    p95=$(echo "$probe_out2" | awk -F'[= ]' '/p95_ms/ {print $2}')
    p95_int=${p95%.*}
    echo "latency probe (post-reboot): $probe_out2"
    if [ -n "$p95_int" ] && [ "$p95_int" -lt "$P95_THRESHOLD_MS" ] 2>/dev/null; then
        pass "post-reboot p95 latency ${p95}ms < ${P95_THRESHOLD_MS}ms"
    else
        fail "post-reboot p95 latency ${p95}ms exceeds ${P95_THRESHOLD_MS}ms"
    fi
else
    fail "latency probe failed post-reboot"
    cat /tmp/syscraft-probe-post.err || true
fi

# 7. Bypass guards ------------------------------------------------------------
if ssh_node1 "findmnt -no SOURCE /srv/storage" >/tmp/syscraft-mount.log 2>&1; then
    src=$(cat /tmp/syscraft-mount.log | tr -d '[:space:]')
    if [ "$src" = "/dev/md0" ]; then
        pass "/srv/storage is still backed by /dev/md0"
    else
        fail "/srv/storage is no longer backed by /dev/md0 (got '${src}')"
    fi
else
    fail "could not inspect /srv/storage mount"
fi

if ssh_node1 "grep -E '^[^#]*/srv/storage[[:space:]]' /etc/exports" >/tmp/syscraft-exports.log 2>&1; then
    pass "/srv/storage is still exported via NFS"
else
    fail "/srv/storage is no longer in /etc/exports"
fi

if ssh_node1 "[ -d /var/lib/syscraft-disks ] && ls /var/lib/syscraft-disks/disk0.img /var/lib/syscraft-disks/disk1.img /var/lib/syscraft-disks/disk2.img /var/lib/syscraft-disks/disk3.img" >/dev/null 2>&1; then
    pass "all 4 backing disk images are present"
else
    fail "one or more backing disk images is missing - data was likely moved off RAID"
fi

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
