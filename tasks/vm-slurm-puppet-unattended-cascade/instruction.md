You are on call for a small research SLURM cluster. Your shell starts on `node0`; you may SSH as `root` to `node1` and `node2`.

## Current operational picture

- `node0` runs the SLURM controller; `node1` and `node2` are compute nodes.
- The cluster looks healthy for light checks: `sinfo` is fine and a single `srun --ntasks=1 hostname` succeeds.
- Under realistic concurrent use, jobs fail and compute nodes drop out of service.
- The problem started after a recent maintenance window.

## Business impact

Researchers cannot run workloads reliably. Quick manual tweaks sometimes seem to help briefly, then the cluster regresses again.

## Goal

Restore normal SLURM operation: all nodes available, concurrent jobs succeed, and the fix still holds after configuration re-application and compute-node reboots. Do not disable standing platform services or rebuild the cluster from scratch.
