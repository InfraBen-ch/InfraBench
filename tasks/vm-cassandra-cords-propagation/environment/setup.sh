#!/usr/bin/env bash
# Runs on all CloudLab nodes. Installs Cassandra and local audit dependencies.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

CASSANDRA_VERSION="4.1.8"
CASSANDRA_DIR="/opt/apache-cassandra-${CASSANDRA_VERSION}"
CASSANDRA_LINK="/opt/apache-cassandra"
CASSANDRA_URL="https://archive.apache.org/dist/cassandra/${CASSANDRA_VERSION}/apache-cassandra-${CASSANDRA_VERSION}-bin.tar.gz"

apt-get update
apt-get install -y --no-install-recommends \
    bc \
    ca-certificates \
    curl \
    dnsutils \
    iproute2 \
    lsof \
    netcat-openbsd \
    openjdk-11-jre-headless \
    python3 \
    python3-pip \
    python3-six \
    rsync \
    sysstat

if [ ! -d "$CASSANDRA_DIR" ]; then
    tmp_tgz="/tmp/apache-cassandra-${CASSANDRA_VERSION}.tar.gz"
    curl -fsSL "$CASSANDRA_URL" -o "$tmp_tgz"
    tar -xzf "$tmp_tgz" -C /opt
    rm -f "$tmp_tgz"
fi

ln -sfn "$CASSANDRA_DIR" "$CASSANDRA_LINK"
cp /usr/lib/python3/dist-packages/six.py "$CASSANDRA_LINK/bin/six.py"

python3 -m pip install --break-system-packages pyasyncore

cat >/usr/local/bin/cassandra-cql <<'PY'
#!/usr/bin/env python3
import argparse
import sys
import zipfile
from pathlib import Path

DRIVER_ZIP = Path("/opt/apache-cassandra/lib/cassandra-driver-internal-only-3.25.0.zip")
DRIVER_DIR = Path("/opt/apache-cassandra/lib/cassandra-driver-internal-only")


def ensure_driver_on_path() -> None:
    sys.path.insert(0, "/usr/lib/python3/dist-packages")
    if not DRIVER_DIR.exists():
        DRIVER_DIR.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(DRIVER_ZIP) as archive:
            archive.extractall(DRIVER_DIR)
    for child in DRIVER_DIR.iterdir():
        if child.is_dir() and child.name.startswith("cassandra-driver-"):
            sys.path.insert(0, str(child))
            return
    sys.path.insert(0, str(DRIVER_DIR))


ensure_driver_on_path()

from cassandra import ConsistencyLevel
from cassandra.cluster import Cluster
from cassandra.query import SimpleStatement


CONSISTENCY = {
    "ANY": ConsistencyLevel.ANY,
    "ONE": ConsistencyLevel.ONE,
    "TWO": ConsistencyLevel.TWO,
    "THREE": ConsistencyLevel.THREE,
    "QUORUM": ConsistencyLevel.QUORUM,
    "ALL": ConsistencyLevel.ALL,
    "LOCAL_QUORUM": ConsistencyLevel.LOCAL_QUORUM,
    "EACH_QUORUM": ConsistencyLevel.EACH_QUORUM,
    "SERIAL": ConsistencyLevel.SERIAL,
    "LOCAL_SERIAL": ConsistencyLevel.LOCAL_SERIAL,
    "LOCAL_ONE": ConsistencyLevel.LOCAL_ONE,
}


def split_statements(text: str) -> list[str]:
    statements: list[str] = []
    current: list[str] = []
    in_single = False
    in_double = False
    for ch in text:
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        if ch == ";" and not in_single and not in_double:
            statement = "".join(current).strip()
            if statement:
                statements.append(statement)
            current = []
        else:
            current.append(ch)
    trailing = "".join(current).strip()
    if trailing:
        statements.append(trailing)
    return statements


def format_row(row) -> str:
    return " | ".join("" if value is None else str(value) for value in row)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("host")
    parser.add_argument("port", type=int)
    parser.add_argument("-f", "--file")
    parser.add_argument("-e", "--execute")
    args = parser.parse_args()

    if bool(args.file) == bool(args.execute):
        parser.error("provide exactly one of -f/--file or -e/--execute")

    text = Path(args.file).read_text() if args.file else args.execute
    statements = split_statements(text)

    cluster = Cluster([args.host], port=args.port)
    session = cluster.connect()
    consistency = ConsistencyLevel.ONE
    try:
        for statement in statements:
            upper = statement.upper()
            if upper.startswith("CONSISTENCY "):
                level = statement.split(None, 1)[1].strip().upper()
                consistency = CONSISTENCY[level]
                continue
            if upper.startswith("TRACING "):
                continue

            result = session.execute(SimpleStatement(statement, consistency_level=consistency))
            if result.column_names:
                for row in result:
                    print(format_row(row))
    finally:
        cluster.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod +x /usr/local/bin/cassandra-cql

cat >/etc/profile.d/syscraft-cassandra.sh <<'EOF'
export CASSANDRA_HOME=/opt/apache-cassandra-4.1.8
export PATH=/opt/apache-cassandra/bin:$PATH
EOF

chmod +x "$CASSANDRA_LINK/bin/"*

mkdir -p /var/lib/cassandra /var/log/cassandra /opt/syscraft-lab

java -version
"$CASSANDRA_LINK/bin/cassandra" -v
