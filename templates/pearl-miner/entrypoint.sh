#!/usr/bin/env bash
# Launch PeakMiner across every visible GPU.
#
# Env contract (pool-independent, injected by the Lium backend at filler launch):
#   PEARL_POOL_HOST      pool hostname (default prl.kryptex.network)
#   PEARL_POOL_PORT      pool port (default 7048)
#   PEARL_POOL_WALLET    PRL payout address (required)
#   PEARL_POOL_WORKER    worker name shown in the pool (default: container hostname)
#   PEARL_POOL_FAILOVER  optional "host:port,host:port" tried in order when the primary is down
set -euo pipefail

if [[ -z "${PEARL_POOL_WALLET:-}" ]]; then
    echo "PEARL_POOL_WALLET is required" >&2
    exit 1
fi

WORKER="${PEARL_POOL_WORKER:-$(hostname)}"

# `|| true` inside AND outside: nvidia-smi may be absent (no driver) and grep -c exits 1 on zero
# matches — either would kill the script via errexit/pipefail before the readable error below.
GPU_COUNT=$( (nvidia-smi -L 2>/dev/null || true) | grep -c . || true)
if [[ "${GPU_COUNT}" -eq 0 ]]; then
    echo "no NVIDIA GPUs visible" >&2
    exit 1
fi

# One --url per pool, primary first: PeakMiner moves to the next one on its own when a pool stops
# answering. The failover list is what keeps a dead pool from idling the whole fleet again.
pool_args=(--url "${PEARL_POOL_HOST}:${PEARL_POOL_PORT}")
if [[ -n "${PEARL_POOL_FAILOVER:-}" ]]; then
    IFS=',' read -ra failover_pools <<< "${PEARL_POOL_FAILOVER}"
    for pool in "${failover_pools[@]}"; do
        pool="${pool//[[:space:]]/}"
        [[ -n "${pool}" ]] && pool_args+=(--url "${pool}")
    done
fi

LOG_DIR="${PEARL_LOG_DIR:-/var/log/pearl}"
mkdir -p "${LOG_DIR}"

# One process for every GPU: PeakMiner drives them all itself and reports each card separately in
# its stats API, so there is nothing left for per-GPU processes to buy.
#
# --log-file mirrors the log the sidecar serves on /logs, because on a miner's host we can reach
# neither `docker logs` nor the container filesystem; --log-append keeps history across a restart,
# which is exactly when the log is worth reading. The stats API stays on the container's loopback
# (PeakMiner's default): it has no authentication, and the sidecar is the authenticated way out.
/usr/local/bin/peakminer \
    --coin pearl "${pool_args[@]}" \
    --user "${PEARL_POOL_WALLET}.${WORKER}" \
    --log-file "${LOG_DIR}/peakminer.log" --log-append &
miner_pid=$!

# The metrics sidecar, only when the platform gave us a token — it refuses to start without one, and
# an unguarded restart loop would spin forever on nodes that never enable metrics. Wrapped in a
# forever-loop so it never exits: `wait -n` below has no way to tell WHICH child died, so a sidecar
# that could exit would look exactly like a dead miner and take the whole container down with it.
if [[ -n "${METRICS_TOKEN:-}" ]]; then
    (
        while true; do
            PEARL_LOG_DIR="${LOG_DIR}" PEARL_GPU_COUNT="${GPU_COUNT}" \
                python3 /usr/local/bin/metrics_sidecar.py || true
            echo "metrics sidecar exited, restarting in 5s" >&2
            sleep 5
        done
    ) &
fi

# Exit (and let the platform restart the container) as soon as the miner dies. `wait -n` is called
# WITHOUT pids (bash 5.1 returns a bogus 0 for an explicit pid that already exited) and with an
# errexit guard (a plain non-zero `wait -n` would abort the script before the log line and kill).
exit_code=0
wait -n || exit_code=$?
echo "peakminer exited with code ${exit_code}, shutting down" >&2
kill "${miner_pid}" 2>/dev/null || true
# A perpetual miner exiting is a failure even at code 0 (e.g. pool-initiated shutdown) — report
# non-zero so the platform never mistakes a dead filler for a completed job.
exit "$(( exit_code == 0 ? 1 : exit_code ))"
