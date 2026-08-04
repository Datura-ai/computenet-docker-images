#!/usr/bin/env bash
# Launch one pearl-miner process per visible GPU.
#
# Env contract (pool-independent, injected by the Lium backend at filler launch):
#   PEARL_POOL_HOST    pool hostname (default pool.pearlhash.xyz)
#   PEARL_POOL_PORT    pool port (default 9000)
#   PEARL_POOL_WALLET  PRL payout address (required)
#   PEARL_POOL_WORKER  worker name shown in the pool (default: container hostname)
#   PEARL_MDL_WALLET   modelOS merge-mining payout address (reserved: pearlhash registers it
#                      pool-side per account, the miner CLI takes no MDL flag yet)
set -euo pipefail

if [[ -z "${PEARL_POOL_WALLET:-}" ]]; then
    echo "PEARL_POOL_WALLET is required" >&2
    exit 1
fi

POOL="${PEARL_POOL_HOST}:${PEARL_POOL_PORT}"
WORKER="${PEARL_POOL_WORKER:-$(hostname)}"

# `|| true` inside AND outside: nvidia-smi may be absent (no driver) and grep -c exits 1 on zero
# matches — either would kill the script via errexit/pipefail before the readable error below.
GPU_COUNT=$( (nvidia-smi -L 2>/dev/null || true) | grep -c . || true)
if [[ "${GPU_COUNT}" -eq 0 ]]; then
    echo "no NVIDIA GPUs visible" >&2
    exit 1
fi

LOG_DIR="${PEARL_LOG_DIR:-/var/log/pearl}"
mkdir -p "${LOG_DIR}"

# One process per GPU: pearl-miner's multi-GPU behavior is undocumented, per-GPU processes with
# CUDA_VISIBLE_DEVICES pinning work the same on 1-GPU and 8-GPU nodes. Worker names get a -g<i>
# suffix on multi-GPU nodes so the pool shows each GPU separately.
#
# Each process is tee'd into its own log file as well as the container's stdout: the sidecar reads
# per-GPU hashrate off those files, and on a miner's host we can reach neither `docker logs` nor the
# container filesystem. Process substitution rather than a `| tee` pipeline so $! stays the MINER's
# pid — through a pipe it would be tee's, and every miner crash would report tee's exit code 0.
pids=()
for ((i = 0; i < GPU_COUNT; i++)); do
    name="${WORKER}"
    if [[ "${GPU_COUNT}" -gt 1 ]]; then
        name="${WORKER}-g${i}"
    fi
    CUDA_VISIBLE_DEVICES="${i}" /usr/local/bin/pearl-miner \
        --host "${POOL}" --user "${PEARL_POOL_WALLET}" --worker "${name}" \
        > >(tee -a "${LOG_DIR}/gpu-${i}.log") 2>&1 &
    pids+=($!)
done

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

# Exit (and let the platform restart the container) as soon as any miner dies. `wait -n` is called
# WITHOUT pids (bash 5.1 returns a bogus 0 for an explicit pid that already exited) and with an
# errexit guard (a plain non-zero `wait -n` would abort the script before the log line and kill).
exit_code=0
wait -n || exit_code=$?
echo "a pearl-miner process exited with code ${exit_code}, shutting down" >&2
kill "${pids[@]}" 2>/dev/null || true
# A perpetual miner exiting is a failure even at code 0 (e.g. pool-initiated shutdown) — report
# non-zero so the platform never mistakes a dead filler for a completed job.
exit "$(( exit_code == 0 ? 1 : exit_code ))"
