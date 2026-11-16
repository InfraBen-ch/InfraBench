# HotInfra ’26 task suite

These 12 task packages contain instructions, environment definitions, and verifiers. Reference solutions are included where available. The [evaluation runtime](../README.md#evaluation-runtime) is not included in this repository.

| Task | Backend | Scenario |
|---|---|---|
| [ipmi-node-power-recovery](ipmi-node-power-recovery/) | Bare metal | Out-of-band power recovery |
| [cassandra-nic-split-brain](cassandra-nic-split-brain/) | Bare metal | Cluster interface recovery |
| [cassandra-dead-node-removal](cassandra-dead-node-removal/) | Bare metal | Failed member removal |
| [cassandra-node-hung-recovery](cassandra-node-hung-recovery/) | Bare metal | Hung node recovery |
| [ceph-pool-degraded](ceph-pool-degraded/) | VM cluster | Storage pool repair |
| [vm-cassandra-cords-propagation](vm-cassandra-cords-propagation/) | VM cluster | Replicated data repair |
| [vm-ceph-bootstrap](vm-ceph-bootstrap/) | VM cluster | Distributed storage bring-up |
| [vm-fileserver-raid10-silent-disk](vm-fileserver-raid10-silent-disk/) | VM cluster | RAID fault diagnosis and recovery |
| [vm-pelican-namespace-key-mismatch](vm-pelican-namespace-key-mismatch/) | VM cluster | Federation signing key recovery |
| [vm-postgres-pgbouncer-drift](vm-postgres-pgbouncer-drift/) | VM cluster | Database connection pool configuration repair |
| [vm-slurm-puppet-unattended-cascade](vm-slurm-puppet-unattended-cascade/) | VM cluster | Scheduler and configuration recovery |
| [db-wal-recovery](db-wal-recovery/) | Docker | SQLite write-ahead log recovery |

The [hello-world](hello-world/) Docker example is available separately.

## Bare-metal setup

Use three dedicated hosts in a CloudLab experiment that permits the task’s fault injection. In a local copy of each bare-metal task, replace the `node0.example.invalid`, `node1.example.invalid`, and `node2.example.invalid` management hostnames with the hosts allocated to you. Keep the logical names `node0`, `node1`, and `node2` and use the cluster network described in the task. The runtime supplies `/etc/syscraft/cluster-info` and `/opt/syscraft/cloudlab-cluster-info.sh`.

For the IPMI power recovery and Cassandra hung-node tasks, provision an account with power-control access to the assigned BMCs. Supply `IPMI_USER` and `IPMI_PASSWORD` as shell assignments in `/etc/syscraft/ipmi-credentials.env` on the primary node. Keep the file outside the task package, owned by root with mode `0600`. Use trial-scoped credentials and remove the file after the run.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for task authoring.
