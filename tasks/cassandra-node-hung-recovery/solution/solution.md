# Reference Solution

For the IPMI examples, load the trial credentials from `/etc/syscraft/ipmi-credentials.env`, export `IPMI_PASSWORD`, and set `NODE1_BMC` from the trial cluster information.

## Step 1 — Assess the cluster state

```bash
nodetool status
# → DN  10.10.1.2  ...   ← node1 is down
```

## Step 2 — Try SSH to node1 (fails)

```bash
ssh -o ConnectTimeout=10 root@10.10.1.2
# → Connection timed out
# SSH is dead — but is the node powered off, or is the OS hung?
```

## Step 3 — Check IPMI power state (key diagnostic step)

```bash
ipmitool -I lan -H "$NODE1_BMC" -U "$IPMI_USER" -E chassis power status
# → Chassis Power is on
```

**Critical insight**: The node is powered ON. This means `chassis power on` will be a no-op.
The OS has hung (kernel panic). The correct fix is a forced reboot: `chassis power cycle` or `chassis power reset`.

## Step 4 — Force-reboot the hung node via IPMI

```bash
ipmitool -I lan -H "$NODE1_BMC" -U "$IPMI_USER" -E chassis power cycle
# Cuts power and restores it — forces a clean reboot regardless of OS state
```

Alternative: `chassis power reset` (sends reset signal without full power cycle).

Wait ~90–120 seconds for POST + OS boot.

## Step 5 — Wait for SSH to return, then start Cassandra

```bash
# Poll for SSH availability
until ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@10.10.1.2 "echo up"; do
    sleep 15
done

# Cassandra is set to manual start (systemctl is disabled)
ssh root@10.10.1.2 "systemctl start cassandra"
```

## Step 6 — Wait for node1 to rejoin the ring

```bash
# Watch until all 3 nodes are UN
watch nodetool status
# → UN  10.10.1.1  ...
# → UN  10.10.1.2  ...   ← node1 back
# → UN  10.10.1.3  ...
```

This typically takes 1–3 minutes as Cassandra gossip converges.

## Step 7 — Verify QUORUM reads

```bash
cqlsh 10.10.1.1 -e "CONSISTENCY QUORUM; SELECT COUNT(*) FROM bench.kv;"
# → 5

cqlsh 10.10.1.3 -e "CONSISTENCY QUORUM; SELECT COUNT(*) FROM bench.kv;"
# → 5
```

## Root Cause Summary

node1 suffered a kernel panic — its OS halted without rebooting (kernel.panic=0). IPMI confirmed the machine was still powered on, which rules out a simple power failure. The correct recovery path is a forced reboot via `ipmitool chassis power cycle` (or `power reset`), not `chassis power on` (which is a no-op on an already-on machine).

After reboot, Cassandra must be manually started (it is configured with `systemctl disable`) and then rejoins the ring automatically.

## Key Concepts

| IPMI Command | Effect | When to use |
|---|---|---|
| `chassis power on` | Powers on from OFF state | Node is powered OFF |
| `chassis power off` | Hard power off | Emergency shutdown |
| `chassis power cycle` | Power off → on | OS hung, need hard reboot |
| `chassis power reset` | Hard reset signal | OS hung, need hard reboot |
| `chassis power soft` | ACPI graceful shutdown | OS responsive |

**`chassis power on` on an already-on node is a no-op** — this is the key trap. Agents who don't check power status first may get stuck here.
