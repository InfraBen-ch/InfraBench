#!/usr/bin/env bash
# Reference recovery for the injected Origin issuer-key mismatch.
set -euo pipefail

LAB_DIR="/opt/syscraft-pelican"
INCIDENT_ENV="/etc/syscraft/pelican-incident.env"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

source "$INCIDENT_ENV"

echo "Current Registry namespace approval:"
bash /usr/local/bin/syscraft-pelican-tools status || true

echo "Active Origin issuer key fingerprint:"
ssh "${SSH_OPTS[@]}" node1 'bash /usr/local/bin/syscraft-pelican-tools fingerprint'

ensure_service_active() {
    local node=$1
    local service=$2

    if [ "$node" = "node0" ]; then
        if ! systemctl is-active --quiet "$service"; then
            systemctl restart "$service"
        fi
    else
        if ! ssh -n "${SSH_OPTS[@]}" "$node" "systemctl is-active --quiet ${service}"; then
            ssh -n "${SSH_OPTS[@]}" "$node" "systemctl restart ${service}"
        fi
    fi
}

echo "Ensuring Pelican services are active"
ensure_service_active node0 pelican-registry.service
ensure_service_active node0 pelican-director.service
ensure_service_active node1 pelican-origin.service
ensure_service_active node2 pelican-cache.service

for url in \
    https://node1:8444/.well-known/issuer.jwks \
    https://node0:8444/.well-known/pelican-configuration \
    https://node2:8444/.well-known/openid-configuration; do
    for attempt in $(seq 1 60); do
        if curl -kfsS --max-time 4 "$url" >/dev/null 2>&1; then
            echo "Ready: $url"
            break
        fi
        if [ "$attempt" = "60" ]; then
            echo "Timed out waiting for $url" >&2
            exit 1
        fi
        sleep 2
    done
done

echo "Reconciling real Registry registrations with the active Origin identity"
bash /usr/local/bin/syscraft-pelican-tools wait-for-registrations
bash /usr/local/bin/syscraft-pelican-tools approve-current

echo "Clearing stale Director/Cache routing state and incident marker"
rm -f "${LAB_DIR}/federation/incident.log"
ssh "${SSH_OPTS[@]}" node2 'rm -rf /opt/syscraft-pelican/cache/storage/* /opt/syscraft-pelican/client/*'

echo "Refreshing Registry and Director state after approval"
systemctl restart pelican-registry.service pelican-director.service
ssh "${SSH_OPTS[@]}" node2 "systemctl restart pelican-cache.service"

for url in \
    https://node1:8444/.well-known/issuer.jwks \
    https://node0:8444/.well-known/pelican-configuration \
    https://node2:8444/.well-known/openid-configuration; do
    for attempt in $(seq 1 60); do
        if curl -kfsS --max-time 4 "$url" >/dev/null 2>&1; then
            echo "Ready: $url"
            break
        fi
        if [ "$attempt" = "60" ]; then
            echo "Timed out waiting for $url" >&2
            exit 1
        fi
        sleep 2
    done
done

echo "Fetching the object through Pelican"
ssh "${SSH_OPTS[@]}" node2 "source ${INCIDENT_ENV}; mkdir -p /opt/syscraft-pelican/client; podman run --rm --network host --entrypoint pelican -v /opt/syscraft-pelican/cache/etc:/etc/pelican:Z -v /opt/syscraft-pelican/client:/work:Z -w /work hub.opensciencegrid.org/pelican_platform/origin:${PELICAN_IMAGE_TAG} object get pelican://node0:8444\${PELICAN_NAMESPACE}/\${PELICAN_OBJECT} \${PELICAN_OBJECT}"

retrieved_path=$(ssh "${SSH_OPTS[@]}" node2 "find /opt/syscraft-pelican/client -type f | head -n1")
if [ -z "$retrieved_path" ]; then
    echo "Downloaded object path was not found under /opt/syscraft-pelican/client" >&2
    exit 1
fi

actual_sha=$(ssh "${SSH_OPTS[@]}" node2 "sha256sum '${retrieved_path}' | awk '{print \$1}'")
if [ "$actual_sha" != "$PELICAN_EXPECTED_SHA256" ]; then
    echo "Checksum mismatch: expected ${PELICAN_EXPECTED_SHA256}, got ${actual_sha}" >&2
    exit 1
fi

echo "Pelican namespace access restored with checksum ${actual_sha}"
