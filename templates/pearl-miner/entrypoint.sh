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
# its stats API, so there is nothing left for per-GPU processes to buy. The flip side is that one
# crash takes all the node's cards down, so the miner is supervised here rather than left to the
# platform: nothing sets a docker restart policy on a filler container, and the backend only
# relaunches on its own scheduling cycle (self-heal is off by default), so an unsupervised crash
# costs the whole node until a cycle notices.
#
# --log-file mirrors the log the sidecar serves on /logs, because on a miner's host we can reach
# neither `docker logs` nor the container filesystem; --log-append keeps history across a restart,
# which is exactly when the log is worth reading. The stats API stays on the container's loopback
# (PeakMiner's default): it has no authentication, and the sidecar is the authenticated way out.
RESTART_DELAY_SECONDS="${PEARL_MINER_RESTART_DELAY_SECONDS:-10}"
# Crash-loop ceiling: a miner that dies for a reason restarting cannot fix (bad wallet, pool
# rejecting us, a card gone) must NOT be hidden behind a forever-loop — past the cap the container
# exits non-zero so the platform sees a failed filler instead of a node that looks alive and earns
# nothing. That is the failure mode this whole image exists to end.
MAX_RESTARTS="${PEARL_MINER_MAX_RESTARTS:-5}"
RESTART_WINDOW_SECONDS="${PEARL_MINER_RESTART_WINDOW_SECONDS:-600}"

supervise_miner() {
    local exit_code=0 now=0 window_started_at=0 restarts=0
    while true; do
        set +e
        peakminer \
            --coin pearl "${pool_args[@]}" \
            --user "${PEARL_POOL_WALLET}.${WORKER}" \
            --log-file "${LOG_DIR}/peakminer.log" --log-append
        exit_code=$?
        set -e

        # Deaths are counted per fixed window rather than as a rolling history: a miner that runs
        # fine for a window and then dies once is a blip and starts a fresh count, while one dying
        # repeatedly inside a single window is the crash loop we refuse to hide.
        now=$(date +%s)
        if (( now - window_started_at >= RESTART_WINDOW_SECONDS )); then
            window_started_at="${now}"
            restarts=0
        fi
        restarts=$(( restarts + 1 ))

        if (( restarts > MAX_RESTARTS )); then
            echo "peakminer exited with code ${exit_code}; ${restarts} restarts in ${RESTART_WINDOW_SECONDS}s — giving up" >&2
            # Non-zero even when the miner exited 0: a perpetual miner that stops is a failure, and a
            # zero here would read to the platform as a filler that finished its work.
            return "$(( exit_code == 0 ? 1 : exit_code ))"
        fi
        echo "peakminer exited with code ${exit_code}, restarting in ${RESTART_DELAY_SECONDS}s" >&2
        sleep "${RESTART_DELAY_SECONDS}"
    done
}

supervise_miner &
miner_pid=$!

# The metrics sidecar, only when the platform gave us a token — it refuses to start without one, and
# an unguarded restart loop would spin forever on nodes that never enable metrics. Wrapped in a
# forever-loop so a sidecar crash never leaves the node unobservable while the miner keeps earning.
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

# The supervisor only returns once it has given up on the miner, so reaching this line means the
# container really is done. Waited on BY PID (not `wait -n`): the sidecar loop is also a child, and
# a bare `wait -n` would return the moment anything else finished.
exit_code=0
wait "${miner_pid}" || exit_code=$?
echo "peakminer supervisor gave up (code ${exit_code}), shutting down" >&2
exit "$(( exit_code == 0 ? 1 : exit_code ))"
