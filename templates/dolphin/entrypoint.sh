#!/usr/bin/env bash
#
# Boot a Dolphin (dphn.ai) v2 inference worker inside a Lium pod.
#
# Steps: render ~/.config/dolphinpod/worker.json from env -> ensure the dolphinpod-worker
# binary is present -> `dolphinpod-worker update && dolphinpod-worker start`. `update`
# self-updates the binary to the network's current version (bootstrap download links expire,
# so a stale baked-in binary would get kicked); `start` runs in the foreground as the pod CMD.
set -euo pipefail

DOLPHIN_HOME="${DOLPHIN_HOME:-/opt/dolphinpod}"
WORKER_BIN="${DOLPHIN_HOME}/dolphinpod-worker"
CONFIG_DIR="${HOME:-/root}/.config/dolphinpod"
CONFIG_PATH="${CONFIG_DIR}/worker.json"

# worker.json fields (see dphn.ai/docs/running-a-node). api_key is the only required value.
API_KEY="${DOLPHIN_API_KEY:-}"
MODEL="${DOLPHIN_MODEL:-nvidia/Qwen3.6-35B-A3B-NVFP4}"
WORKER_TYPE="${DOLPHIN_WORKER_TYPE:-text-v}"
# Comma-separated GPU indices (e.g. "0,1"). When empty we auto-select a valid slice below;
# an explicit value is respected as-is and skips selection.
GPU_IDS="${DOLPHIN_GPU_IDS:-}"
# URL to fetch the worker binary when it is not already in the image. Sourced from the
# per-account install script at v2.dphn.ai; these links expire, so it is passed at runtime,
# not baked in. Left empty once an official published binary URL exists.
WORKER_URL="${DOLPHIN_WORKER_URL:-}"

# The full model needs 70 GB of VRAM (dphn.ai/docs/running-a-node). Override for a different
# model footprint. 70 GiB expressed in MiB (nvidia-smi reports memory.total in MiB).
MIN_VRAM_MB="${DOLPHIN_MIN_VRAM_MB:-71680}"
# The network only accepts these GPU counts; odd counts (3, 5, ...) are rejected and 8+ is
# not fully efficient. We pick the SMALLEST count that reaches MIN_VRAM_MB.
ALLOWED_GPU_COUNTS="1 2 4 8 16"

require_api_key() {
    if [[ -z "${API_KEY}" ]]; then
        echo "[dolphin] DOLPHIN_API_KEY is required (dp-... key from v2.dphn.ai)." >&2
        exit 1
    fi
}

# Pick a valid GPU slice: the smallest allowed count whose combined VRAM reaches the floor.
# Assumes a homogeneous box (all GPUs same size), which is how Lium executors are provisioned.
# No-op when GPU_IDS is set explicitly or nvidia-smi is unavailable (build/test).
select_gpus() {
    if [[ -n "${GPU_IDS}" ]]; then
        echo "[dolphin] using operator-provided DOLPHIN_GPU_IDS=${GPU_IDS}."
        return
    fi
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo "[dolphin] nvidia-smi unavailable; leaving gpu_ids=null (worker uses all GPUs)." >&2
        return
    fi

    local vram_lines
    vram_lines="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits)"
    local available_count per_gpu_mb
    available_count="$(grep -c . <<<"${vram_lines}")"
    per_gpu_mb="$(head -n1 <<<"${vram_lines}" | tr -d ' ')"

    if [[ "${available_count}" -eq 0 || -z "${per_gpu_mb}" ]]; then
        echo "[dolphin] no GPUs detected; cannot start worker." >&2
        exit 1
    fi

    local chosen=""
    for count in ${ALLOWED_GPU_COUNTS}; do
        if [[ "${count}" -le "${available_count}" && $((count * per_gpu_mb)) -ge "${MIN_VRAM_MB}" ]]; then
            chosen="${count}"
            break
        fi
    done

    if [[ -z "${chosen}" ]]; then
        echo "[dolphin] ${available_count} GPU(s) x ${per_gpu_mb}MB cannot reach the ${MIN_VRAM_MB}MB VRAM floor" \
             "with an accepted count (${ALLOWED_GPU_COUNTS// /, }); refusing to start." >&2
        exit 1
    fi
    if [[ "${chosen}" -ge 8 ]]; then
        echo "[dolphin] warning: using ${chosen} GPUs; 8+ is not fully efficient." >&2
    fi

    local ids=()
    for ((i = 0; i < chosen; i++)); do
        ids+=("${i}")
    done
    GPU_IDS="$(IFS=,; echo "${ids[*]}")"
    echo "[dolphin] selected ${chosen} of ${available_count} GPU(s) (${per_gpu_mb}MB each): gpu_ids=${GPU_IDS}."
}

render_config() {
    mkdir -p "${CONFIG_DIR}"
    local gpu_json="null"
    if [[ -n "${GPU_IDS}" ]]; then
        gpu_json="$(jq -Rc 'split(",") | map(select(length > 0) | tonumber)' <<<"${GPU_IDS}")"
    fi
    jq -n \
        --arg api "${API_KEY}" \
        --arg model "${MODEL}" \
        --arg worker_type "${WORKER_TYPE}" \
        --argjson gpu_ids "${gpu_json}" \
        '{schema_version: 1, api_key: $api, model: $model, worker_type: $worker_type, gpu_ids: $gpu_ids}' \
        >"${CONFIG_PATH}"
    echo "[dolphin] wrote ${CONFIG_PATH} (model=${MODEL}, worker_type=${WORKER_TYPE}, gpu_ids=${gpu_json})."
}

ensure_binary() {
    if [[ -x "${WORKER_BIN}" ]]; then
        return
    fi
    if [[ -z "${WORKER_URL}" ]]; then
        echo "[dolphin] dolphinpod-worker not found and DOLPHIN_WORKER_URL is unset." >&2
        echo "[dolphin] Provide the binary URL from your v2.dphn.ai install script." >&2
        exit 1
    fi
    echo "[dolphin] downloading dolphinpod-worker from DOLPHIN_WORKER_URL ..."
    mkdir -p "${DOLPHIN_HOME}"
    curl -fsSL "${WORKER_URL}" -o "${WORKER_BIN}"
    chmod +x "${WORKER_BIN}"
}

main() {
    require_api_key
    select_gpus
    render_config
    ensure_binary
    cd "${DOLPHIN_HOME}"
    echo "[dolphin] updating worker binary ..."
    "${WORKER_BIN}" update
    echo "[dolphin] starting worker (foreground) ..."
    exec "${WORKER_BIN}" start
}

main "$@"
