#!/usr/bin/env bash
# Verifier script. Writes reward (0.0 or 1.0) to /logs/verifier/reward.txt
# Partial credit written to /logs/verifier/reward.json.

set -uo pipefail

# shellcheck source=/opt/syscraft/cloudlab-cluster-info.sh
source /opt/syscraft/cloudlab-cluster-info.sh 2>/dev/null || true

NODE0="${NODE0:-$(syscraft_node_cluster_ip node0)}"
NODE1="${NODE1:-$(syscraft_node_cluster_ip node1)}"
NODE2="${NODE2:-$(syscraft_node_cluster_ip node2)}"
NODE0="${NODE0:-10.10.1.1}"
NODE1="${NODE1:-10.10.1.2}"
NODE2="${NODE2:-10.10.1.3}"
NODE2_HOST="${NODE2_HOST:-$(syscraft_node_host node2)}"
NODE2_HOST="${NODE2_HOST:-node2}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

mkdir -p /logs/verifier

score=0
details=""

check() {
    local label="$1"
    local result="$2"   # "pass" or "fail"
    local points="$3"
    if [ "$result" = "pass" ]; then
        score=$((score + points))
        details="${details}  [PASS +${points}] ${label}\n"
    else
        details="${details}  [FAIL  +0] ${label}\n"
    fi
}

# ── Check 1: All 3 nodes UN — full healthy ring (60 pts) ─────────────────────
RING_STATUS=$(nodetool status 2>/dev/null || true)
DN_COUNT=$(echo "$RING_STATUS" | grep -c '^DN' || true)
UN_COUNT=$(echo "$RING_STATUS" | grep -c '^UN' || true)
DN_COUNT=$(echo "${DN_COUNT:-1}" | tr -d '[:space:]')
UN_COUNT=$(echo "${UN_COUNT:-0}" | tr -d '[:space:]')

# Initialize data-check variables so reward.json is always valid
ROW_COUNT_N0=0
ROW_COUNT_N2=0

ring_full=false
[ "${DN_COUNT:-1}" -eq 0 ] && [ "${UN_COUNT:-0}" -eq 3 ] && ring_full=true

if $ring_full; then
    check "all 3 nodes UN (${UN_COUNT} UN, ${DN_COUNT} DN)" "pass" 60
else
    check "all 3 nodes UN (got ${UN_COUNT} UN, ${DN_COUNT} DN — need 3 UN 0 DN)" "fail" 60
fi

# ── Checks 2-3: Only meaningful once ring is fully healthy ───────────────────
# Awarding data-integrity points while a DN node exists would credit
# Cassandra's built-in degraded-mode reads, not the agent's recovery work.

if $ring_full; then

    # ── Check 2: QUORUM read from node0 — all 5 rows accessible (25 pts) ────
    ROW_COUNT_N0=$(cqlsh "$NODE0" --request-timeout=15 \
        -e 'CONSISTENCY QUORUM; SELECT COUNT(*) FROM bench.kv;' 2>/dev/null \
        | grep -E '^\s+[0-9]+\s*$' | tr -d ' ' || echo 0)
    ROW_COUNT_N0=$(echo "${ROW_COUNT_N0:-0}" | tr -d '[:space:]')
    [ "${ROW_COUNT_N0:-0}" -ge 5 ] \
        && check "QUORUM read from node0: bench.kv has ≥5 rows (got ${ROW_COUNT_N0})" "pass" 25 \
        || check "QUORUM read from node0: bench.kv has ≥5 rows (got ${ROW_COUNT_N0})" "fail" 25

    # ── Check 3: QUORUM read from node2 — all 5 rows accessible (15 pts) ────
    ROW_COUNT_N2=$(ssh $SSH_OPTS "root@$NODE2_HOST" \
        "cqlsh $NODE2 --request-timeout=15 -e 'CONSISTENCY QUORUM; SELECT COUNT(*) FROM bench.kv;' 2>/dev/null | grep -E '^\s+[0-9]+\s*\$' | tr -d ' '" \
        2>/dev/null || echo 0)
    ROW_COUNT_N2=$(echo "${ROW_COUNT_N2:-0}" | tr -d '[:space:]')
    [ "${ROW_COUNT_N2:-0}" -ge 5 ] \
        && check "QUORUM read from node2: bench.kv has ≥5 rows (got ${ROW_COUNT_N2})" "pass" 15 \
        || check "QUORUM read from node2: bench.kv has ≥5 rows (got ${ROW_COUNT_N2})" "fail" 15

else
    details="${details}  [SKIP] QUORUM read from node0 (ring not fully healthy)\n"
    details="${details}  [SKIP] QUORUM read from node2 (ring not fully healthy)\n"
fi

# ── Compute final reward ──────────────────────────────────────────────────────
REWARD=$(echo "scale=2; $score / 100" | bc)
[ "$score" -eq 100 ] && REWARD="1.0"
[ "$score" -eq 0 ]   && REWARD="0.0"

printf "Score: %d/100  →  reward=%s\n" "$score" "$REWARD"
printf "%b\n" "$details"

echo "$REWARD" > /logs/verifier/reward.txt
cat > /logs/verifier/reward.json <<JSON
{
  "reward": $REWARD,
  "score": $score,
  "max_score": 100,
  "checks": {
    "all_three_nodes_un": $( $ring_full && echo true || echo false),
    "quorum_read_node0": $([ "${ROW_COUNT_N0:-0}" -ge 5 ] 2>/dev/null && echo true || echo false),
    "quorum_read_node2": $([ "${ROW_COUNT_N2:-0}" -ge 5 ] 2>/dev/null && echo true || echo false)
  }
}
JSON
