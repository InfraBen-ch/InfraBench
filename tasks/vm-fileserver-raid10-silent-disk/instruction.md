You are on call for a two-node NFS fileserver used by local researchers. Your shell starts on `node0`; you may SSH as `root` to `node1`.

## Current operational picture

- `node1` serves shared storage over NFS; `node0` mounts it at `/mnt/storage`.
- Basic checks look fine: the export is up, the array reports healthy, and small reads succeed.
- Under sustained concurrent reads, tail latency through NFS becomes very high and workloads stall.
- The problem started after a recent maintenance window and persists across reboot.

## Business impact

The fileserver is technically up, but users cannot pull datasets at acceptable speed when many jobs read at once.

## Goal

Restore normal fileserver performance under concurrent load. Keep existing data and the current storage layout; do not relocate the export or wipe backing storage. The fix must still work after rebooting the fileserver.
