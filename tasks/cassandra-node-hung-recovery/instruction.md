# Cassandra Node Recovery

## Situation

You are on-call SRE for a 3-node Cassandra 4.1.x cluster running on bare-metal servers. An alert fired: node1 is unreachable and the cluster is degraded.

**Cluster nodes:**
- `node0` — 10.10.1.1 (you are here)
- `node1` — 10.10.1.2 (unreachable)
- `node2` — 10.10.1.3 (`ssh node2` works)

**Keyspace:** `bench`
**Table:** `bench.kv` (schema: `id int PRIMARY KEY, val text`)
**Replication factor:** 3
**Consistency level in use:** QUORUM

## Symptoms

- `nodetool status` shows node1 as `DN` (Down/Normal)
- SSH to node1 is not responding

## Your Task

Restore the cluster to a fully healthy 3-node state. All three nodes must be `UN` and QUORUM reads must succeed from both surviving nodes.

## Available Tools

- `nodetool` — Cassandra ring management
- `cqlsh 10.10.1.1` or `cqlsh 10.10.1.3` — CQL shell
- `ssh node2` — access to node2
- `ipmitool` — out-of-band hardware management
  - Discover the assigned BMC addresses from `/etc/syscraft/cluster-info` and use the provisioned IPMI account.
- Standard Linux tools

## Constraints

- Do not wipe any Cassandra data directories on any node
- All three Cassandra nodes must be running and in `UN` state by the end
