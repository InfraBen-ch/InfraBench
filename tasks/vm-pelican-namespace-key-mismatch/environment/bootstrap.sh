#!/usr/bin/env bash
# Runs on node0. Builds a private three-node Pelican federation, verifies the
# namespace once, then rotates the Origin issuer key without updating Registry
# approval metadata.
set -euo pipefail

LAB_DIR="/opt/syscraft-pelican"
EXPECTED_DIR="${LAB_DIR}/expected"
FEDERATION_DIR="${LAB_DIR}/federation"
INCIDENT_ENV="/etc/syscraft/pelican-incident.env"
IMAGE_TAG="${PELICAN_IMAGE_TAG:-v7.19.0}"
NAMESPACE="/syscraft/public"
OBJECT_NAME="payload.txt"
DATA_DIR="${LAB_DIR}/origin-data"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
NODES=(node0 node1 node2)

REGISTRY_IMAGE="hub.opensciencegrid.org/pelican_platform/registry:${IMAGE_TAG}"
DIRECTOR_IMAGE="hub.opensciencegrid.org/pelican_platform/director:${IMAGE_TAG}"
ORIGIN_IMAGE="hub.opensciencegrid.org/pelican_platform/origin:${IMAGE_TAG}"
CACHE_IMAGE="hub.opensciencegrid.org/pelican_platform/cache:${IMAGE_TAG}"

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

wait_for_http() {
    local url=$1
    local attempts=${2:-90}
    local attempt
    for attempt in $(seq 1 "$attempts"); do
        if curl -kfsS --max-time 4 "$url" >/tmp/pelican-http-check.txt 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "HTTP endpoint did not become available: ${url}" >&2
    cat /tmp/pelican-http-check.txt >&2 || true
    return 1
}

for node in "${NODES[@]}"; do
    getent hosts "$node" >/dev/null
done

for node in "${NODES[@]}"; do
    run_on_node "$node" <<'NODE'
set -euo pipefail
systemctl stop pelican-registry.service pelican-director.service pelican-origin.service pelican-cache.service 2>/dev/null || true
podman rm -f pelican-registry pelican-director pelican-origin pelican-cache 2>/dev/null || true
rm -rf /opt/syscraft-pelican
mkdir -p /opt/syscraft-pelican/bin /opt/syscraft-pelican/expected /opt/syscraft-pelican/federation /etc/syscraft
NODE
done

payload="${EXPECTED_DIR}/${OBJECT_NAME}"
mkdir -p "$EXPECTED_DIR" "$FEDERATION_DIR"
cat >"$payload" <<'EOF'
Syscraft Pelican federation object
namespace=/syscraft/public
incident=origin-issuer-key-mismatch
expected-repair=registry-namespace-identity-reconciliation
EOF
payload_sha256=$(sha256sum "$payload" | awk '{print $1}')

cat >"$INCIDENT_ENV" <<EOF
PELICAN_IMAGE_TAG=${IMAGE_TAG}
PELICAN_NAMESPACE=${NAMESPACE}
PELICAN_OBJECT=${OBJECT_NAME}
PELICAN_EXPECTED_SHA256=${payload_sha256}
PELICAN_DISCOVERY_URL=https://node0:8444
PELICAN_REGISTRY_URL=https://node0:8445
PELICAN_DIRECTOR_URL=https://node0:8444
PELICAN_ORIGIN_URL=https://node1:8444
PELICAN_ORIGIN_TRANSFER_URL=https://node1:8443
PELICAN_CACHE_URL=https://node2:8444
EOF

for node in "${NODES[@]}"; do
    copy_to_node "$INCIDENT_ENV" "$node" "$INCIDENT_ENV"
    copy_to_node "$payload" "$node" "${EXPECTED_DIR}/${OBJECT_NAME}"
done

run_on_node node0 <<NODE
set -euo pipefail
podman pull "$REGISTRY_IMAGE" >/dev/null
podman pull "$DIRECTOR_IMAGE" >/dev/null
NODE

run_on_node node1 <<NODE
set -euo pipefail
podman pull "$ORIGIN_IMAGE" >/dev/null
NODE

run_on_node node2 <<NODE
set -euo pipefail
podman pull "$CACHE_IMAGE" >/dev/null
podman pull "$ORIGIN_IMAGE" >/dev/null
NODE

run_on_node node0 <<'NODE0'
set -euo pipefail
LAB_DIR=/opt/syscraft-pelican
mkdir -p \
    "$LAB_DIR/ca" \
    "$LAB_DIR/registry/etc/certificates" "$LAB_DIR/registry/lib" \
    "$LAB_DIR/director/etc/certificates" "$LAB_DIR/director/lib"

make_ca() {
    openssl req -x509 -newkey rsa:4096 -nodes -days 365 \
        -subj "/CN=Syscraft Pelican Test CA" \
        -keyout "$LAB_DIR/ca/tlsca.key" \
        -out "$LAB_DIR/ca/tlsca.pem" >/dev/null 2>&1
}

make_signed_cert() {
    local name=$1
    local out_dir=$2
    local csr_path="${out_dir}/${name}.csr"
    local ext_path="${out_dir}/${name}.ext"

    openssl req -new -newkey rsa:2048 -nodes \
        -subj "/CN=${name}" \
        -keyout "${out_dir}/tls.key" \
        -out "${csr_path}" >/dev/null 2>&1

    cat >"${ext_path}" <<EOF
subjectAltName=DNS:${name},DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth,clientAuth
EOF

    openssl x509 -req -days 365 \
        -in "${csr_path}" \
        -CA "$LAB_DIR/ca/tlsca.pem" \
        -CAkey "$LAB_DIR/ca/tlsca.key" \
        -CAcreateserial \
        -out "${out_dir}/tls.crt" \
        -extfile "${ext_path}" >/dev/null 2>&1

    rm -f "${csr_path}" "${ext_path}"
}

make_ca
make_signed_cert node0 "$LAB_DIR/registry/etc/certificates"
cp "$LAB_DIR/registry/etc/certificates/tls."* "$LAB_DIR/director/etc/certificates/"
cp "$LAB_DIR/ca/tlsca."* "$LAB_DIR/registry/etc/certificates/"
cp "$LAB_DIR/ca/tlsca."* "$LAB_DIR/director/etc/certificates/"
printf 'syscraft-registry-client\n' >"$LAB_DIR/registry/etc/oidc-client-id"
printf 'syscraft-registry-secret\n' >"$LAB_DIR/registry/etc/oidc-client-secret"
openssl rand -hex 32 >"$LAB_DIR/registry/etc/session-secret"

cat >"$LAB_DIR/registry/etc/pelican.yaml" <<'YAML'
Logging:
  Level: debug
Server:
  Hostname: node0
  ExternalWebUrl: https://node0:8445
  WebPort: 8445
  TLSCACertificateFile: /etc/pelican/certificates/tlsca.pem
  TLSCertificateChain: /etc/pelican/certificates/tls.crt
  TLSKey: /etc/pelican/certificates/tls.key
Registry:
  RequireOriginApproval: false
YAML

cat >"$LAB_DIR/director/etc/pelican.yaml" <<'YAML'
Logging:
  Level: debug
Server:
  Hostname: node0
  ExternalWebUrl: https://node0:8444
  WebPort: 8444
  TLSCACertificateFile: /etc/pelican/certificates/tlsca.pem
  TLSCertificateChain: /etc/pelican/certificates/tls.crt
  TLSKey: /etc/pelican/certificates/tls.key
Federation:
  DiscoveryUrl: https://node0:8444
  DirectorUrl: https://node0:8444
  RegistryUrl: https://node0:8445
YAML
NODE0

run_on_node node0 <<'NODE0DIST'
set -euo pipefail
LAB_DIR=/opt/syscraft-pelican
mkdir -p "$LAB_DIR/generated-certs/node1" "$LAB_DIR/generated-certs/node2"

make_signed_cert() {
    local name=$1
    local out_dir=$2
    local csr_path="${out_dir}/${name}.csr"
    local ext_path="${out_dir}/${name}.ext"

    openssl req -new -newkey rsa:2048 -nodes \
        -subj "/CN=${name}" \
        -keyout "${out_dir}/tls.key" \
        -out "${csr_path}" >/dev/null 2>&1

    cat >"${ext_path}" <<EOF
subjectAltName=DNS:${name},DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth,clientAuth
EOF

    openssl x509 -req -days 365 \
        -in "${csr_path}" \
        -CA "$LAB_DIR/ca/tlsca.pem" \
        -CAkey "$LAB_DIR/ca/tlsca.key" \
        -CAcreateserial \
        -out "${out_dir}/tls.crt" \
        -extfile "${ext_path}" >/dev/null 2>&1

    rm -f "${csr_path}" "${ext_path}"
}

make_signed_cert node1 "$LAB_DIR/generated-certs/node1"
make_signed_cert node2 "$LAB_DIR/generated-certs/node2"
cp "$LAB_DIR/ca/tlsca.pem" "$LAB_DIR/generated-certs/node1/tlsca.pem"
cp "$LAB_DIR/ca/tlsca.pem" "$LAB_DIR/generated-certs/node2/tlsca.pem"
NODE0DIST

run_on_node node1 <<'NODE1'
set -euo pipefail
LAB_DIR=/opt/syscraft-pelican
mkdir -p \
    "$LAB_DIR/origin/etc/certificates" "$LAB_DIR/origin/etc/issuer-keys" \
    "$LAB_DIR/origin/lib" "$LAB_DIR/origin-data"

openssl genrsa -out "$LAB_DIR/origin/etc/issuer-keys/issuer.key" 2048 >/dev/null 2>&1
openssl rsa -in "$LAB_DIR/origin/etc/issuer-keys/issuer.key" \
    -pubout -out "$LAB_DIR/origin/etc/issuer-keys/issuer.pub" >/dev/null 2>&1

cp "$LAB_DIR/expected/payload.txt" "$LAB_DIR/origin-data/payload.txt"

cat >"$LAB_DIR/origin/etc/pelican.yaml" <<'YAML'
Logging:
  Level: debug
IssuerKeysDirectory: /etc/pelican/issuer-keys
Server:
  Hostname: node1
  ExternalWebUrl: https://node1:8444
  WebPort: 8444
  TLSCACertificateFile: /etc/pelican/certificates/tlsca.pem
  TLSCertificateChain: /etc/pelican/certificates/tls.crt
  TLSKey: /etc/pelican/certificates/tls.key
Federation:
  DiscoveryUrl: https://node0:8444
  DirectorUrl: https://node0:8444
  RegistryUrl: https://node0:8445
Origin:
  Port: 8443
  Url: https://node1:8443
  EnableReads: true
  EnablePublicReads: true
  Exports:
    - StoragePrefix: /data
      FederationPrefix: /syscraft/public
      Capabilities: ["PublicReads", "Listings", "DirectReads"]
YAML
NODE1

run_on_node node2 <<'NODE2'
set -euo pipefail
LAB_DIR=/opt/syscraft-pelican
mkdir -p "$LAB_DIR/cache/etc/certificates" "$LAB_DIR/cache/lib" "$LAB_DIR/cache/storage" "$LAB_DIR/client"

cat >"$LAB_DIR/cache/etc/pelican.yaml" <<'YAML'
Logging:
  Level: debug
Server:
  Hostname: node2
  ExternalWebUrl: https://node2:8444
  WebPort: 8444
  TLSCACertificateFile: /etc/pelican/certificates/tlsca.pem
  TLSCertificateChain: /etc/pelican/certificates/tls.crt
  TLSKey: /etc/pelican/certificates/tls.key
Federation:
  DiscoveryUrl: https://node0:8444
  DirectorUrl: https://node0:8444
  RegistryUrl: https://node0:8445
Cache:
  Port: 8442
  StorageLocation: /var/cache/pelican
YAML
NODE2

copy_to_node /opt/syscraft-pelican/generated-certs/node1/tls.crt node1 /opt/syscraft-pelican/origin/etc/certificates/tls.crt
copy_to_node /opt/syscraft-pelican/generated-certs/node1/tls.key node1 /opt/syscraft-pelican/origin/etc/certificates/tls.key
copy_to_node /opt/syscraft-pelican/generated-certs/node1/tlsca.pem node1 /opt/syscraft-pelican/origin/etc/certificates/tlsca.pem
copy_to_node /opt/syscraft-pelican/generated-certs/node2/tls.crt node2 /opt/syscraft-pelican/cache/etc/certificates/tls.crt
copy_to_node /opt/syscraft-pelican/generated-certs/node2/tls.key node2 /opt/syscraft-pelican/cache/etc/certificates/tls.key
copy_to_node /opt/syscraft-pelican/generated-certs/node2/tlsca.pem node2 /opt/syscraft-pelican/cache/etc/certificates/tlsca.pem

cat >/tmp/syscraft-pelican-tools.sh <<'TOOLS'
#!/usr/bin/env bash
set -euo pipefail
LAB_DIR=/opt/syscraft-pelican
REGISTRY_DB="${LAB_DIR}/registry/lib/pelican.sqlite"
ORIGIN_REG_PREFIX="/origins/node1:8444"
NAMESPACE_PREFIX="/syscraft/public"
CACHE_REG_PREFIX="/caches/node2"

origin_fingerprint() {
    local key_path=${1:-"${LAB_DIR}/origin/etc/issuer-keys/issuer.pub"}
    openssl pkey -pubin -in "$key_path" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
}

canon_json() {
    python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin), sort_keys=True, separators=(",", ":")))'
}

fetch_jwks() {
    local host=$1
    curl -kfsS --max-time 10 "https://${host}:8444/.well-known/issuer.jwks" | canon_json
}

python_registry() {
    python3 - "$@" <<'PY'
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

db_path = Path(sys.argv[1])
cmd = sys.argv[2]

con = sqlite3.connect(db_path)

if cmd == "exists":
    prefixes = sys.argv[3:]
    rows = {
        prefix
        for (prefix,) in con.execute(
            f"select prefix from registrations where prefix in ({','.join('?' for _ in prefixes)})",
            prefixes,
        )
    }
    print(json.dumps({"missing": [p for p in prefixes if p not in rows]}))
elif cmd == "get":
    prefix = sys.argv[3]
    row = con.execute(
        "select prefix, pubkey, admin_metadata from registrations where prefix = ?",
        (prefix,),
    ).fetchone()
    if row is None:
        raise SystemExit(f"missing registration for {prefix}")
    meta = json.loads(row[2] or "{}")
    print(
        json.dumps(
            {
                "prefix": row[0],
                "pubkey": json.loads(row[1]),
                "status": meta.get("status", ""),
                "admin_metadata": meta,
            },
            sort_keys=True,
        )
    )
elif cmd == "approve":
    prefix = sys.argv[3]
    pubkey = json.loads(sys.argv[4])
    row = con.execute(
        "select admin_metadata from registrations where prefix = ?",
        (prefix,),
    ).fetchone()
    if row is None:
        raise SystemExit(f"missing registration for {prefix}")
    meta = json.loads(row[0] or "{}")
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    meta["status"] = "Approved"
    meta["approved_at"] = now
    meta["updated_at"] = now
    meta.setdefault("approver_id", "syscraft")
    con.execute(
        "update registrations set pubkey = ?, admin_metadata = ? where prefix = ?",
        (json.dumps(pubkey, sort_keys=True, separators=(",", ":")), json.dumps(meta, separators=(",", ":")), prefix),
    )
    con.commit()
else:
    raise SystemExit(f"unknown command: {cmd}")
PY
}

wait_for_registrations() {
    local missing=""
    for _ in $(seq 1 60); do
        missing=$(python_registry "$REGISTRY_DB" exists \
            "$ORIGIN_REG_PREFIX" \
            "$NAMESPACE_PREFIX" \
            "$CACHE_REG_PREFIX")
        if [ "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["missing"]))' "$missing")" = "0" ]; then
            return 0
        fi
        sleep 2
    done
    echo "$missing" >&2
    return 1
}

approve_prefix() {
    local prefix=$1
    local host=$2
    local jwks
    jwks=$(fetch_jwks "$host")
    python_registry "$REGISTRY_DB" approve "$prefix" "$jwks"
}

registration_status() {
    local prefix=$1
    python_registry "$REGISTRY_DB" get "$prefix"
}

case "${1:-}" in
    fingerprint)
        origin_fingerprint "${2:-${LAB_DIR}/origin/etc/issuer-keys/issuer.pub}"
        ;;
    wait-for-registrations)
        wait_for_registrations
        ;;
    current-origin-jwks)
        fetch_jwks node1
        ;;
    approve-current)
        approve_prefix "$ORIGIN_REG_PREFIX" node1
        approve_prefix "$NAMESPACE_PREFIX" node1
        ;;
    approve-initial)
        approve_prefix "$ORIGIN_REG_PREFIX" node1
        approve_prefix "$NAMESPACE_PREFIX" node1
        approve_prefix "$CACHE_REG_PREFIX" node2
        ;;
    status)
        namespace=$(registration_status "$NAMESPACE_PREFIX")
        origin=$(registration_status "$ORIGIN_REG_PREFIX")
        python3 - "$namespace" "$origin" <<'PY'
import json
import sys

namespace = json.loads(sys.argv[1])
origin = json.loads(sys.argv[2])
print(
    json.dumps(
        {
            "namespace": namespace["prefix"],
            "origin_url": "https://node1:8444",
            "origin_transfer_url": "https://node1:8443",
            "issuer_jwks": namespace["pubkey"],
            "status": namespace["status"].lower(),
            "registry_url": "https://node0:8445",
            "origin_registration_status": origin["status"].lower(),
        },
        sort_keys=True,
    )
)
PY
        ;;
    *)
        echo "usage: $0 fingerprint [pubkey] | wait-for-registrations | current-origin-jwks | approve-current | approve-initial | status" >&2
        exit 2
        ;;
esac
TOOLS
chmod +x /tmp/syscraft-pelican-tools.sh
for node in "${NODES[@]}"; do
    copy_to_node /tmp/syscraft-pelican-tools.sh "$node" /usr/local/bin/syscraft-pelican-tools
done
rm -f /tmp/syscraft-pelican-tools.sh

initial_origin_key=$(ssh "${SSH_OPTS[@]}" node1 'bash /usr/local/bin/syscraft-pelican-tools fingerprint')
run_on_node node0 <<NODE0STATE
set -euo pipefail
echo "PELICAN_INITIAL_ORIGIN_KEY_SHA256=${initial_origin_key}" >>/etc/syscraft/pelican-incident.env
NODE0STATE

for node in "${NODES[@]}"; do
    copy_to_node "$INCIDENT_ENV" "$node" "$INCIDENT_ENV"
done

cat >/tmp/pelican-registry.service <<EOF
[Unit]
Description=Syscraft Pelican Registry
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/podman rm -f pelican-registry
ExecStart=/usr/bin/podman run --rm --name pelican-registry --network host -v /opt/syscraft-pelican/registry/etc:/etc/pelican:Z -v /opt/syscraft-pelican/registry/lib:/var/lib/pelican:Z ${REGISTRY_IMAGE} serve
ExecStop=/usr/bin/podman stop pelican-registry
ExecStopPost=-/usr/bin/podman rm -f pelican-registry
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat >/tmp/pelican-director.service <<EOF
[Unit]
Description=Syscraft Pelican Director
After=network-online.target pelican-registry.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/podman rm -f pelican-director
ExecStart=/usr/bin/podman run --rm --name pelican-director --network host -v /opt/syscraft-pelican/director/etc:/etc/pelican:Z -v /opt/syscraft-pelican/director/lib:/var/lib/pelican:Z ${DIRECTOR_IMAGE} serve
ExecStop=/usr/bin/podman stop pelican-director
ExecStopPost=-/usr/bin/podman rm -f pelican-director
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat >/tmp/pelican-origin.service <<EOF
[Unit]
Description=Syscraft Pelican Origin
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/podman rm -f pelican-origin
ExecStart=/usr/bin/podman run --rm --name pelican-origin --network host -v /opt/syscraft-pelican/origin/etc:/etc/pelican:Z -v /opt/syscraft-pelican/origin/lib:/var/lib/pelican:Z -v /opt/syscraft-pelican/origin-data:/data:Z ${ORIGIN_IMAGE} serve
ExecStop=/usr/bin/podman stop pelican-origin
ExecStopPost=-/usr/bin/podman rm -f pelican-origin
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat >/tmp/pelican-cache.service <<EOF
[Unit]
Description=Syscraft Pelican Cache
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/podman rm -f pelican-cache
ExecStart=/usr/bin/podman run --rm --name pelican-cache --network host -v /opt/syscraft-pelican/cache/etc:/etc/pelican:Z -v /opt/syscraft-pelican/cache/lib:/var/lib/pelican:Z -v /opt/syscraft-pelican/cache/storage:/var/cache/pelican:Z ${CACHE_IMAGE} serve
ExecStop=/usr/bin/podman stop pelican-cache
ExecStopPost=-/usr/bin/podman rm -f pelican-cache
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

copy_to_node /tmp/pelican-registry.service node0 /etc/systemd/system/pelican-registry.service
copy_to_node /tmp/pelican-director.service node0 /etc/systemd/system/pelican-director.service
copy_to_node /tmp/pelican-origin.service node1 /etc/systemd/system/pelican-origin.service
copy_to_node /tmp/pelican-cache.service node2 /etc/systemd/system/pelican-cache.service
rm -f /tmp/pelican-registry.service /tmp/pelican-director.service /tmp/pelican-origin.service /tmp/pelican-cache.service

run_on_node node0 <<'NODE0START'
set -euo pipefail
systemctl daemon-reload
systemctl enable --now pelican-registry.service pelican-director.service
NODE0START
run_on_node node1 <<'NODE1START'
set -euo pipefail
systemctl daemon-reload
systemctl enable --now pelican-origin.service
NODE1START
run_on_node node2 <<'NODE2START'
set -euo pipefail
systemctl daemon-reload
systemctl enable --now pelican-cache.service
NODE2START

wait_for_http https://node0:8444/.well-known/pelican-configuration 120 || true
wait_for_http https://node1:8444/.well-known/openid-configuration 120 || true
wait_for_http https://node2:8444/.well-known/openid-configuration 120 || true

run_on_node node0 <<'NODE0APPROVED'
set -euo pipefail
bash /usr/local/bin/syscraft-pelican-tools wait-for-registrations
bash /usr/local/bin/syscraft-pelican-tools approve-initial
bash /usr/local/bin/syscraft-pelican-tools status >/opt/syscraft-pelican/expected/namespace-approval.initial.json
systemctl restart pelican-registry.service pelican-director.service
NODE0APPROVED

run_on_node node2 <<'NODE2WARM'
set -euo pipefail
source /etc/syscraft/pelican-incident.env
mkdir -p /opt/syscraft-pelican/client
podman run --rm --network host \
    --entrypoint timeout \
    -v /opt/syscraft-pelican/cache/etc:/etc/pelican:Z \
    -v /opt/syscraft-pelican/client:/work:Z \
    -w /work \
    "hub.opensciencegrid.org/pelican_platform/origin:${PELICAN_IMAGE_TAG}" \
    90s pelican object get "pelican://node0:8444${PELICAN_NAMESPACE}/${PELICAN_OBJECT}" "${PELICAN_OBJECT}" >/tmp/pelican-object-get.log 2>&1 || true
if [ -f "/opt/syscraft-pelican/client/${PELICAN_OBJECT}" ]; then
    sha256sum "/opt/syscraft-pelican/client/${PELICAN_OBJECT}" >/opt/syscraft-pelican/expected/cache-warm.sha256
fi
NODE2WARM

run_on_node node1 <<'NODE1ROTATE'
set -euo pipefail
LAB_DIR=/opt/syscraft-pelican
mkdir -p "$LAB_DIR/origin/etc/issuer-keys.stale"
cp "$LAB_DIR/origin/etc/issuer-keys/"* "$LAB_DIR/origin/etc/issuer-keys.stale/"
rm -f "$LAB_DIR/origin/etc/issuer-keys/"*
openssl genrsa -out "$LAB_DIR/origin/etc/issuer-keys/issuer.key" 2048 >/dev/null 2>&1
openssl rsa -in "$LAB_DIR/origin/etc/issuer-keys/issuer.key" \
    -pubout -out "$LAB_DIR/origin/etc/issuer-keys/issuer.pub" >/dev/null 2>&1
new_fp=$(bash /usr/local/bin/syscraft-pelican-tools fingerprint)
echo "PELICAN_ACTIVE_ORIGIN_KEY_SHA256=${new_fp}" >>/etc/syscraft/pelican-incident.env
systemctl restart pelican-origin.service
journalctl -u pelican-origin.service -n 200 --no-pager >/opt/syscraft-pelican/expected/origin-post-rotation.log || true
NODE1ROTATE

wait_for_http https://node1:8444/.well-known/issuer.jwks 120 || true

active_origin_key=$(ssh "${SSH_OPTS[@]}" node1 "grep PELICAN_ACTIVE_ORIGIN_KEY_SHA256 /etc/syscraft/pelican-incident.env | tail -1")
echo "$active_origin_key" >>"$INCIDENT_ENV"
for node in "${NODES[@]}"; do
    copy_to_node "$INCIDENT_ENV" "$node" "$INCIDENT_ENV"
done

run_on_node node0 <<'NODE0FAULT'
set -euo pipefail
cat >>/opt/syscraft-pelican/federation/incident.log <<'EOF'
origin registration rejected: issuer key mismatch for /syscraft/public
registry namespace approval still references the pre-rebuild Origin issuer key
EOF
journalctl -u pelican-director.service -n 200 --no-pager >/opt/syscraft-pelican/expected/director-pre-repair.log || true
NODE0FAULT

echo "Pelican namespace key mismatch incident injected."
