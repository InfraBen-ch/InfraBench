#!/usr/bin/env bash
# Runs on node0. Builds a 4-disk mdadm RAID10 on node1 backed by sparse files
# wrapped in device-mapper targets. Three members are dm-linear pass-throughs;
# the fourth (disk3) is wrapped in dm-delay so reads against it are slow but
# produce no I/O errors. A boot-time assemble script re-applies the same
# layering on every reboot.
set -euo pipefail

LAB_DIR="/opt/syscraft-raid"
INCIDENT_ID="raid10-silent-disk-20260518"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

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

require_ip node1 >/dev/null
wait_for_ssh node1

mkdir -p "$LAB_DIR" /etc/syscraft
cat >/etc/syscraft/raid-silent-disk.env <<EOF
INCIDENT_ID=${INCIDENT_ID}
FILESERVER_NODE=node1
EXPORT_PATH=/srv/storage
CLIENT_MOUNT=/mnt/storage
BASELINE_DIR=/srv/storage/baseline
BIG_FILE=/srv/storage/baseline/big.bin
EOF

# ---- All durable storage state is materialized on node1 --------------------

ssh "${SSH_OPTS[@]}" node1 'bash -se' <<'NODE'
set -euo pipefail

DISK_DIR=/var/lib/syscraft-disks
LAB_DIR=/opt/syscraft-raid
mkdir -p "$DISK_DIR" "$LAB_DIR"

# Clean any prior state idempotently.
systemctl stop nfs-server 2>/dev/null || true
umount /srv/storage 2>/dev/null || true
mdadm --stop /dev/md0 2>/dev/null || true
for name in disk0 disk1 disk2 disk3; do
    dmsetup remove "$name" 2>/dev/null || true
done
losetup -D 2>/dev/null || true

# Sparse 1 GiB backing files.
for i in 0 1 2 3; do
    truncate -s 1G "$DISK_DIR/disk$i.img"
done

# Initial loop + dm setup: 3 pass-through dm-linear, 1 dm-delay (read=200ms).
declare -a LOOPS
for i in 0 1 2 3; do
    LOOPS[$i]=$(losetup --find --show "$DISK_DIR/disk$i.img")
done
SIZE_SECTORS=$(blockdev --getsz "${LOOPS[0]}")

dmsetup create disk0 --table "0 $SIZE_SECTORS linear ${LOOPS[0]} 0"
dmsetup create disk1 --table "0 $SIZE_SECTORS linear ${LOOPS[1]} 0"
dmsetup create disk2 --table "0 $SIZE_SECTORS linear ${LOOPS[2]} 0"
# dm-delay: 200ms read delay, 0ms write delay. Adds latency, no errors.
dmsetup create disk3 --table "0 $SIZE_SECTORS delay ${LOOPS[3]} 0 200 ${LOOPS[3]} 0 0"

# Create the array. --metadata=1.2 stores superblock 4K from start so the
# dm-mapper devices see consistent metadata across re-creates.
mdadm --create /dev/md0 --level=10 --raid-devices=4 --metadata=1.2 \
    --force --run --assume-clean \
    /dev/mapper/disk0 /dev/mapper/disk1 /dev/mapper/disk2 /dev/mapper/disk3

mkfs.ext4 -F -L syscraft-vicepa /dev/md0
mount /dev/md0 /srv/storage

# Baseline data: 4 small files + 1 200 MiB random-data file for latency probe.
mkdir -p /srv/storage/baseline
for i in 1 2 3 4; do
    dd if=/dev/urandom of="/srv/storage/baseline/sample-$i.bin" bs=1M count=4 status=none
done
dd if=/dev/urandom of=/srv/storage/baseline/big.bin bs=1M count=200 status=none
sync

(cd /srv/storage/baseline && md5sum sample-*.bin big.bin) >"$LAB_DIR/baseline-md5.txt"
cp "$LAB_DIR/baseline-md5.txt" /srv/storage/baseline-md5.txt
sync

# NFS export.
cat >/etc/exports <<'EOF'
/srv/storage 192.168.100.0/24(rw,sync,no_root_squash,no_subtree_check)
EOF
systemctl enable nfs-server >/dev/null
systemctl restart nfs-server
exportfs -ra

# Boot-time assemble script that re-establishes loops + dm targets + array.
cat >/usr/local/sbin/syscraft-assemble-raid <<'SCRIPT'
#!/usr/bin/env bash
# syscraft-managed: re-establish RAID10 fileserver storage at boot.
# Maintenance baseline wraps disk3 in dm-delay to throttle reads.
set -euo pipefail

DISK_DIR=/var/lib/syscraft-disks

declare -a LOOPS
for i in 0 1 2 3; do
    existing=$(losetup -j "$DISK_DIR/disk$i.img" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -n "$existing" ]; then
        LOOPS[$i]="$existing"
    else
        LOOPS[$i]=$(losetup --find --show "$DISK_DIR/disk$i.img")
    fi
done
SIZE_SECTORS=$(blockdev --getsz "${LOOPS[0]}")

for i in 0 1 2; do
    if ! dmsetup info "disk$i" >/dev/null 2>&1; then
        dmsetup create "disk$i" --table "0 $SIZE_SECTORS linear ${LOOPS[$i]} 0"
    fi
done
if ! dmsetup info disk3 >/dev/null 2>&1; then
    dmsetup create disk3 --table "0 $SIZE_SECTORS delay ${LOOPS[3]} 0 200 ${LOOPS[3]} 0 0"
fi

if [ ! -e /dev/md0 ]; then
    mdadm --assemble /dev/md0 \
        /dev/mapper/disk0 /dev/mapper/disk1 \
        /dev/mapper/disk2 /dev/mapper/disk3
fi

mountpoint -q /srv/storage || mount /dev/md0 /srv/storage
exportfs -ra
SCRIPT
chmod +x /usr/local/sbin/syscraft-assemble-raid

cat >/etc/systemd/system/syscraft-raid-disks.service <<'EOF'
[Unit]
Description=Syscraft RAID10 fileserver assemble (loops + dm-mapper + mdadm + NFS)
After=local-fs.target
Before=nfs-server.service
Wants=nfs-server.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/syscraft-assemble-raid

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable syscraft-raid-disks.service

cat >"$LAB_DIR/incident-note.txt" <<'EOF'
mdadm --detail /dev/md0 reports clean and all 4 members active. Single-file
reads look fine but sustained concurrent reads through NFS have very high p95
latency. The boot-time assemble script under /usr/local/sbin re-applies the
maintenance device-mapper layering on every reboot.
EOF
NODE

# ---- Configure node0 as NFS client + capture baseline checksums ------------

scp "${SSH_OPTS[@]}" node1:/opt/syscraft-raid/baseline-md5.txt "$LAB_DIR/baseline-md5.txt"

mkdir -p /mnt/storage
mount -t nfs node1:/srv/storage /mnt/storage
# Persist client mount across node0 reboot (harmless even though verifier only
# reboots node1).
grep -q 'node1:/srv/storage' /etc/fstab || \
    echo 'node1:/srv/storage /mnt/storage nfs rw,_netdev,noatime 0 0' >> /etc/fstab

(cd /mnt/storage/baseline && md5sum -c "$LAB_DIR/baseline-md5.txt") >/tmp/syscraft-baseline-check.txt 2>&1

echo "Injected RAID10 silent disk degradation incident"
