#!/usr/bin/env bash
# Runs on node0. Builds a PostgreSQL + PgBouncer + API stack, then injects a
# restart-persistent PgBouncer maintenance drift fault.
set -euo pipefail

LAB_DIR="/opt/syscraft-pgbouncer"
BIN_DIR="${LAB_DIR}/bin"
EXPECTED_FILE="${LAB_DIR}/expected-bootstrap.tsv"
CLUSTER_INFO="/etc/syscraft/pgbouncer-drift.env"
INCIDENT_ID="pgbouncer-drift-20260518"
APP_PORT="8080"
PGBOUNCER_PORT="6432"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
NODES=(node0 node1 node2)

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

run_on_node() {
    local node_name=$1
    if [ "$node_name" = "node0" ]; then
        bash -se
    else
        ssh "${SSH_OPTS[@]}" "$node_name" 'bash -se'
    fi
}

copy_to_node() {
    local source=$1
    local node_name=$2
    local target=$3
    if [ "$node_name" = "node0" ]; then
        if [ "$source" != "$target" ]; then
            cp "$source" "$target"
        fi
    else
        scp "${SSH_OPTS[@]}" "$source" "${node_name}:${target}"
    fi
}

wait_for_port() {
    local host=$1
    local port=$2
    local attempt
    for attempt in $(seq 1 60); do
        if nc -z "$host" "$port"; then
            return 0
        fi
        sleep 1
    done
    echo "port ${host}:${port} did not open" >&2
    return 1
}

for node in "${NODES[@]}"; do
    require_ip "$node" >/dev/null
done

for node in "${NODES[@]}"; do
    run_on_node "$node" <<'NODE'
set -euo pipefail
systemctl stop syscraft-transactions.service pgbouncer postgresql 2>/dev/null || true
systemctl disable syscraft-transactions.service pgbouncer 2>/dev/null || true
rm -rf /opt/syscraft-pgbouncer
mkdir -p /opt/syscraft-pgbouncer/bin /opt/syscraft-pgbouncer/logs /etc/syscraft
NODE
done

cat >"$CLUSTER_INFO" <<EOF
INCIDENT_ID=${INCIDENT_ID}
APP_URL=http://127.0.0.1:${APP_PORT}
DB_HOST=node1
DB_PORT=${PGBOUNCER_PORT}
DB_NAME=appdb
DB_USER=appuser
PGBOUNCER_NODE=node1
POSTGRES_NODE=node2
EXPECTED_FILE=${EXPECTED_FILE}
EOF

cat >"$EXPECTED_FILE" <<'EOF'
bootstrap-1001	1200	BOOTSTRAP
bootstrap-1002	3400	BOOTSTRAP
bootstrap-1003	5600	BOOTSTRAP
EOF

for node in "${NODES[@]}"; do
    copy_to_node "$CLUSTER_INFO" "$node" "$CLUSTER_INFO"
    copy_to_node "$EXPECTED_FILE" "$node" "$EXPECTED_FILE"
done

run_on_node node2 <<'NODE'
set -euo pipefail
systemctl start postgresql
pg_version=$(pg_lsclusters -h | awk '$2 == "main" {print $1; exit}')
if [ -z "$pg_version" ]; then
    echo "could not discover PostgreSQL main cluster" >&2
    exit 1
fi

pg_conf="/etc/postgresql/${pg_version}/main/postgresql.conf"
pg_hba="/etc/postgresql/${pg_version}/main/pg_hba.conf"
sed -i "s/^#\?listen_addresses = .*/listen_addresses = '*'/" "$pg_conf"
grep -q 'syscraft pgbouncer drift trust' "$pg_hba" || cat >>"$pg_hba" <<'EOF'
# syscraft pgbouncer drift trust
host all all 127.0.0.1/32 trust
host all all 192.168.100.0/24 trust
EOF
systemctl restart postgresql

runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<'SQL'
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'appuser') THEN
        CREATE ROLE appuser LOGIN;
    END IF;
END
$$;
SELECT 'CREATE DATABASE appdb OWNER appuser'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'appdb')\gexec
SQL

runuser -u postgres -- psql -d appdb -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS transactions (
    txn_id text PRIMARY KEY,
    amount_cents integer NOT NULL,
    status text NOT NULL,
    source text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS syscraft_meta (
    key text PRIMARY KEY,
    value text NOT NULL
);
TRUNCATE transactions;
INSERT INTO transactions (txn_id, amount_cents, status, source) VALUES
    ('bootstrap-1001', 1200, 'POSTED', 'BOOTSTRAP'),
    ('bootstrap-1002', 3400, 'POSTED', 'BOOTSTRAP'),
    ('bootstrap-1003', 5600, 'POSTED', 'BOOTSTRAP');
INSERT INTO syscraft_meta (key, value)
VALUES ('incident_id', 'pgbouncer-drift-20260518')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO appuser;
SQL

runuser -u postgres -- psql -At -c "SELECT system_identifier FROM pg_control_system();" >/opt/syscraft-pgbouncer/pg-system-id
chmod 644 /opt/syscraft-pgbouncer/pg-system-id
NODE

ssh "${SSH_OPTS[@]}" node2 "cat /opt/syscraft-pgbouncer/pg-system-id" >/opt/syscraft-pgbouncer/pg-system-id
chmod 644 /opt/syscraft-pgbouncer/pg-system-id

run_on_node node1 <<'NODE'
set -euo pipefail
mkdir -p /etc/systemd/system/pgbouncer.service.d
cat >/etc/pgbouncer/userlist.txt <<'EOF'
"appuser" ""
EOF
chmod 640 /etc/pgbouncer/userlist.txt
chown postgres:postgres /etc/pgbouncer/userlist.txt 2>/dev/null || true

cat >/usr/local/bin/syscraft-restore-bad-pgbouncer <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/etc/pgbouncer/pgbouncer.ini <<'BADCFG'
[databases]
appdb = host=node2 port=5432 dbname=appdb

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = trust
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 100
default_pool_size = 1
reserve_pool_size = 0
query_wait_timeout = 1
server_connect_timeout = 1
server_lifetime = 2
ignore_startup_parameters = extra_float_digits
admin_users = appuser
stats_users = appuser
pidfile = /run/postgresql/pgbouncer.pid
logfile = /var/log/postgresql/pgbouncer.log
BADCFG
chown postgres:postgres /etc/pgbouncer/pgbouncer.ini 2>/dev/null || true
EOF
chmod +x /usr/local/bin/syscraft-restore-bad-pgbouncer

cat >/etc/systemd/system/pgbouncer.service.d/maintenance-drift.conf <<'EOF'
[Service]
ExecStartPre=/usr/local/bin/syscraft-restore-bad-pgbouncer
EOF

/usr/local/bin/syscraft-restore-bad-pgbouncer
systemctl daemon-reload
systemctl enable pgbouncer
systemctl restart pgbouncer
NODE

run_on_node node0 <<'NODE'
set -euo pipefail
cat >/opt/syscraft-pgbouncer/bin/transaction_api.py <<'PY'
#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ENV_PATH = Path("/etc/syscraft/pgbouncer-drift.env")


def read_env() -> dict[str, str]:
    data: dict[str, str] = {}
    for line in ENV_PATH.read_text().splitlines():
        if not line.strip() or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key] = value
    return data


def psql(sql: str, timeout: int = 8) -> subprocess.CompletedProcess[str]:
    env_data = read_env()
    return subprocess.run(
        [
            "psql",
            "-h",
            env_data["DB_HOST"],
            "-p",
            env_data["DB_PORT"],
            "-U",
            env_data["DB_USER"],
            "-d",
            env_data["DB_NAME"],
            "-v",
            "ON_ERROR_STOP=1",
            "-At",
            "-c",
            sql,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
        env={**os.environ, "PGCONNECT_TIMEOUT": "3"},
    )


def sql_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


class Handler(BaseHTTPRequestHandler):
    def _write_json(self, status: int, payload: dict[str, object]) -> None:
        body = (json.dumps(payload, sort_keys=True) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            return

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/health":
            result = psql("SELECT 1;", timeout=4)
            if result.returncode == 0:
                self._write_json(200, {"status": "ok", "db": "reachable-via-pgbouncer"})
            else:
                self._write_json(503, {"status": "db-error", "stderr": result.stderr[-400:]})
            return

        if parsed.path == "/book":
            params = urllib.parse.parse_qs(parsed.query)
            txn_id = params.get("txn", [""])[0]
            amount_text = params.get("amount", [""])[0]
            if not txn_id or not amount_text.isdigit():
                self._write_json(400, {"status": "bad-request"})
                return
            amount = int(amount_text)
            sql = (
                "BEGIN; "
                "INSERT INTO transactions (txn_id, amount_cents, status, source) "
                f"VALUES ({sql_quote(txn_id)}, {amount}, 'POSTED', 'APP'); "
                "SELECT pg_sleep(0.20); "
                "COMMIT;"
            )
            result = psql(sql, timeout=10)
            if result.returncode == 0:
                self._write_json(200, {"status": "posted", "txn": txn_id, "amount_cents": amount})
            else:
                self._write_json(
                    503,
                    {
                        "status": "db-error",
                        "txn": txn_id,
                        "stderr": result.stderr[-500:],
                    },
                )
            return

        self._write_json(404, {"status": "not-found"})

    def log_message(self, fmt: str, *args: object) -> None:
        return


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
PY
chmod +x /opt/syscraft-pgbouncer/bin/transaction_api.py

cat >/etc/systemd/system/syscraft-transactions.service <<'EOF'
[Unit]
Description=Syscraft transaction API for PgBouncer drift task
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/syscraft/pgbouncer-drift.env
ExecStart=/usr/bin/python3 /opt/syscraft-pgbouncer/bin/transaction_api.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable syscraft-transactions.service
systemctl restart syscraft-transactions.service
NODE

wait_for_port node1 "$PGBOUNCER_PORT"
wait_for_port 127.0.0.1 "$APP_PORT"
curl -fsS --max-time 5 "http://127.0.0.1:${APP_PORT}/health" >/tmp/syscraft-pgbouncer-health.txt

cat >"${LAB_DIR}/incident-note.txt" <<'EOF'
Short health checks are intentionally misleading. The PgBouncer maintenance
change reappears on restart and unsafe pool settings fail under concurrent load.
Repair the durable pooler configuration and remove the restart-time residue.
EOF

echo "Injected PgBouncer restart-persistent configuration drift incident"
