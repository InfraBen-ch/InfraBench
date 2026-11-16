#!/usr/bin/env bash
# Reference recovery: identify the slow array member by latency probing,
# fail+remove it, recreate the dm target as a plain dm-linear pass-through,
# re-add it to the array, wait for resync, and edit the boot-time assemble
# script so the dm-delay layer does not return after a reboot.
set -euo pipefail

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

echo "Identifying the slow RAID10 member on node1"
ssh "${SSH_OPTS[@]}" node1 'bash -se' <<'NODE'
set -euo pipefail

# Drop caches so the latency probe hits the underlying device-mapper layer.
echo 3 > /proc/sys/vm/drop_caches

# Probe each /dev/mapper/disk* directly with O_DIRECT reads and pick the
# slowest. The dm-delay wrapper adds 200ms per read; the others return in <5ms.
slowest_name=""
slowest_ms=0
for i in 0 1 2 3; do
    dev="/dev/mapper/disk$i"
    total=0
    for _ in 1 2 3 4 5; do
        # 4 KiB direct read at a random offset within the first 256 MiB.
        skip=$((RANDOM % 65536))
        start_ns=$(date +%s%N)
        dd if="$dev" of=/dev/null bs=4096 count=1 skip="$skip" iflag=direct status=none
        end_ns=$(date +%s%N)
        elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
        total=$(( total + elapsed_ms ))
    done
    avg=$(( total / 5 ))
    echo "disk$i average 4K read = ${avg}ms (raw total ${total}ms over 5 reads)"
    if [ "$avg" -gt "$slowest_ms" ]; then
        slowest_ms=$avg
        slowest_name="disk$i"
    fi
done

echo "Slowest member: ${slowest_name} at ~${slowest_ms}ms average read"

if [ -z "$slowest_name" ]; then
    echo "could not identify slowest member" >&2
    exit 1
fi

# Walk the dm-mapper table to discover the backing loop and reload as linear.
mapper_path="/dev/mapper/${slowest_name}"
backing_loop=$(dmsetup table "$slowest_name" | awk '{print $4}')
size_sectors=$(dmsetup table "$slowest_name" | awk '{print $2}')
echo "Replacing ${slowest_name} (backed by ${backing_loop}) with a dm-linear pass-through"

# Fail and remove the slow member from the array.
mdadm /dev/md0 --fail "$mapper_path"
mdadm /dev/md0 --remove "$mapper_path"

# Replace the dm target with a plain linear pass-through.
dmsetup remove "$slowest_name"
dmsetup create "$slowest_name" --table "0 $size_sectors linear $backing_loop 0"

# Re-add to the array and wait for resync.
mdadm /dev/md0 --add "$mapper_path"
echo "Waiting for resync"
while grep -q 'recovery' /proc/mdstat 2>/dev/null; do
    grep -A1 'recovery' /proc/mdstat | tail -1 || true
    sleep 5
done
mdadm --wait /dev/md0 2>/dev/null || true

# Update the boot-time assemble script: drop the dm-delay wrapper for disk3.
# Rewrite the script so every disk0..disk3 is created as a plain pass-through.
cat >/usr/local/sbin/syscraft-assemble-raid <<'SCRIPT'
#!/usr/bin/env bash
# syscraft-managed: re-establish RAID10 fileserver storage at boot.
# Repaired: all four members are dm-linear pass-throughs.
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

for i in 0 1 2 3; do
    if ! dmsetup info "disk$i" >/dev/null 2>&1; then
        dmsetup create "disk$i" --table "0 $SIZE_SECTORS linear ${LOOPS[$i]} 0"
    fi
done

if [ ! -e /dev/md0 ]; then
    mdadm --assemble /dev/md0 \
        /dev/mapper/disk0 /dev/mapper/disk1 \
        /dev/mapper/disk2 /dev/mapper/disk3
fi

mountpoint -q /srv/storage || mount /dev/md0 /srv/storage
exportfs -ra
SCRIPT
chmod +x /usr/local/sbin/syscraft-assemble-raid

echo "Final state:"
mdadm --detail /dev/md0 | grep -E 'Raid Level|Active|Failed|State '
dmsetup table
NODE

echo "RAID10 silent disk degradation recovery complete"
