#!/usr/bin/env bash
#
# Boot a Dolphin (dphn.ai) v2 inference worker inside a Lium pod: render worker.json from env,
# ensure the binary is present, then `dolphinpod-worker update && start`.
#
# The worker auto-scales to every GPU on the node (gpu_ids: null), so this image does NOT pick
# a GPU count. Which nodes are eligible (VRAM floor, supported arch) is the scheduler's job.
set -euo pipefail

DOLPHIN_HOME="${DOLPHIN_HOME:-/opt/dolphinpod}"
WORKER_BIN="${DOLPHIN_HOME}/dolphinpod-worker"
CONFIG_DIR="${HOME:-/root}/.config/dolphinpod"

API_KEY="${DOLPHIN_API_KEY:-}"
MODEL="${DOLPHIN_MODEL:-nvidia/Qwen3.6-35B-A3B-NVFP4}"
WORKER_TYPE="${DOLPHIN_WORKER_TYPE:-text-v}"
# Comma-separated GPU indices (e.g. "0,1"); empty -> null -> worker uses all GPUs on the node.
GPU_IDS="${DOLPHIN_GPU_IDS:-}"
# URL to fetch the worker binary when it is not baked in. From the per-account install script at
# v2.dphn.ai; the link expires, so it is passed at runtime, not baked. `update` refreshes it after.
WORKER_URL="${DOLPHIN_WORKER_URL:-}"

if [[ -z "${API_KEY}" ]]; then
    echo "[dolphin] DOLPHIN_API_KEY is required (dp-... key from v2.dphn.ai)." >&2
    exit 1
fi

mkdir -p "${CONFIG_DIR}"
gpu_ids_json="null"
if [[ -n "${GPU_IDS}" ]]; then
    gpu_ids_json="$(jq -Rc 'split(",") | map(select(length > 0) | tonumber)' <<<"${GPU_IDS}")"
fi
jq -n \
    --arg api "${API_KEY}" \
    --arg model "${MODEL}" \
    --arg worker_type "${WORKER_TYPE}" \
    --argjson gpu_ids "${gpu_ids_json}" \
    '{schema_version: 1, api_key: $api, model: $model, worker_type: $worker_type, gpu_ids: $gpu_ids}' \
    >"${CONFIG_DIR}/worker.json"

if [[ ! -x "${WORKER_BIN}" ]]; then
    if [[ -z "${WORKER_URL}" ]]; then
        echo "[dolphin] dolphinpod-worker not found and DOLPHIN_WORKER_URL is unset." >&2
        echo "[dolphin] Provide the binary URL from your v2.dphn.ai install script." >&2
        exit 1
    fi
    curl -fsSL "${WORKER_URL}" -o "${WORKER_BIN}"
    chmod +x "${WORKER_BIN}"
fi

cd "${DOLPHIN_HOME}"
"${WORKER_BIN}" update
exec "${WORKER_BIN}" start
