#!/usr/bin/env bash
# Reference recovery: remove restart-time PgBouncer drift, install safe durable
# pooler settings, restart services, and validate concurrent transactions.
set -euo pipefail

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

echo "Inspecting current PgBouncer incident state"
ssh "${SSH_OPTS[@]}" node1 "systemctl cat pgbouncer || true"
ssh "${SSH_OPTS[@]}" node1 "grep -E 'default_pool_size|query_wait_timeout|server_lifetime|host=' /etc/pgbouncer/pgbouncer.ini || true"

echo "Removing restart-time maintenance drift hook"
ssh "${SSH_OPTS[@]}" node1 <<'REMOTE'
set -euo pipefail
rm -f /etc/systemd/system/pgbouncer.service.d/maintenance-drift.conf
rm -f /usr/local/bin/syscraft-restore-bad-pgbouncer
rmdir /etc/systemd/system/pgbouncer.service.d 2>/dev/null || true
cat >/etc/pgbouncer/pgbouncer.ini <<'EOF'
[databases]
appdb = host=node2 port=5432 dbname=appdb

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = trust
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 200
default_pool_size = 12
reserve_pool_size = 4
reserve_pool_timeout = 2
query_wait_timeout = 30
server_connect_timeout = 10
server_lifetime = 0
ignore_startup_parameters = extra_float_digits
admin_users = appuser
stats_users = appuser
pidfile = /run/postgresql/pgbouncer.pid
logfile = /var/log/postgresql/pgbouncer.log
EOF
chown postgres:postgres /etc/pgbouncer/pgbouncer.ini 2>/dev/null || true
systemctl daemon-reload
systemctl restart pgbouncer
REMOTE

echo "Ensuring the app still uses PgBouncer rather than bypassing directly"
grep -q '^DB_HOST=node1$' /etc/syscraft/pgbouncer-drift.env
grep -q '^DB_PORT=6432$' /etc/syscraft/pgbouncer-drift.env
systemctl restart syscraft-transactions.service

echo "Validating service health"
for _ in $(seq 1 15); do
    if curl -fsS --max-time 5 http://127.0.0.1:8080/health; then
        break
    fi
    sleep 1
done
curl -fsS --max-time 5 http://127.0.0.1:8080/health

echo "Validating concurrent writes"
python3 - <<'PY'
from __future__ import annotations

import concurrent.futures
import json
import os
import urllib.request

prefix = f"solution-check-{os.getpid()}"


def post(i: int) -> dict[str, object]:
    txn = f"{prefix}-{i:02d}"
    url = f"http://127.0.0.1:8080/book?txn={txn}&amount={2000 + i}"
    with urllib.request.urlopen(url, timeout=12) as response:
        payload = json.loads(response.read().decode())
    if response.status != 200 or payload.get("status") != "posted":
        raise RuntimeError(payload)
    return payload


with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
    list(executor.map(post, range(24)))
PY

echo "PgBouncer drift recovery complete"
