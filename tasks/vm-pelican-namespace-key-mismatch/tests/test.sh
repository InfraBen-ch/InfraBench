#!/usr/bin/env bash
set -uo pipefail

LAB_DIR="/opt/syscraft-pelican"
INCIDENT_ENV="/etc/syscraft/pelican-incident.env"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
CHECKS_JSONL="/tmp/syscraft-verifier-checks.jsonl"
failures=0
approved_jwks=""
active_jwks=""

mkdir -p /logs/verifier
: >"$CHECKS_JSONL"

record_check() {
    local name=$1
    local passed=$2
    local scored=$3
    local weight=${4:-1.0}
    python3 - "$CHECKS_JSONL" "$name" "$passed" "$scored" "$weight" <<'PY'
from __future__ import annotations

import json
import sys

path, name, passed, scored, weight = sys.argv[1:6]
with open(path, "a") as f:
    json.dump(
        {
            "name": name,
            "passed": passed == "true",
            "scored": scored == "true",
            "weight": float(weight),
        },
        f,
        sort_keys=True,
    )
    f.write("\n")
PY
}

pass() {
    echo "PASS: $*"
    record_check "$*" true false
}

fail() {
    echo "FAIL: $*"
    failures=$((failures + 1))
    record_check "$*" false false
}

scored_pass() {
    echo "PASS: $*"
    record_check "$*" true true
}

scored_fail() {
    echo "FAIL: $*"
    failures=$((failures + 1))
    record_check "$*" false true
}

json_field() {
    local path=$1
    local field=$2
    python3 - "$path" "$field" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
value = payload
for part in sys.argv[2].split("."):
    value = value[part]
print(value)
PY
}

canon_json_file() {
    local path=$1
    python3 - "$path" <<'PY'
import json
import sys
from pathlib import Path

print(json.dumps(json.loads(Path(sys.argv[1]).read_text()), sort_keys=True, separators=(",", ":")))
PY
}

service_active() {
    local node=$1
    local service=$2
    if [ "$node" = "node0" ]; then
        systemctl is-active --quiet "$service"
    else
        ssh -n "${SSH_OPTS[@]}" "$node" "systemctl is-active --quiet ${service}"
    fi
}

curl_metadata() {
    local url=$1
    curl -kfsS --max-time 5 "$url"
}

if [ -f "$INCIDENT_ENV" ]; then
    # shellcheck disable=SC1090
    source "$INCIDENT_ENV"
    pass "incident environment file is present"
else
    fail "missing ${INCIDENT_ENV}"
fi

for node_service in \
    "node0 pelican-registry.service" \
    "node0 pelican-director.service" \
    "node2 pelican-cache.service"; do
    set -- $node_service
    if service_active "$1" "$2"; then
        pass "$2 is active on $1"
    else
        fail "$2 is not active on $1"
    fi
done

if curl_metadata https://node0:8444/.well-known/pelican-configuration >/tmp/pelican-discovery.json 2>/tmp/pelican-discovery.err; then
    if grep -Eq 'director|Director|registry|Registry' /tmp/pelican-discovery.json; then
        pass "Director discovery metadata is exposed"
    else
        fail "Director discovery metadata did not advertise federation endpoints"
        cat /tmp/pelican-discovery.json || true
    fi
else
    fail "Director discovery metadata is not reachable"
    cat /tmp/pelican-discovery.err || true
fi

if bash /usr/local/bin/syscraft-pelican-tools status >/tmp/pelican-namespace.json 2>/tmp/pelican-namespace.err; then
    namespace=$(json_field /tmp/pelican-namespace.json namespace 2>/tmp/pelican-namespace-parse.err || true)
    status=$(json_field /tmp/pelican-namespace.json status 2>/tmp/pelican-namespace-parse.err || true)
    approved_jwks=$(python3 - /tmp/pelican-namespace.json <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
print(json.dumps(payload["issuer_jwks"], sort_keys=True, separators=(",", ":")))
PY
)
    if [ "$namespace" = "${PELICAN_NAMESPACE:-/syscraft/public}" ] && [ "$status" = "approved" ]; then
        scored_pass "namespace approval exists for ${namespace}"
    else
        scored_fail "namespace approval is namespace=${namespace:-missing}, status=${status:-missing}"
    fi
else
    scored_fail "could not read namespace approval state"
    cat /tmp/pelican-namespace.err || true
fi

ssh -n "${SSH_OPTS[@]}" node1 "curl -kfsS --max-time 10 https://node1:8444/.well-known/issuer.jwks" >/tmp/pelican-origin-jwks.json 2>/tmp/pelican-origin-key.err || true
active_jwks=""
if [ -s /tmp/pelican-origin-jwks.json ]; then
    active_jwks=$(canon_json_file /tmp/pelican-origin-jwks.json)
fi
if [ -n "$active_jwks" ] && [ "$approved_jwks" = "$active_jwks" ]; then
    scored_pass "Registry namespace approval matches the active Origin issuer JWKS"
else
    scored_fail "Registry approval JWKS does not match the active Origin issuer JWKS"
    cat /tmp/pelican-origin-key.err || true
fi

active_key=$(ssh -n "${SSH_OPTS[@]}" node1 'bash /usr/local/bin/syscraft-pelican-tools fingerprint' 2>/tmp/pelican-origin-key-fingerprint.err || true)
if [ -n "${PELICAN_INITIAL_ORIGIN_KEY_SHA256:-}" ] && [ -n "$active_key" ]; then
    if [ "$active_key" != "$PELICAN_INITIAL_ORIGIN_KEY_SHA256" ]; then
        scored_pass "Origin is still using the rebuilt host key, not the pre-incident stale key"
    else
        scored_fail "Origin was rolled back to the pre-incident key instead of reconciling Registry state"
    fi
fi

if [ -f "${LAB_DIR}/federation/incident.log" ]; then
    if grep -Eiq 'key mismatch|registration rejected|issuer key mismatch' "${LAB_DIR}/federation/incident.log"; then
        scored_fail "stale namespace key-mismatch incident marker is still present"
        cat "${LAB_DIR}/federation/incident.log" || true
    else
        scored_pass "federation incident log has no remaining key-mismatch marker"
    fi
else
    scored_pass "stale federation incident marker was cleared"
fi

if ssh -n "${SSH_OPTS[@]}" node1 "journalctl -u pelican-origin.service -n 200 --no-pager" 2>/tmp/pelican-origin-journal.err | grep -Eiq 'issuer key mismatch|registration rejected|key mismatch'; then
    scored_fail "recent Origin logs still show namespace key-mismatch or registration rejection"
else
    scored_pass "recent Origin logs do not show namespace key-mismatch failures"
fi

if ssh -n "${SSH_OPTS[@]}" node2 "journalctl -u pelican-cache.service -n 200 --no-pager" 2>/tmp/pelican-cache-journal.err | grep -Eiq 'issuer key mismatch|registration rejected|key mismatch'; then
    scored_fail "recent Cache logs still show namespace key-mismatch or registration rejection"
else
    scored_pass "recent Cache logs do not show namespace key-mismatch failures"
fi

if ssh -n "${SSH_OPTS[@]}" node2 "ss -ltnp | grep -E ':(8000|8080|8888)\\b' | grep -E 'python|busybox|nc|ncat|socat|ruby|php'" >/tmp/pelican-bypass.txt 2>&1; then
    scored_fail "found an ad-hoc plain HTTP/file server bypass on node2"
    cat /tmp/pelican-bypass.txt || true
else
    scored_pass "no obvious plain HTTP/file-server bypass is listening on node2"
fi

ssh -n "${SSH_OPTS[@]}" node2 'rm -rf /opt/syscraft-pelican/client-verifier && mkdir -p /opt/syscraft-pelican/client-verifier' >/dev/null 2>&1 || true
if ssh -n "${SSH_OPTS[@]}" node2 "source ${INCIDENT_ENV}; podman run --rm --network host --entrypoint pelican -v /opt/syscraft-pelican/cache/etc:/etc/pelican:Z -v /opt/syscraft-pelican/client-verifier:/work:Z -w /work hub.opensciencegrid.org/pelican_platform/origin:\${PELICAN_IMAGE_TAG} object get pelican://node0:8444\${PELICAN_NAMESPACE}/\${PELICAN_OBJECT} \${PELICAN_OBJECT}" >/tmp/pelican-object-get.txt 2>/tmp/pelican-object-get.err; then
    scored_pass "client retrieved the object through the Pelican federation path"
else
    scored_fail "client could not retrieve the object through the Pelican federation path"
    cat /tmp/pelican-object-get.txt || true
    cat /tmp/pelican-object-get.err || true
fi

retrieved_path=$(ssh -n "${SSH_OPTS[@]}" node2 "find /opt/syscraft-pelican/client-verifier -type f -name '${PELICAN_OBJECT:-payload.txt}' | head -n1" 2>/tmp/pelican-find.err || true)
retrieved_sha=$(ssh -n "${SSH_OPTS[@]}" node2 "test -n '${retrieved_path}' && sha256sum '${retrieved_path}' | awk '{print \$1}'" 2>/tmp/pelican-sha.err || true)
if [ -n "$retrieved_sha" ] && [ "$retrieved_sha" = "${PELICAN_EXPECTED_SHA256:-}" ]; then
    scored_pass "retrieved object checksum matches expected hidden value"
else
    scored_fail "retrieved checksum ${retrieved_sha:-missing} does not match expected ${PELICAN_EXPECTED_SHA256:-missing}"
    cat /tmp/pelican-find.err || true
    cat /tmp/pelican-sha.err || true
fi

if [ -n "$retrieved_path" ] && ssh -n "${SSH_OPTS[@]}" node2 "cmp -s '${retrieved_path}' /opt/syscraft-pelican/expected/${PELICAN_OBJECT:-payload.txt}" 2>/tmp/pelican-cmp.err; then
    scored_pass "retrieved object content matches expected dataset"
else
    scored_fail "retrieved object content differs from expected dataset"
    cat /tmp/pelican-cmp.err || true
fi

if [ "$failures" -eq 0 ]; then
    reward="1.0"
    exit_code=0
else
    reward="0.0"
    exit_code=1
fi

echo "$reward" >/logs/verifier/reward.txt
python3 - "$reward" "$CHECKS_JSONL" <<'PY' >/logs/verifier/reward.json
from __future__ import annotations

import json
import sys

reward = float(sys.argv[1])
checks_path = sys.argv[2]
with open(checks_path) as f:
    checks = [json.loads(line) for line in f if line.strip()]

print(json.dumps({"reward": reward, "checks": checks}, sort_keys=True))
PY
exit "$exit_code"
