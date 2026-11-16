#!/usr/bin/env bash
# Reference recovery: diagnose affected replica state, restore only the affected
# ledger rows at CL=ALL, then compact every replica so stale bytes are gone.
set -euo pipefail

CASSANDRA_HOME="${CASSANDRA_HOME:-/opt/apache-cassandra-4.1.8}"
KEYSPACE="${KEYSPACE:-integrity_lab}"
TABLE="${TABLE:-ledger}"
LAB_DIR="/opt/syscraft-lab"
AFFECTED_FILE="${LAB_DIR}/affected-ledger.tsv"
UNAFFECTED_FILE="${LAB_DIR}/unaffected-ledger.tsv"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

node_ip() {
    getent hosts "$1" | awk '{print $1; exit}'
}

NODE0_IP=$(node_ip node0)
if [ -z "$NODE0_IP" ]; then
    echo "failed to resolve node0" >&2
    exit 1
fi

if [ ! -s "$AFFECTED_FILE" ]; then
    echo "missing affected ledger manifest: $AFFECTED_FILE" >&2
    exit 1
fi

wait_for_service_healthy() {
    local attempt
    for attempt in $(seq 1 60); do
        if curl -fsS http://127.0.0.1:8080/health >/tmp/ledger-health.txt 2>&1; then
            cat /tmp/ledger-health.txt
            return 0
        fi
        sleep 2
    done
    cat /tmp/ledger-health.txt >&2 || true
    return 1
}

read_one() {
    local node=$1
    local account=$2
    local query_file
    query_file=$(mktemp)
    cat >"$query_file" <<CQL
CONSISTENCY ONE;
SELECT balance, audit FROM ${KEYSPACE}.${TABLE} WHERE account = '${account}';
CQL
    /usr/local/bin/cassandra-cql "$(node_ip "$node")" 9042 -f "$query_file" || true
    rm -f "$query_file"
}

echo "Replica state before repair:"
while IFS=$'\t' read -r account expected_balance expected_audit bad_balance _bad_audit; do
    [ -n "$account" ] || continue
    echo "== ${account} =="
    echo "expected: ${expected_balance} ${expected_audit}"
    echo "known-bad-observed: ${bad_balance}"
    for node in node0 node1 node2; do
        printf '%s: ' "$node"
        read_one "$node" "$account"
    done
done <"$AFFECTED_FILE"

repair_cql=$(mktemp)
cat >"$repair_cql" <<CQL
CONSISTENCY ALL;
CQL

while IFS=$'\t' read -r account balance audit _bad_balance _bad_audit; do
    [ -n "$account" ] || continue
    cat >>"$repair_cql" <<CQL
UPDATE ${KEYSPACE}.${TABLE}
SET balance = '${balance}', audit = '${audit}'
WHERE account = '${account}';
CQL
done <"$AFFECTED_FILE"

/usr/local/bin/cassandra-cql "$NODE0_IP" 9042 -f "$repair_cql"
rm -f "$repair_cql"

for node in node0 node1 node2; do
    if [ "$node" = "node0" ]; then
        "$CASSANDRA_HOME/bin/nodetool" flush "$KEYSPACE" "$TABLE"
        "$CASSANDRA_HOME/bin/nodetool" compact "$KEYSPACE" "$TABLE"
    else
        ssh "${SSH_OPTS[@]}" "$node" "$CASSANDRA_HOME/bin/nodetool flush $KEYSPACE $TABLE && $CASSANDRA_HOME/bin/nodetool compact $KEYSPACE $TABLE"
    fi
done

echo "Replica state after repair:"
while IFS=$'\t' read -r account expected_balance expected_audit _bad_balance _bad_audit; do
    [ -n "$account" ] || continue
    for node in node0 node1 node2; do
        out=$(read_one "$node" "$account")
        echo "${node} ${account}: ${out}"
        if [ "$out" != "${expected_balance} | ${expected_audit}" ]; then
            echo "repair verification failed for ${account} on ${node}" >&2
            exit 1
        fi
    done
done <"$AFFECTED_FILE"

if [ -s "$UNAFFECTED_FILE" ]; then
    echo "Sampling unrelated ledger rows:"
    while IFS=$'\t' read -r account expected_balance expected_audit; do
        [ -n "$account" ] || continue
        out=$(read_one node0 "$account")
        echo "node0 ${account}: ${out}"
        if [ "$out" != "${expected_balance} | ${expected_audit}" ]; then
            echo "unrelated ledger row changed: ${account}" >&2
            exit 1
        fi
    done <"$UNAFFECTED_FILE"
fi

wait_for_service_healthy
