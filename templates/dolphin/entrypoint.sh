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
# GPU models that cannot boot the NVFP4 model yet (comma-separated, case-insensitive substrings
# matched against nvidia-smi GPU names). A100 is Ampere and will NOT boot nvfp4 per the Dolphin
# team, even though it clears the 70 GB VRAM floor. Extend as the network adds/removes support.
UNSUPPORTED_GPUS="${DOLPHIN_UNSUPPORTED_GPUS:-A100}"

require_api_key() {
    if [[ -z "${API_KEY}" ]]; then
        echo "[dolphin] DOLPHIN_API_KEY is required (dp-... key from v2.dphn.ai)." >&2
        exit 1
    fi
}

# Refuse (don't crash-loop) on GPUs the model can't run — VRAM size is not enough, the arch
# must support NVFP4. Runs regardless of DOLPHIN_GPU_IDS since it is a hard hardware limit.
assert_gpus_supported() {
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        return
    fi
    local gpu_names raw_patterns patterns=() pattern name
    if ! gpu_names="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null)"; then
        echo "[dolphin] could not query GPU names; skipping unsupported-GPU check." >&2
        return
    fi
    # Trim each comma-separated denylist entry once, up front (not per GPU).
    IFS=',' read -ra raw_patterns <<<"${UNSUPPORTED_GPUS}"
    for pattern in "${raw_patterns[@]}"; do
        pattern="$(echo "${pattern}" | xargs)"
        [[ -n "${pattern}" ]] && patterns+=("${pattern}")
    done

    while IFS= read -r name; do
        [[ -z "${name}" ]] && continue
        for pattern in "${patterns[@]}"; do
            if grep -qiF -- "${pattern}" <<<"${name}"; then
                echo "[dolphin] GPU '${name}' is not supported by Dolphin v2 (cannot boot NVFP4);" \
                     "refusing to start." >&2
                exit 1
            fi
        done
    done <<<"${gpu_names}"
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
    if ! vram_lines="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null)"; then
        echo "[dolphin] could not query GPU VRAM; leaving gpu_ids=null (worker uses all GPUs)." >&2
        return
    fi
    local available_count per_gpu_mb
    available_count="$(grep -c . <<<"${vram_lines}")"
    per_gpu_mb="$(head -n1 <<<"${vram_lines}" | tr -d ' ')"

    if [[ "${available_count}" -eq 0 || -z "${per_gpu_mb}" ]]; then
        echo "[dolphin] no GPUs detected; cannot start worker." >&2
        exit 1
    fi

    local chosen_gpu_count=""
    for count in ${ALLOWED_GPU_COUNTS}; do
        if [[ "${count}" -le "${available_count}" && $((count * per_gpu_mb)) -ge "${MIN_VRAM_MB}" ]]; then
            chosen_gpu_count="${count}"
            break
        fi
    done

    if [[ -z "${chosen_gpu_count}" ]]; then
        echo "[dolphin] ${available_count} GPU(s) x ${per_gpu_mb}MB cannot reach the ${MIN_VRAM_MB}MB VRAM floor" \
             "with an accepted count (${ALLOWED_GPU_COUNTS// /, }); refusing to start." >&2
        exit 1
    fi
    if [[ "${chosen_gpu_count}" -ge 8 ]]; then
        echo "[dolphin] warning: using ${chosen_gpu_count} GPUs; 8+ is not fully efficient." >&2
    fi

    local gpu_indices=()
    for ((i = 0; i < chosen_gpu_count; i++)); do
        gpu_indices+=("${i}")
    done
    GPU_IDS="$(IFS=,; echo "${gpu_indices[*]}")"
    echo "[dolphin] selected ${chosen_gpu_count} of ${available_count} GPU(s) (${per_gpu_mb}MB each): gpu_ids=${GPU_IDS}."
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
    assert_gpus_supported
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
