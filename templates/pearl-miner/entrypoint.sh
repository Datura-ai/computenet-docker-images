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

# Take a newer miner build when the pinned major has one. The updater never fails the container: on
# any problem it installs nothing and the baked-in binary, still on PATH behind the install dir,
# runs instead.
"$(dirname "${BASH_SOURCE[0]}")/update_miner.sh" || true
export PATH="${PEARL_MINER_DIR:-/var/lib/pearl/bin}:${PATH}"

LOG_DIR="${PEARL_LOG_DIR:-/var/log/pearl}"
mkdir -p "${LOG_DIR}"

# One process for every GPU: PeakMiner drives them all itself and reports each card separately in
# its stats API, so there is nothing left for per-GPU processes to buy. The flip side is that one
# crash takes all the node's cards down, so the miner is supervised here rather than left to the
# platform: the validator runs a filler under `unless-stopped`, or under plain `on-failure` (no
# retry cap) when the backend marks the job `self_ending` (lium-io#1370), and the backend only
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
# exits 0 so the run ends instead of looking alive and earning nothing. Zero on purpose: under
# `restart: on-failure` every non-zero exit is restarted with no cap, and every restart begins with
# the counter below at zero (it lives in this process), so a non-zero cap exit would never end the
# run. A zero exit stays `exited` and the backend closes the run as STOPPED. That close carries no
# launch strike, so the node can get this image again on its next scheduling cycle. Under
# `unless-stopped` a zero exit is restarted too, so the cap ends nothing there. Genuine failures of
# this script (no wallet, no GPU, the supervisor itself dying) still exit non-zero.
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
            echo "peakminer exited with code ${exit_code}; ${restarts} exits in ${RESTART_WINDOW_SECONDS}s," \
                "cap ${MAX_RESTARTS} reached; giving the node back, exiting 0 so the reconciler closes the run" >&2
            # 0, not the miner's code: see the crash-loop ceiling comment above.
            return 0
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
# a bare `wait -n` would return the moment anything else finished. The code is passed through: 0 is
# the cap, anything else is the supervisor itself dying (errexit in the loop, a signal).
exit_code=0
wait "${miner_pid}" || exit_code=$?
echo "peakminer supervisor ended (code ${exit_code}), shutting down" >&2
exit "${exit_code}"
