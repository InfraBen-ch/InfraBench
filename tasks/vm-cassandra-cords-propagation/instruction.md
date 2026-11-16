You are on-call for a **three-node replicated ledger service**. Your shell is on **`node0`**. Peers **`node1`** and **`node2`** are reachable as **root over SSH** using the key already on this host.

## Context

The cluster backs an internal treasury-style ledger API. Replication is up; CPU, disk, and latency dashboards look **normal**. There is no obvious outage or slowdown.

## What operators see

Downstream reconciliation and spot checks report **conflicting ledger values for several accounts** depending on which backend participates in the read. Some balances and their audit digests do not agree across replicas, and one bad value may have been spread by the normal read path.

At the same time, the lightweight synthetic health probe still succeeds:

- `http://127.0.0.1:8080/health`

That check only exercises a shallow liveness path. It is **not** evidence that every persisted replica agrees.

## Your goal

Diagnose from what you can observe on the machines: services, logs, Cassandra tools, CQL reads, and persisted data. Restore durable semantic agreement for the in-scope ledger accounts:

- all replicas should return the committed balance and matching audit digest;
- the cluster must still accept new replicated writes;
- unrelated ledger rows must remain unchanged;
- stale wrong data must not remain recoverable from on-disk state after you are done.

**Do not** treat a green `/health` response alone as resolution.
