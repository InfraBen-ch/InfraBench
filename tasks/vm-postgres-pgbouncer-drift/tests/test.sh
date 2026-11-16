#!/usr/bin/env bash
set -uo pipefail

LAB_DIR="/opt/syscraft-pgbouncer"
ENV_FILE="/etc/syscraft/pgbouncer-drift.env"
EXPECTED_FILE="${LAB_DIR}/expected-bootstrap.tsv"
SYSTEM_ID_FILE="${LAB_DIR}/pg-system-id"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
failures=0

mkdir -p /logs/verifier

pass() {
    echo "PASS: $*"
}

fail() {
    echo "FAIL: $*"
    failures=$((failures + 1))
}

ssh_node() {
    local node=$1
    shift
    if [ "$node" = "node0" ]; then
        bash -lc "$*"
    else
        ssh -n "${SSH_OPTS[@]}" "$node" "$*"
    fi
}

psql_direct() {
    local sql=$1
    ssh -n "${SSH_OPTS[@]}" node2 "runuser -u postgres -- psql -d appdb -At -v ON_ERROR_STOP=1 -c $(printf '%q' "$sql")"
}

book_txn() {
    local txn_id=$1
    local amount=$2
    curl -fsS --max-time 12 "http://127.0.0.1:8080/book?txn=${txn_id}&amount=${amount}"
}

if [ -f "$ENV_FILE" ] && grep -q '^DB_HOST=node1$' "$ENV_FILE" && grep -q '^DB_PORT=6432$' "$ENV_FILE"; then
    pass "app environment still points to PgBouncer on node1:6432"
else
    fail "app environment no longer points to PgBouncer"
    cat "$ENV_FILE" 2>/dev/null || true
fi

if curl -fsS --max-time 5 http://127.0.0.1:8080/health >/tmp/pgbouncer-api-health.json 2>/tmp/pgbouncer-api-health.err; then
    pass "transaction API health is green"
else
    fail "transaction API health is not green"
    cat /tmp/pgbouncer-api-health.err || true
fi

warm_txn="verifier-warm-$$"
if book_txn "$warm_txn" 777 >/tmp/pgbouncer-warm.json 2>/tmp/pgbouncer-warm.err; then
    pass "warm transaction succeeded before restart"
else
    fail "warm transaction failed before restart"
    cat /tmp/pgbouncer-warm.err /tmp/pgbouncer-warm.json 2>/dev/null || true
fi

if ssh_node node1 "systemctl restart pgbouncer" && systemctl restart syscraft-transactions.service; then
    pass "restarted PgBouncer and transaction API"
else
    fail "could not restart PgBouncer and transaction API"
fi

sleep 3

if curl -fsS --max-time 5 http://127.0.0.1:8080/health >/tmp/pgbouncer-api-health-after.json 2>/tmp/pgbouncer-api-health-after.err; then
    pass "transaction API health stayed green after restart"
else
    fail "transaction API health failed after restart"
    cat /tmp/pgbouncer-api-health-after.err || true
fi

if ssh_node node1 "test ! -f /etc/systemd/system/pgbouncer.service.d/maintenance-drift.conf"; then
    pass "PgBouncer maintenance drift drop-in was removed"
else
    fail "PgBouncer maintenance drift drop-in still exists"
fi

if ssh_node node1 "! systemctl cat pgbouncer | grep -q syscraft-restore-bad-pgbouncer"; then
    pass "PgBouncer unit no longer invokes the bad config restore hook"
else
    fail "PgBouncer unit still invokes the bad config restore hook"
fi

if ssh_node node1 "grep -Eq '^default_pool_size[[:space:]]*=[[:space:]]*([5-9]|[1-9][0-9]+)' /etc/pgbouncer/pgbouncer.ini"; then
    pass "PgBouncer persistent config has enough default pool capacity"
else
    fail "PgBouncer default_pool_size is still unsafe"
    ssh_node node1 "grep -n '^default_pool_size' /etc/pgbouncer/pgbouncer.ini || true"
fi

if ssh_node node1 "grep -Eq '^query_wait_timeout[[:space:]]*=[[:space:]]*([5-9]|[1-9][0-9]+)' /etc/pgbouncer/pgbouncer.ini"; then
    pass "PgBouncer query_wait_timeout is durable enough for burst traffic"
else
    fail "PgBouncer query_wait_timeout is still unsafe"
    ssh_node node1 "grep -n '^query_wait_timeout' /etc/pgbouncer/pgbouncer.ini || true"
fi

if ssh_node node1 "grep -q 'host=node2' /etc/pgbouncer/pgbouncer.ini"; then
    pass "PgBouncer still routes to PostgreSQL on node2"
else
    fail "PgBouncer database route no longer points at node2"
fi

workload_prefix="verifier-load-$$"
if python3 - "$workload_prefix" <<'PY' >/tmp/pgbouncer-workload.json 2>/tmp/pgbouncer-workload.err
from __future__ import annotations

import concurrent.futures
import json
import sys
import urllib.error
import urllib.request

prefix = sys.argv[1]


def post(i: int) -> dict[str, object]:
    txn = f"{prefix}-{i:02d}"
    url = f"http://127.0.0.1:8080/book?txn={txn}&amount={1000 + i}"
    try:
        with urllib.request.urlopen(url, timeout=12) as response:
            payload = json.loads(response.read().decode())
        return {"txn": txn, "ok": response.status == 200 and payload.get("status") == "posted", "payload": payload}
    except Exception as exc:
        return {"txn": txn, "ok": False, "error": str(exc)}


with concurrent.futures.ThreadPoolExecutor(max_workers=16) as executor:
    results = list(executor.map(post, range(32)))

print(json.dumps(results, indent=2, sort_keys=True))
if not all(item["ok"] for item in results):
    raise SystemExit(1)
PY
then
    pass "concurrent workload completed through PgBouncer"
else
    fail "concurrent workload had failed transactions"
    cat /tmp/pgbouncer-workload.err /tmp/pgbouncer-workload.json 2>/dev/null || true
fi

row_count=$(psql_direct "SELECT count(*) FROM transactions WHERE txn_id LIKE '${workload_prefix}-%';" 2>/tmp/pgbouncer-row-count.err || true)
if [ "$row_count" = "32" ]; then
    pass "all concurrent workload rows were committed exactly once"
else
    fail "expected 32 workload rows, found ${row_count:-missing}"
    cat /tmp/pgbouncer-row-count.err || true
fi

if psql_direct "SELECT txn_id || E'\t' || amount_cents || E'\t' || source FROM transactions WHERE txn_id LIKE 'bootstrap-%' ORDER BY txn_id;" >/tmp/pgbouncer-bootstrap.tsv 2>/tmp/pgbouncer-bootstrap.err \
    && diff -u "$EXPECTED_FILE" /tmp/pgbouncer-bootstrap.tsv >/tmp/pgbouncer-bootstrap.diff 2>&1; then
    pass "bootstrap PostgreSQL rows were retained"
else
    fail "bootstrap PostgreSQL rows are missing or changed"
    cat /tmp/pgbouncer-bootstrap.err /tmp/pgbouncer-bootstrap.diff 2>/dev/null || true
fi

expected_system_id=$(cat "$SYSTEM_ID_FILE" 2>/dev/null || true)
actual_system_id=$(ssh -n "${SSH_OPTS[@]}" node2 "runuser -u postgres -- psql -At -c 'SELECT system_identifier FROM pg_control_system();'" 2>/tmp/pgbouncer-system-id.err || true)
if [ -n "$expected_system_id" ] && [ "$actual_system_id" = "$expected_system_id" ]; then
    pass "PostgreSQL cluster system identifier is unchanged"
else
    fail "PostgreSQL cluster appears to have been recreated"
    cat /tmp/pgbouncer-system-id.err || true
fi

if systemctl cat syscraft-transactions.service >/tmp/pgbouncer-app-unit.txt 2>/tmp/pgbouncer-app-unit.err \
    && grep -q 'ExecStart=/usr/bin/python3 /opt/syscraft-pgbouncer/bin/transaction_api.py' /tmp/pgbouncer-app-unit.txt; then
    pass "transaction API still runs the in-place task service"
else
    fail "transaction API service was removed or grossly rebuilt"
    cat /tmp/pgbouncer-app-unit.err /tmp/pgbouncer-app-unit.txt 2>/dev/null || true
fi

if ssh_node node1 "systemctl cat pgbouncer" >/tmp/pgbouncer-unit.txt 2>/tmp/pgbouncer-unit.err; then
    pass "PgBouncer service unit is present"
else
    fail "PgBouncer service unit is missing"
    cat /tmp/pgbouncer-unit.err || true
fi

if [ "$failures" -eq 0 ]; then
    reward="1.0"
else
    reward="0.0"
fi

printf '%s\n' "$reward" >/logs/verifier/reward.txt
echo "Final reward: $reward"
exit 0
