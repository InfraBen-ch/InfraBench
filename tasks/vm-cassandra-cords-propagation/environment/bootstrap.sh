#!/usr/bin/env bash
# Runs on node0. Builds the cluster, injects three silent SSTable payload faults,
# then intentionally exercises Cassandra read repair for one affected account.
set -euo pipefail

CASSANDRA_HOME="/opt/apache-cassandra-4.1.8"
CLUSTER_NAME="syscraft-integrity-lab"
KEYSPACE="integrity_lab"
TABLE="ledger"
LAB_DIR="/opt/syscraft-lab"
EXPECTED_FILE="${LAB_DIR}/expected-ledger.tsv"
AFFECTED_FILE="${LAB_DIR}/affected-ledger.tsv"
UNAFFECTED_FILE="${LAB_DIR}/unaffected-ledger.tsv"
PROTECTED_FILE="${LAB_DIR}/protected-unaffected-writetime.tsv"
FAULT_PLAN_FILE="${LAB_DIR}/fault-plan.tsv"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectionAttempts=10 -o ConnectTimeout=10)

require_ip() {
    local node_name=$1
    local node_ip
    node_ip=$(getent hosts "$node_name" | awk '{print $1; exit}')
    if [ -z "$node_ip" ]; then
        echo "failed to resolve ${node_name}" >&2
        exit 1
    fi
    printf '%s\n' "$node_ip"
}

NODE0_IP=$(require_ip node0)
NODE1_IP=$(require_ip node1)
NODE2_IP=$(require_ip node2)
SEEDS="${NODE0_IP}:7000,${NODE1_IP}:7000,${NODE2_IP}:7000"

run_on_node() {
    local node_name=$1
    shift
    local command_text=$1
    if [ "$node_name" = "node0" ]; then
        bash -se <<<"$command_text"
    else
        ssh "${SSH_OPTS[@]}" "$node_name" 'bash -se' <<<"$command_text"
    fi
}

node_ip_var() {
    case "$1" in
        node0) printf '%s\n' "$NODE0_IP" ;;
        node1) printf '%s\n' "$NODE1_IP" ;;
        node2) printf '%s\n' "$NODE2_IP" ;;
        *) echo "unknown node $1" >&2; exit 1 ;;
    esac
}

configure_node() {
    local node_name=$1
    local node_ip=$2
    run_on_node "$node_name" "
        set -euo pipefail
        systemctl stop cassandra || true
        rm -rf /var/lib/cassandra/* /var/log/cassandra/*
        mkdir -p /var/lib/cassandra/data /var/lib/cassandra/commitlog /var/lib/cassandra/saved_caches /var/log/cassandra ${LAB_DIR}

        cp ${CASSANDRA_HOME}/conf/cassandra.yaml ${CASSANDRA_HOME}/conf/cassandra.yaml.orig
        python3 - <<'PY'
from pathlib import Path

path = Path('${CASSANDRA_HOME}/conf/cassandra.yaml')
text = path.read_text()
replacements = {
    \"cluster_name: 'Test Cluster'\": \"cluster_name: '${CLUSTER_NAME}'\",
    '- seeds: \"127.0.0.1:7000\"': '- seeds: \"${SEEDS}\"',
    'listen_address: localhost': 'listen_address: ${node_ip}',
    'rpc_address: localhost': 'rpc_address: 0.0.0.0',
    '# broadcast_rpc_address: 1.2.3.4': 'broadcast_rpc_address: ${node_ip}',
    'endpoint_snitch: SimpleSnitch': 'endpoint_snitch: GossipingPropertyFileSnitch',
    'num_tokens: 16': 'num_tokens: 16',
}
for old, new in replacements.items():
    if old not in text:
        raise SystemExit(f'missing expected Cassandra config line: {old}')
    text = text.replace(old, new)
path.write_text(text)
PY

        cat >${CASSANDRA_HOME}/conf/cassandra-rackdc.properties <<EOF
dc=dc1
rack=rack1
prefer_local=true
EOF

        cat >>${CASSANDRA_HOME}/conf/cassandra-env.sh <<'EOF'
MAX_HEAP_SIZE=\"768M\"
HEAP_NEWSIZE=\"256M\"
JVM_OPTS=\"\$JVM_OPTS -Dcassandra.skip_wait_for_gossip_to_settle=0\"
EOF

        cat >/etc/systemd/system/cassandra.service <<'EOF'
[Unit]
Description=Apache Cassandra
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
Environment=CASSANDRA_HOME=/opt/apache-cassandra-4.1.8
ExecStart=/opt/apache-cassandra/bin/cassandra -f -R
Restart=on-failure
RestartSec=5
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable cassandra
        systemctl restart cassandra
    "
}

wait_for_cassandra_port() {
    local node_ip=$1
    local attempt
    for attempt in $(seq 1 90); do
        if nc -z "$node_ip" 9042; then
            return 0
        fi
        sleep 2
    done
    echo "Cassandra CQL port did not open on ${node_ip}" >&2
    return 1
}

wait_for_cluster_ready() {
    local attempt
    for attempt in $(seq 1 90); do
        if nc -z "$NODE0_IP" 9042 && nc -z "$NODE1_IP" 9042 && nc -z "$NODE2_IP" 9042; then
            return 0
        fi
        sleep 3
    done
    echo "cluster never became CQL-reachable on all nodes" >&2
    return 1
}

run_cql() {
    local cql_file=$1
    /usr/local/bin/cassandra-cql "$NODE0_IP" 9042 -f "$cql_file"
}

# The CQL port opening does not mean gossip/schema have settled; the initial
# bulk load can hit OperationTimedOut on a fresh cluster. The load file starts
# with DROP KEYSPACE IF EXISTS, so re-running it from scratch is safe.
run_cql_with_retry() {
    local cql_file=$1
    local attempt
    for attempt in $(seq 1 5); do
        if run_cql "$cql_file"; then
            return 0
        fi
        echo "CQL load attempt ${attempt} failed; waiting for cluster to settle before retry" >&2
        wait_for_cluster_ready
        sleep 10
    done
    echo "CQL load failed after retries" >&2
    return 1
}

write_audit_tool() {
    cat >/usr/local/bin/ledger-audit <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

KEYSPACE="integrity_lab"
TABLE="ledger"
EXPECTED_FILE="/opt/syscraft-lab/expected-ledger.tsv"
NODES=(node0 node1 node2)

if [ ! -s "$EXPECTED_FILE" ]; then
    echo "missing expected ledger manifest: $EXPECTED_FILE" >&2
    exit 2
fi

query_file=$(mktemp)
failures=0
for node in "${NODES[@]}"; do
    node_ip=$(getent hosts "$node" | awk '{print $1; exit}')
    if [ -z "$node_ip" ]; then
        echo "FAIL ${node}: cannot resolve hostname"
        failures=$((failures + 1))
        continue
    fi

    while IFS=$'\t' read -r account expected_balance expected_audit; do
        [ -n "$account" ] || continue
        cat >"$query_file" <<CQL
CONSISTENCY ONE;
SELECT balance, audit FROM ${KEYSPACE}.${TABLE} WHERE account = '${account}';
CQL

        out_file=$(mktemp)
        if ! /usr/local/bin/cassandra-cql "$node_ip" 9042 -f "$query_file" >"$out_file" 2>&1; then
            echo "FAIL ${node} ${account}: cql read failed"
            cat "$out_file"
            failures=$((failures + 1))
            rm -f "$out_file"
            continue
        fi

        if grep -Fxq "${expected_balance} | ${expected_audit}" "$out_file"; then
            echo "PASS ${node} ${account}: digest matched"
        else
            echo "FAIL ${node} ${account}: digest mismatch"
            cat "$out_file"
            failures=$((failures + 1))
        fi
        rm -f "$out_file"
    done <"$EXPECTED_FILE"
done

rm -f "$query_file"

if [ "$failures" -ne 0 ]; then
    echo "ledger audit failed with ${failures} mismatches"
    exit 1
fi

echo "ledger audit passed on all replicas"
EOF
    chmod +x /usr/local/bin/ledger-audit
    for node in node1 node2; do
        scp "${SSH_OPTS[@]}" /usr/local/bin/ledger-audit "${node}:/usr/local/bin/ledger-audit"
    done
}

write_health_service() {
    cat >/usr/local/bin/ledger-health-server <<'PY'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
import subprocess

NODE0 = "127.0.0.1"
NODES = ("127.0.0.1", "node1", "node2")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_response(404)
            self.end_headers()
            return

        cql = subprocess.run(
            ["/usr/local/bin/cassandra-cql", NODE0, "9042", "-e", "SELECT keyspace_name FROM system_schema.keyspaces;"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )
        ports = []
        for node in NODES:
            probe = subprocess.run(
                ["bash", "-lc", f"nc -z {node} 9042"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
                check=False,
            )
            ports.append(probe.returncode == 0)
        healthy = cql.returncode == 0 and all(ports)
        body = b'{"status":"ok","checks":["cluster-cql"]}\n' if healthy else b'{"status":"degraded"}\n'
        self.send_response(200 if healthy else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


HTTPServer(("127.0.0.1", 8080), Handler).serve_forever()
PY
    chmod +x /usr/local/bin/ledger-health-server

    cat >/etc/systemd/system/ledger-health.service <<'EOF'
[Unit]
Description=Misleading ledger application health endpoint
After=cassandra.service
Wants=cassandra.service

[Service]
Type=simple
ExecStart=/usr/local/bin/ledger-health-server
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ledger-health
    systemctl restart ledger-health
}

load_ledger_data() {
    mkdir -p "$LAB_DIR"
    : >"$EXPECTED_FILE"
    : >"$AFFECTED_FILE"
    : >"$UNAFFECTED_FILE"
    : >"$PROTECTED_FILE"
    : >"$FAULT_PLAN_FILE"

    cql_file=$(mktemp)
    cat >"$cql_file" <<CQL
DROP KEYSPACE IF EXISTS ${KEYSPACE};
CREATE KEYSPACE ${KEYSPACE}
  WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 3};

CREATE TABLE ${KEYSPACE}.${TABLE} (
  account text PRIMARY KEY,
  balance text,
  audit text
) WITH compression = {'enabled': 'false'}
  AND compaction = {'class': 'SizeTieredCompactionStrategy', 'enabled': 'false'}
  AND read_repair = 'BLOCKING';

CONSISTENCY ALL;
CQL

    for i in $(seq -f "%03g" 1 64); do
        account="acct-${i}"
        token=$(printf 'good-%s-%s' "$i" "$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')")
        token=${token:0:12}
        balance="ledger-payload-${i}-${token}-anchor"
        audit=$(printf '%s:%s\n' "$account" "$balance" | sha256sum | awk '{print $1}')
        printf '%s\t%s\t%s\n' "$account" "$balance" "$audit" >>"$EXPECTED_FILE"
        case "$account" in
            acct-017 | acct-042 | acct-059)
                bad_token=$(printf 'zzzz-%s-%s' "$i" "$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')")
                bad_token=${bad_token:0:12}
                bad_balance="ledger-payload-${i}-${bad_token}-anchor"
                bad_audit=$(printf '%s:%s\n' "$account" "$bad_balance" | sha256sum | awk '{print $1}')
                printf '%s\t%s\t%s\t%s\t%s\n' "$account" "$balance" "$audit" "$bad_balance" "$bad_audit" >>"$AFFECTED_FILE"
                ;;
            acct-005 | acct-023 | acct-038 | acct-064)
                printf '%s\t%s\t%s\n' "$account" "$balance" "$audit" >>"$UNAFFECTED_FILE"
                ;;
        esac
        cat >>"$cql_file" <<CQL
INSERT INTO ${KEYSPACE}.${TABLE} (account, balance, audit)
VALUES ('${account}', '${balance}', '${audit}');
CQL
    done

    awk -F '\t' '$1 == "acct-017" { print "acct-017\tnode1\tisolated\t" $2 "\t" $3 "\t" $4 "\t" $5 }' "$AFFECTED_FILE" >>"$FAULT_PLAN_FILE"
    awk -F '\t' '$1 == "acct-042" { print "acct-042\tnode1\tpropagated\t" $2 "\t" $3 "\t" $4 "\t" $5 }' "$AFFECTED_FILE" >>"$FAULT_PLAN_FILE"
    awk -F '\t' '$1 == "acct-059" { print "acct-059\tnode2\tpartial\t" $2 "\t" $3 "\t" $4 "\t" $5 }' "$AFFECTED_FILE" >>"$FAULT_PLAN_FILE"

    run_cql_with_retry "$cql_file"
    rm -f "$cql_file"

    while IFS=$'\t' read -r account _balance _audit; do
        query_file=$(mktemp)
        cat >"$query_file" <<CQL
CONSISTENCY ALL;
SELECT account, writetime(balance) FROM ${KEYSPACE}.${TABLE} WHERE account = '${account}';
CQL
        writetime=$(/usr/local/bin/cassandra-cql "$NODE0_IP" 9042 -f "$query_file" | awk -F ' \\| ' -v account="$account" '$1 == account { print $2; exit }')
        rm -f "$query_file"
        if [ -z "$writetime" ]; then
            echo "failed to capture protected writetime for ${account}" >&2
            exit 1
        fi
        printf '%s\t%s\n' "$account" "$writetime" >>"$PROTECTED_FILE"
    done <"$UNAFFECTED_FILE"

    for node in node1 node2; do
        scp "${SSH_OPTS[@]}" "$EXPECTED_FILE" "${node}:${EXPECTED_FILE}"
        scp "${SSH_OPTS[@]}" "$AFFECTED_FILE" "${node}:${AFFECTED_FILE}"
        scp "${SSH_OPTS[@]}" "$UNAFFECTED_FILE" "${node}:${UNAFFECTED_FILE}"
        scp "${SSH_OPTS[@]}" "$PROTECTED_FILE" "${node}:${PROTECTED_FILE}"
        scp "${SSH_OPTS[@]}" "$FAULT_PLAN_FILE" "${node}:${FAULT_PLAN_FILE}"
    done

    for node in node0 node1 node2; do
        run_on_node "$node" "${CASSANDRA_HOME}/bin/nodetool flush ${KEYSPACE} ${TABLE}"
    done
    assert_fault_payloads_visible
}

flush_all_replicas() {
    for node in node0 node1 node2; do
        run_on_node "$node" "${CASSANDRA_HOME}/bin/nodetool flush ${KEYSPACE} ${TABLE}"
    done
}

assert_fault_payloads_visible() {
    local attempt
    for attempt in $(seq 1 12); do
        local all_visible=1
        while IFS=$'\t' read -r account node_name _mode expected_balance _expected_audit _bad_balance _bad_audit; do
            [ -n "$account" ] || continue
            if ! run_on_node "$node_name" "python3 - '${KEYSPACE}' '${TABLE}' '${account}' '${expected_balance}' <<'PY'
import sys
from pathlib import Path

keyspace, table, account, expected = sys.argv[1:]
roots = [
    Path('/opt/apache-cassandra-4.1.8/data/data') / keyspace,
    Path('/opt/apache-cassandra/data/data') / keyspace,
    Path('/var/lib/cassandra/data') / keyspace,
]


def list_data_files() -> list[Path]:
    primary: list[Path] = []
    fallback: list[Path] = []
    for root in roots:
        if not root.exists():
            continue
        primary.extend(root.glob(f'{table}-*/*-Data.db'))
        fallback.extend(path for path in root.rglob('*-Data.db') if f'/{table}-' in str(path))
    return sorted(set(primary)) or sorted(set(fallback))


data_files = list_data_files()
if not data_files:
    print(f'no SSTable Data.db files found for {keyspace}.{table} while checking {account}', file=sys.stderr)
    for root in roots:
        print(f'keyspace root {root}: exists={root.exists()}', file=sys.stderr)
        if root.exists():
            print('table dirs:', ', '.join(str(path) for path in sorted(root.glob(f'{table}-*'))) or '<none>', file=sys.stderr)
            print('Data.db files:', ', '.join(str(path) for path in sorted(root.rglob('*-Data.db'))) or '<none>', file=sys.stderr)
    raise SystemExit(1)

if any(expected.encode() in path.read_bytes() for path in data_files):
    print(f'visible {account} payload in {len(data_files)} SSTable Data.db file(s)')
    raise SystemExit(0)

print(f'{account} expected payload not visible in {len(data_files)} SSTable Data.db file(s)', file=sys.stderr)
raise SystemExit(2)
PY"; then
                all_visible=0
            fi
        done <"$FAULT_PLAN_FILE"

        if [ "$all_visible" -eq 1 ]; then
            return 0
        fi

        echo "Fault target SSTable payloads are not all visible after flush attempt ${attempt}; retrying"
        flush_all_replicas
        sleep 3
    done

    echo "fault target payloads were not visible in SSTable files after retries" >&2
    return 1
}

corrupted_balance_for() {
    local account=$1
    awk -F '\t' -v account="$account" '$1 == account { print $6; exit }' "$FAULT_PLAN_FILE"
}

count_corrupted_payload_nodes() {
    local account=$1
    local bad_balance
    bad_balance=$(corrupted_balance_for "$account")
    local count=0
    local node
    for node in node0 node1 node2; do
        if run_on_node "$node" "
            set -euo pipefail
            found=0
            for root in ${CASSANDRA_HOME}/data/data/${KEYSPACE} /opt/apache-cassandra/data/data/${KEYSPACE} /var/lib/cassandra/data/${KEYSPACE}; do
                [ -d \"\$root\" ] || continue
                if find \"\$root\" -path \"*/${TABLE}-*/*-Data.db\" -type f -print0 | xargs -0 -r grep -a -F -q '${bad_balance}'; then
                    found=1
                    break
                fi
            done
            [ \"\$found\" -eq 1 ]
        "; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

perturb_node() {
    local node_name=$2
    local plan_rows=$1
    [ -n "$plan_rows" ] || return 0

    run_on_node "$node_name" "
        set -euo pipefail
        ${CASSANDRA_HOME}/bin/nodetool drain
        systemctl stop cassandra
        sleep 3

        python3 - <<'PY'
import sys
from pathlib import Path

keyspace = '${KEYSPACE}'
table = '${TABLE}'
roots = [
    Path('${CASSANDRA_HOME}/data/data') / keyspace,
    Path('/opt/apache-cassandra/data/data') / keyspace,
    Path('/var/lib/cassandra/data') / keyspace,
]
plan_rows = '''${plan_rows}'''.strip().splitlines()


def list_data_files() -> list[Path]:
    primary: list[Path] = []
    fallback: list[Path] = []
    for root in roots:
        if not root.exists():
            continue
        primary.extend(root.glob(f'{table}-*/*-Data.db'))
        fallback.extend(path for path in root.rglob('*-Data.db') if f'/{table}-' in str(path))
    return sorted(set(primary)) or sorted(set(fallback))


data_files = list_data_files()
print(f'found {len(data_files)} SSTable Data.db file(s) for {keyspace}.{table}')
if not data_files:
    for root in roots:
        print(f'keyspace root {root}: exists={root.exists()}', file=sys.stderr)
        if root.exists():
            print('table dirs:', ', '.join(str(path) for path in sorted(root.glob(f'{table}-*'))) or '<none>', file=sys.stderr)
            print('Data.db files:', ', '.join(str(path) for path in sorted(root.rglob('*-Data.db'))) or '<none>', file=sys.stderr)
    raise SystemExit('no SSTable Data.db files found for mutation')

for row in plan_rows:
    account, _node_name, _mode, expected_balance, _expected_audit, bad_balance, _bad_audit = row.split('\t')
    target = expected_balance.encode()
    replacement = bad_balance.encode()
    if len(target) != len(replacement):
        raise SystemExit(f'replacement for {account} must preserve byte length')
    for path in data_files:
        data = path.read_bytes()
        if target in data:
            path.write_bytes(data.replace(target, replacement, 1))
            print(f'mutated {account} in {path}')
            break
    else:
        raise SystemExit(f'target payload for {account} not found in {len(data_files)} SSTable Data.db file(s)')
PY

        systemctl start cassandra
    "

    wait_for_cassandra_port "$(node_ip_var "$node_name")"
    wait_for_cluster_ready
}

inject_faults() {
    local node
    local plan_rows
    for node in node1 node2; do
        plan_rows=$(awk -F '\t' -v node="$node" '$2 == node { print }' "$FAULT_PLAN_FILE")
        perturb_node "$plan_rows" "$node"
    done
}

trigger_read_repair_propagation() {
    local account="acct-042"
    local query_file
    query_file=$(mktemp)
    cat >"$query_file" <<CQL
CONSISTENCY QUORUM;
SELECT balance, audit FROM ${KEYSPACE}.${TABLE} WHERE account = '${account}';
CONSISTENCY ALL;
SELECT balance, audit FROM ${KEYSPACE}.${TABLE} WHERE account = '${account}';
CQL

    local attempt
    for attempt in $(seq 1 10); do
        echo "Triggering CL=QUORUM/ALL read repair attempt ${attempt} for ${account}:"
        for node in node0 node1 node2; do
            /usr/local/bin/cassandra-cql "$(node_ip_var "$node")" 9042 -f "$query_file" || true
        done
        flush_all_replicas

        local corrupt_count
        corrupt_count=$(count_corrupted_payload_nodes "$account")
        echo "Corrupted payload for ${account} is present on ${corrupt_count}/3 nodes after read repair attempt ${attempt}"
        if [ "$corrupt_count" -eq 3 ]; then
            rm -f "$query_file"
            return 0
        fi
        sleep 3
    done

    rm -f "$query_file"
    echo "read repair did not propagate the corrupted payload to every replica" >&2
    return 1
}

for node in node0 node1 node2; do
    configure_node "$node" "$(node_ip_var "$node")"
done

wait_for_cassandra_port "$NODE0_IP"
wait_for_cassandra_port "$NODE1_IP"
wait_for_cassandra_port "$NODE2_IP"
wait_for_cluster_ready

write_audit_tool
write_health_service
load_ledger_data

echo "Baseline audit before fault:"
ledger-audit

inject_faults
trigger_read_repair_propagation

echo "Post-propagation cluster reachability:"
for ip in "$NODE0_IP" "$NODE1_IP" "$NODE2_IP"; do
    nc -z "$ip" 9042
done

echo "Post-propagation application health:"
curl -fsS http://127.0.0.1:8080/health

echo "Post-propagation targeted reads:"
query_file=$(mktemp)
cat >"$query_file" <<CQL
CONSISTENCY ONE;
SELECT balance, audit FROM ${KEYSPACE}.${TABLE} WHERE account IN ('acct-017', 'acct-042', 'acct-059');
CQL
for node in node0 node1 node2; do
    node_ip=$(node_ip_var "$node")
    echo "-- ${node} affected accounts --"
    /usr/local/bin/cassandra-cql "$node_ip" 9042 -f "$query_file" || true
done
rm -f "$query_file"

echo "Post-propagation audit is expected to fail until the agent repairs all affected state:"
if ledger-audit; then
    echo "audit unexpectedly passed after propagated corruption" >&2
    exit 1
fi
