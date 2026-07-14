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

GPU_COUNT=$(nvidia-smi -L 2>/dev/null | wc -l || echo 0)
if [[ "${GPU_COUNT}" -eq 0 ]]; then
    echo "no NVIDIA GPUs visible" >&2
    exit 1
fi

# One process per GPU: pearl-miner's multi-GPU behavior is undocumented, per-GPU processes with
# CUDA_VISIBLE_DEVICES pinning work the same on 1-GPU and 8-GPU nodes. Worker names get a -g<i>
# suffix on multi-GPU nodes so the pool shows each GPU separately.
pids=()
for ((i = 0; i < GPU_COUNT; i++)); do
    name="${WORKER}"
    if [[ "${GPU_COUNT}" -gt 1 ]]; then
        name="${WORKER}-g${i}"
    fi
    CUDA_VISIBLE_DEVICES="${i}" /usr/local/bin/pearl-miner \
        --host "${POOL}" --user "${PEARL_POOL_WALLET}" --worker "${name}" &
    pids+=($!)
done

# Exit (and let the platform restart the container) as soon as any miner dies.
wait -n "${pids[@]}"
exit_code=$?
echo "a pearl-miner process exited with code ${exit_code}, shutting down" >&2
kill "${pids[@]}" 2>/dev/null || true
exit "${exit_code}"
