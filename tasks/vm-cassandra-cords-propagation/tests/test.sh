#!/usr/bin/env bash
set -euo pipefail

CASSANDRA_HOME="/opt/apache-cassandra-4.1.8"
KEYSPACE="integrity_lab"
TABLE="ledger"
LAB_DIR="/opt/syscraft-lab"
AFFECTED_FILE="${LAB_DIR}/affected-ledger.tsv"
UNAFFECTED_FILE="${LAB_DIR}/unaffected-ledger.tsv"
PROTECTED_FILE="${LAB_DIR}/protected-unaffected-writetime.tsv"
REWARD=0
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

mkdir -p /logs/verifier

node_ip() {
    getent hosts "$1" | awk '{print $1; exit}'
}

NODE0_IP=$(node_ip node0)

finish() {
    local reward
    reward=$(awk "BEGIN { printf \"%.2f\", ${REWARD} / 100 }")
    echo "$reward" >/logs/verifier/reward.txt
    echo "Final reward: $reward"
}
trap finish EXIT

if [ -z "$NODE0_IP" ]; then
    echo "FAIL: node0 does not resolve"
    exit 0
fi

if [ ! -s "$AFFECTED_FILE" ] || [ ! -s "$UNAFFECTED_FILE" ] || [ ! -s "$PROTECTED_FILE" ]; then
    echo "FAIL: verifier manifests are missing"
    exit 0
fi

wait_for_cluster_ready() {
    local attempt
    for attempt in $(seq 1 30); do
        if nc -z node0 9042 && nc -z node1 9042 && nc -z node2 9042; then
            return 0
        fi
        sleep 3
    done
    return 1
}

cql_query() {
    local host=$1
    local consistency=$2
    local cql=$3
    local query_file
    query_file=$(mktemp)
    cat >"$query_file" <<CQL
CONSISTENCY ${consistency};
${cql}
CQL
    /usr/local/bin/cassandra-cql "$host" 9042 -f "$query_file"
    local status=$?
    rm -f "$query_file"
    return "$status"
}

row_matches() {
    local host=$1
    local consistency=$2
    local account=$3
    local expected_balance=$4
    local expected_audit=$5
    local out_file
    out_file=$(mktemp)
    if ! cql_query "$host" "$consistency" "SELECT balance, audit FROM ${KEYSPACE}.${TABLE} WHERE account = '${account}';" >"$out_file" 2>&1; then
        echo "FAIL: ${host} ${consistency} read failed for ${account}"
        cat "$out_file" || true
        rm -f "$out_file"
        return 1
    fi
    if grep -Fxq "${expected_balance} | ${expected_audit}" "$out_file"; then
        rm -f "$out_file"
        return 0
    fi
    echo "FAIL: ${host} ${consistency} returned unexpected data for ${account}"
    cat "$out_file" || true
    rm -f "$out_file"
    return 1
}

cluster_health_pass=0
if wait_for_cluster_ready; then
    nodetool_out=$(mktemp)
    if "$CASSANDRA_HOME/bin/nodetool" status "$KEYSPACE" >"$nodetool_out" 2>&1 \
        && [ "$(grep -c '^UN ' "$nodetool_out" || true)" -ge 3 ]; then
        echo "PASS: all three Cassandra nodes are CQL-reachable and Up/Normal"
        cluster_health_pass=1
    else
        echo "FAIL: Cassandra ring is not healthy enough for CL=ALL"
        cat "$nodetool_out" || true
    fi
    rm -f "$nodetool_out"
else
    echo "FAIL: Cassandra cluster is not reachable on all three nodes"
fi

if curl -fsS http://127.0.0.1:8080/health >/tmp/ledger-health.txt 2>&1; then
    echo "INFO: application /health endpoint is green"
else
    echo "INFO: application /health endpoint is not green"
    cat /tmp/ledger-health.txt || true
fi

read_path_pass=1
while IFS=$'\t' read -r account expected_balance expected_audit _bad_balance _bad_audit; do
    [ -n "$account" ] || continue
    for node in node0 node1 node2; do
        if ! row_matches "$(node_ip "$node")" ONE "$account" "$expected_balance" "$expected_audit"; then
            read_path_pass=0
        fi
    done
    for consistency in QUORUM ALL; do
        if ! row_matches "$NODE0_IP" "$consistency" "$account" "$expected_balance" "$expected_audit"; then
            read_path_pass=0
        fi
    done
done <"$AFFECTED_FILE"

if [ "$read_path_pass" -eq 1 ]; then
    echo "PASS: affected accounts match expected balance and audit digest across per-node and quorum/all reads"
else
    echo "FAIL: affected accounts still diverge or have bad semantic state"
fi

write_roundtrip_pass=0
verifier_balance="verifier-write-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
verifier_audit=$(printf 'acct-verifier:%s\n' "$verifier_balance" | sha256sum | awk '{print $1}')
write_cql=$(mktemp)
cat >"$write_cql" <<CQL
CONSISTENCY ALL;
INSERT INTO ${KEYSPACE}.${TABLE} (account, balance, audit)
VALUES ('acct-verifier', '${verifier_balance}', '${verifier_audit}');
CQL
if /usr/local/bin/cassandra-cql "$NODE0_IP" 9042 -f "$write_cql" >/tmp/verifier-write.txt 2>&1; then
    for node in node0 node1 node2; do
        ssh "${SSH_OPTS[@]}" "$node" "${CASSANDRA_HOME}/bin/nodetool flush ${KEYSPACE} ${TABLE}" >/dev/null 2>&1 || true
    done
    write_roundtrip_pass=1
    for node in node0 node1 node2; do
        if ! row_matches "$(node_ip "$node")" ONE "acct-verifier" "$verifier_balance" "$verifier_audit"; then
            write_roundtrip_pass=0
        fi
    done
else
    echo "FAIL: verifier CL=ALL write failed"
    cat /tmp/verifier-write.txt || true
fi
rm -f "$write_cql"

if [ "$write_roundtrip_pass" -eq 1 ]; then
    echo "PASS: table accepts a new CL=ALL verifier write and every node reads it"
else
    echo "FAIL: verifier write did not survive flush/readback on all nodes"
fi

for node in node0 node1 node2; do
    ssh "${SSH_OPTS[@]}" "$node" "${CASSANDRA_HOME}/bin/nodetool flush ${KEYSPACE} ${TABLE} && ${CASSANDRA_HOME}/bin/nodetool compact ${KEYSPACE} ${TABLE}" >/dev/null 2>&1 || true
done

sstable_state_pass=1
while IFS=$'\t' read -r account expected_balance _expected_audit bad_balance _bad_audit; do
    [ -n "$account" ] || continue
    for node in node0 node1 node2; do
        if ! ssh "${SSH_OPTS[@]}" "$node" "python3 - '${KEYSPACE}' '${TABLE}' '${account}' '${expected_balance}' '${bad_balance}' <<'PY'
import json
import subprocess
import sys
from pathlib import Path

keyspace, table, account, expected, bad = sys.argv[1:]
roots = [
    Path('/opt/apache-cassandra-4.1.8/data/data') / keyspace,
    Path('/opt/apache-cassandra/data/data') / keyspace,
    Path('/var/lib/cassandra/data') / keyspace,
]
primary_files = []
fallback_files = []
for root in roots:
    if not root.exists():
        continue
    primary_files.extend(root.glob(f'{table}-*/*-Data.db'))
    fallback_files.extend(path for path in root.rglob('*-Data.db') if f'/{table}-' in str(path))
data_files = sorted(set(primary_files)) or sorted(set(fallback_files))
seen_expected = False
seen_bad = False
parsed_any = False

if not data_files:
    for root in roots:
        print(f'keyspace root {root}: exists={root.exists()}')
        if root.exists():
            print('table dirs:', ', '.join(str(path) for path in sorted(root.glob(f'{table}-*'))) or '<none>')
            print('Data.db files:', ', '.join(str(path) for path in sorted(root.rglob('*-Data.db'))) or '<none>')
    raise SystemExit('no SSTable Data.db files found for durable state verification')

for data_file in data_files:
    dump = subprocess.run(
        ['/opt/apache-cassandra-4.1.8/tools/bin/sstabledump', str(data_file)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=30,
        check=False,
    )
    if dump.returncode == 0 and dump.stdout.strip():
        try:
            partitions = json.loads(dump.stdout)
        except json.JSONDecodeError:
            partitions = []
        for partition in partitions:
            key = partition.get('partition', {}).get('key', [])
            if account not in key:
                continue
            parsed_any = True
            for row in partition.get('rows', []):
                for cell in row.get('cells', []):
                    value = str(cell.get('value', ''))
                    if cell.get('name') == 'balance' and value == expected:
                        seen_expected = True
                    if value == bad:
                        seen_bad = True

if not parsed_any or not seen_expected:
    blob = b''.join(path.read_bytes() for path in data_files)
    seen_expected = seen_expected or expected.encode() in blob
    seen_bad = seen_bad or bad.encode() in blob

if seen_bad:
    raise SystemExit('stale corrupted row version is still present')
if not seen_expected:
    raise SystemExit('expected durable row version is missing')
PY"; then
            echo "FAIL: on-disk state for ${account} is stale or missing on ${node}"
            sstable_state_pass=0
        fi
    done
done <"$AFFECTED_FILE"

if [ "$sstable_state_pass" -eq 1 ]; then
    echo "PASS: compacted SSTable state contains expected affected rows and no stale corrupted row versions"
else
    echo "FAIL: at least one affected account still has stale or missing on-disk state"
fi

unaffected_pass=1
while IFS=$'\t' read -r account expected_balance expected_audit; do
    [ -n "$account" ] || continue
    for consistency in ALL QUORUM; do
        if ! row_matches "$NODE0_IP" "$consistency" "$account" "$expected_balance" "$expected_audit"; then
            unaffected_pass=0
        fi
    done
done <"$UNAFFECTED_FILE"

while IFS=$'\t' read -r account expected_writetime; do
    [ -n "$account" ] || continue
    writetime_out=$(mktemp)
    if cql_query "$NODE0_IP" ALL "SELECT account, writetime(balance) FROM ${KEYSPACE}.${TABLE} WHERE account = '${account}';" >"$writetime_out" 2>&1; then
        actual_writetime=$(awk -F ' \\| ' -v account="$account" '$1 == account { print $2; exit }' "$writetime_out")
        if [ "$actual_writetime" != "$expected_writetime" ]; then
            echo "FAIL: protected account ${account} was rewritten"
            unaffected_pass=0
        fi
    else
        echo "FAIL: could not read protected writetime for ${account}"
        cat "$writetime_out" || true
        unaffected_pass=0
    fi
    rm -f "$writetime_out"
done <"$PROTECTED_FILE"

row_count_out=$(mktemp)
if cql_query "$NODE0_IP" ALL "SELECT count(*) FROM ${KEYSPACE}.${TABLE};" >"$row_count_out" 2>&1; then
    row_count=$(tr -dc '0-9' <"$row_count_out")
    if [ "$row_count" != "65" ]; then
        echo "FAIL: unexpected ledger row count ${row_count}; table may have been wiped or rebuilt incorrectly"
        unaffected_pass=0
    fi
else
    echo "FAIL: could not count ledger rows at CL=ALL"
    cat "$row_count_out" || true
    unaffected_pass=0
fi
rm -f "$row_count_out"

if [ "$unaffected_pass" -eq 1 ]; then
    echo "PASS: sampled unaffected accounts and row count are preserved"
else
    echo "FAIL: unrelated ledger state was changed or removed"
fi

echo "INFO: sleeping before final revalidation"
sleep 60

revalidate_pass=1
while IFS=$'\t' read -r account expected_balance expected_audit _bad_balance _bad_audit; do
    [ -n "$account" ] || continue
    if ! row_matches "$NODE0_IP" ALL "$account" "$expected_balance" "$expected_audit"; then
        revalidate_pass=0
    fi
done <"$AFFECTED_FILE"

if [ "$revalidate_pass" -eq 1 ]; then
    echo "PASS: affected rows still pass CL=ALL read-path checks after delay"
else
    echo "FAIL: delayed revalidation found transient or unstable repair"
fi

if [ "$cluster_health_pass" -eq 1 ] \
    && [ "$read_path_pass" -eq 1 ] \
    && [ "$write_roundtrip_pass" -eq 1 ] \
    && [ "$sstable_state_pass" -eq 1 ] \
    && [ "$unaffected_pass" -eq 1 ] \
    && [ "$revalidate_pass" -eq 1 ]; then
    REWARD=100
fi
