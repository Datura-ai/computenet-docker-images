#!/usr/bin/env bash
#
# Boot Dolphin (dphn.ai) v2 inference worker(s) inside a Lium pod: render worker.json from env,
# ensure the binary is present, then supervise `dolphinpod-worker update && start` in a restart
# loop so workers can self-update while the container keeps running.
#
# DAH-2465: on multi-GPU nodes one worker is spawned per minimal VRAM bundle (the smallest card
# group that fits the model) instead of one tensor-sharded worker over every GPU. Every worker
# instance loads the FULL model, so sharding one worker across many cards wastes VRAM that would
# otherwise be KV cache: measured on prod, an 8x RTX PRO 6000 single worker reports 317 slots at
# ~13% VRAM/GPU while a 1x worker on the same card reports 72 slots at ~70%. Slots bound the
# concurrent batch and Dolphin pays per processed token, so more workers recover the lost
# concurrency. 96 GB cards get a worker per GPU, 48 GB cards one per pair, and so on; nodes that
# cannot form 2+ bundles keep the single all-GPUs worker.
#
# What multi-instance costs, and how each cost is paid here:
#   - config collision   -> per-instance HOME, so each worker reads its own worker.json
#   - N copies of 35 GB  -> per-instance HOME/.cache is a SYMLINK to the shared cache, so the
#                           weights land in one place no matter how the closed worker binary
#                           treats HF_HOME/XDG_CACHE_HOME (it scrubs its child's env)
#   - binary corruption  -> every write to the shared DOLPHIN_HOME goes through flock, staged
#                           into a temp file and renamed atomically (DAH-2475)
#   - metrics undercount -> the sidecar scrapes EVERY engine socket and tags each with its own
#                           dolphin_engine label; DOLPHIN_ENGINES_EXPECTED lets it report a
#                           dead engine as a gap instead of as a smaller token count
#   - one wedge kills all -> one watchdog per instance, scoped by DOLPHIN_WATCHDOG_INSTANCE_HOME,
#                           so a wedged engine is killed on its own and its siblings — including
#                           siblings sharing its card — keep serving
set -euo pipefail

DOLPHIN_HOME="${DOLPHIN_HOME:-/opt/dolphinpod}"
WORKER_BIN="${DOLPHIN_HOME}/dolphinpod-worker"
# Where the per-instance watchdogs write their state. The container's own filesystem, so the
# names below stay private to this container; the sidecar globs the same directory.
WATCHDOG_STATE_DIR="${DOLPHIN_WATCHDOG_STATE_DIR:-/tmp}"

API_KEY="${DOLPHIN_API_KEY:-}"
MODEL="${DOLPHIN_MODEL:-nvidia/Qwen3.6-35B-A3B-NVFP4}"
WORKER_TYPE="${DOLPHIN_WORKER_TYPE:-text-v}"
# Public, stable worker-binary URL (linux/amd64 only — the worker ships no arm64 build). `update`
# refreshes it after first launch. Override only if Dolphin moves the download.
WORKER_URL="${DOLPHIN_WORKER_URL:-https://updates.dphn.ai/dolphinpod-worker-v2_linux_amd64}"

# How often (seconds) to check WORKER_URL for a newly published binary while workers run.
CHECK_INTERVAL="${DOLPHIN_UPDATE_CHECK_SECONDS:-3600}"
# Worker liveness is checked this often; the etag poll fires once per CHECK_INTERVAL.
LIVENESS_INTERVAL=30

# Delay between initial worker spawns, AFTER the shared cache is seeded.
SPLIT_STAGGER_SECONDS="${DOLPHIN_SPLIT_STAGGER_SECONDS:-30}"

# DAH-2551: how long a SIGTERMed worker may take to exit before it is killed. A customer rent
# waits out this window, and the validator gives a filler container a 15 s docker-stop grace,
# so this must stay comfortably under it. 5 s measured on 8xB200: docker stop 12.4 s -> 6.8 s,
# every card still released cleanly (0 MiB, no compute apps, exit 0 rather than SIGKILL).
TERM_TIMEOUT_SECONDS="${DOLPHIN_TERM_TIMEOUT_SECONDS:-5}"
TERM_POLL_SECONDS="${DOLPHIN_TERM_POLL_SECONDS:-0.2}"

# On a cold node the siblings wait for the FIRST instance to finish seeding the shared cache
# instead of merely pausing a few seconds. Measured 2026-07-23: with a 30 s stagger both workers
# downloaded the ~12 GB runtime into their own staging directories side by side, doubling the
# bytes over a link that boostrun throttles to a few MB/s. Waiting for instance 0 to actually
# serve means the runtime AND the weights are on disk, so every sibling starts warm.
# 0 disables the wait (back to a plain stagger); the bound keeps a stuck seed from wedging
# the node forever.
SEED_WAIT_SECONDS="${DOLPHIN_SEED_WAIT_SECONDS:-5400}"
# The worker opens this socket once its engine is up; same path the metrics sidecar scrapes.
ENGINE_SOCKET_GLOB="${METRICS_SOCKET_GLOB:-/tmp/dp-*/v.sock}"

# DAH-2743: the name of the .pth file that turns on the offline mode of the HF library, written
# into the site-packages of every worker runtime. A .pth file, because Python runs it at startup
# even when the closed worker gives its child a clean environment.
HF_OFFLINE_PTH_NAME="zz-dolphin-hf-offline.pth"

# DAH-2475: DOLPHIN_HOME is a cache volume shared by every filler container on the node AND by
# every worker instance inside this one, so the binary download and the worker's self-update are
# cross-process critical sections — two cold workers writing the same path at once produce a
# corrupted binary and a crash loop.
DOLPHIN_LOCK="${DOLPHIN_HOME}/.dolphinpod.lock"
# A cold download on a slow miner link takes minutes; this only bounds a stuck holder, and on
# timeout we proceed anyway rather than fail the container.
DOLPHIN_LOCK_TIMEOUT="${DOLPHIN_LOCK_TIMEOUT:-900}"

# One line per GPU: "<index>, <value>" for one nvidia-smi field, total VRAM by default. Empty
# output when nvidia-smi is absent/failing.
detect_gpus() {
    nvidia-smi --query-gpu="index,${1:-memory.total}" --format=csv,noheader,nounits 2>/dev/null || true
}

# Name one instance's private files (HOME, watchdog state) by the cards it owns.
instance_tag() {
    local gpu_set="$1"
    echo "gpu${gpu_set//,/-}"
}

# Cut the cards into bundles of EXACTLY <bundle_size> and print one bundle per line. Cards come in
# as "<index>:<vram_mb>" in plan order. Fails without printing anything when a bundle would miss the
# VRAM floor, which is the caller's cue to keep the node on its single all-GPUs worker rather than
# launch it broken.
#
# Exactly, not evenly: the size IS vLLM's --tensor-parallel-size and only 1, 2, 4, 8, 16 are valid,
# so spreading a remainder over the bundles (9 cards over 4 -> 3,2,2,2) would hand one engine an
# invalid size and crash-loop it. Cards past the last whole bundle stay idle, which is what the
# backend did while it planned these bundles itself.
print_gpu_bundles_of_size() {
    local bundle_size="$1" split_min_vram_mb="$2"
    shift 2
    local cards=("$@") gpu_count=$#
    local bundles=() cursor=0 i bundle bundle_vram card
    while (( cursor + bundle_size <= gpu_count )); do
        bundle=""
        bundle_vram=0
        for (( i = cursor; i < cursor + bundle_size; i++ )); do
            card="${cards[$i]}"
            bundle="${bundle:+${bundle},}${card%%:*}"
            bundle_vram=$(( bundle_vram + ${card##*:} ))
        done
        if (( bundle_vram < split_min_vram_mb )); then
            return 1
        fi
        bundles+=("${bundle}")
        cursor=$(( cursor + bundle_size ))
    done
    (( ${#bundles[@]} > 0 )) || return 1
    printf '%s\n' "${bundles[@]}"
}

# Emit one line per worker to spawn: a comma-separated gpu_ids list, or the literal "all"
# (worker.json gpu_ids: null -> the worker auto-scales to every GPU on the node).
#
# Every worker instance loads the full model, so it needs the VRAM floor ("Running the full
# model requires 70 GB of VRAM", dphn.ai docs — the same figure the backend gates DPHN nodes
# on) across ITS cards. The plan gives each worker the smallest card group that clears the
# floor: 96 GB cards -> one worker per GPU, 48 GB cards -> one per pair, 32 GB -> one per
# triple-or-more; cards are spread evenly so none sits idle. Fewer than 2 such groups -> the
# node keeps the single all-GPUs worker.
plan_worker_gpu_sets() {
    if [[ -n "${DOLPHIN_GPU_IDS:-}" ]]; then
        echo "${DOLPHIN_GPU_IDS}"
        return
    fi
    local worker_per_gpu="${DOLPHIN_WORKER_PER_GPU:-1}"
    local split_min_vram_mb="${DOLPHIN_SPLIT_MIN_VRAM_MB:-71680}"
    if [[ "${worker_per_gpu}" != "1" ]]; then
        echo "all"
        return
    fi
    local cards=() index vram
    while IFS=',' read -r index vram; do
        index="${index//[[:space:]]/}"
        vram="${vram//[[:space:]]/}"
        [[ -n "${index}" && -n "${vram}" ]] || continue
        cards+=("${index}:${vram}")
    done < <(detect_gpus)
    local gpu_count=${#cards[@]}
    if (( gpu_count < 2 )); then
        echo "all"
        return
    fi
    # The smallest card decides how many cards one worker needs (Lium nodes are homogeneous;
    # min is the conservative choice for a mixed node).
    local min_vram=${cards[0]##*:} card
    for card in "${cards[@]}"; do
        if (( ${card##*:} < min_vram )); then
            min_vram=${card##*:}
        fi
    done
    if (( min_vram <= 0 )); then
        echo "all"
        return
    fi
    # A bundle's card count becomes vLLM's --tensor-parallel-size, which must divide the model's 16
    # attention heads: 1, 2, 4, 8, 16 and nothing else. Confirmed 2026-07-22 — an invalid size
    # crash-loops the engine before it even downloads the weights. The backend used to guarantee
    # this by planning bundles itself; it now hands the whole node to one container, so the rule
    # lives here. Round the VRAM answer UP to a valid size (3 cards -> 4), and if the node cannot
    # form even one such bundle, keep the single all-GPUs worker rather than crash-loop N of them.
    local cards_per_worker=$(( (split_min_vram_mb + min_vram - 1) / min_vram ))
    local valid_size
    for valid_size in 1 2 4 8 16; do
        if (( valid_size >= cards_per_worker )); then
            cards_per_worker=${valid_size}
            break
        fi
    done
    if (( cards_per_worker > 16 )); then
        echo "all"
        return
    fi
    local bundles
    if ! bundles="$(print_gpu_bundles_of_size "${cards_per_worker}" "${split_min_vram_mb}" "${cards[@]}")"; then
        echo "all"
        return
    fi
    # One bundle covering every card is the whole-node run, and "all" is how it has always been
    # written (worker.json gpu_ids: null). A single bundle that does NOT cover every card is a
    # different thing and must stay scoped: the leftover cards cannot join it without making the
    # tensor-parallel size invalid, so a node with 6 cards and a 4-card bundle runs on 4 and leaves
    # 2 idle — exactly what the backend used to plan before it handed the whole node over.
    if (( $(wc -l <<<"${bundles}") == 1 )) && (( cards_per_worker == gpu_count )); then
        echo "all"
        return
    fi
    printf '%s\n' "${bundles}"
}

# Render one worker.json into <config_dir>. gpu_set "all" -> gpu_ids null. 0600 up front:
# worker.json holds the api_key and the worker refuses a config readable beyond its owner
# ("contains secrets but is accessible beyond its owner").
render_worker_config() {
    local config_dir="$1" gpu_set="$2"
    local gpu_ids_json="null"
    if [[ "${gpu_set}" != "all" ]]; then
        gpu_ids_json="$(jq -Rc 'split(",") | map(select(length > 0) | tonumber)' <<<"${gpu_set}")"
    fi
    mkdir -p "${config_dir}"
    local config_path="${config_dir}/worker.json"
    touch "${config_path}"
    chmod 600 "${config_path}"
    jq -n \
        --arg api "${API_KEY}" \
        --arg model "${MODEL}" \
        --arg worker_type "${WORKER_TYPE}" \
        --argjson gpu_ids "${gpu_ids_json}" \
        '{schema_version: 1, api_key: $api, model: $model, worker_type: $worker_type, gpu_ids: $gpu_ids}' \
        >"${config_path}"
}

# Give an instance its own HOME (so worker.json cannot collide) while keeping ONE copy of the
# ~35 GB model+runtime cache. The symlink is what makes this safe: the closed worker binary
# scrubs its child's environment, so exporting HF_HOME/XDG_CACHE_HOME is not sufficient on its
# own — a path that resolves to the shared directory is.
prepare_instance_home() {
    local instance_home="$1" shared_cache="$2"
    mkdir -p "${instance_home}" "${shared_cache}"
    if [[ -L "${instance_home}/.cache" || ! -e "${instance_home}/.cache" ]]; then
        ln -sfn "${shared_cache}" "${instance_home}/.cache"
    fi
}

# True once any engine is serving: the worker opens its unix socket only after the runtime and
# the model weights are on disk, so this is the honest "shared cache is seeded" signal — and it
# needs no assumption about how the worker names its staging directories.
engine_socket_present() {
    compgen -G "${ENGINE_SOCKET_GLOB}" >/dev/null 2>&1
}

wait_for_cache_seed() {
    (( SEED_WAIT_SECONDS > 0 )) || return 0
    engine_socket_present && return 0
    echo "[dolphin] waiting up to ${SEED_WAIT_SECONDS}s for the first worker to seed the shared cache" >&2
    local waited=0
    while (( waited < SEED_WAIT_SECONDS )); do
        # background sleep + wait, so the TERM trap fires immediately instead of after the nap
        sleep 10 &
        wait $! || true
        waited=$((waited + 10))
        if engine_socket_present; then
            echo "[dolphin] shared cache seeded after ${waited}s; releasing siblings" >&2
            return 0
        fi
    done
    echo "[dolphin] cache not seeded after ${SEED_WAIT_SECONDS}s; starting siblings anyway" >&2
}

# Sleep in the background and wait on it, so a TERM reaches the trap immediately instead of after
# the nap. A plain `sleep` here makes `docker stop` wait out the full interval.
interruptible_sleep() {
    sleep "$1" &
    wait $! || true
}

published_etag() {
    curl -fsSI --max-time 30 "${WORKER_URL}" | awk 'tolower($1) == "etag:" {print $2}' | tr -d '\r'
}

with_dolphin_lock() {
    # flock ships in the CUDA base image (util-linux). If it is ever absent the writes below
    # are UNSERIALIZED and siblings can corrupt the shared binary, so say so loudly rather
    # than degrade into the "timed out" message, which reads like a slow peer.
    if ! command -v flock >/dev/null 2>&1; then
        echo "[dolphin] WARNING: flock missing, shared-cache writes are unserialized" >&2
        "$@"
        return
    fi
    (
        flock -w "${DOLPHIN_LOCK_TIMEOUT}" 9 || echo "[dolphin] cache lock wait timed out; proceeding" >&2
        "$@"
    ) 9>"${DOLPHIN_LOCK}"
}

download_worker_binary() {
    # Re-check under the lock: whoever held it may have just downloaded the binary for us.
    if [[ -x "${WORKER_BIN}" ]]; then
        return 0
    fi
    local staged
    staged="$(mktemp "${DOLPHIN_HOME}/.dolphinpod-worker.XXXXXX")"
    curl -fsSL "${WORKER_URL}" -o "${staged}"
    chmod +x "${staged}"
    # Atomic: even a lock timeout can never expose a half-written binary to a sibling.
    mv -f "${staged}" "${WORKER_BIN}"
}

# Download the worker binary if it isn't present yet; `update` refreshes it later.
ensure_worker_binary() {
    if [[ -x "${WORKER_BIN}" ]]; then
        return
    fi
    if [[ -z "${WORKER_URL}" ]]; then
        echo "[dolphin] dolphinpod-worker not found and DOLPHIN_WORKER_URL is unset." >&2
        echo "[dolphin] Provide the binary URL from your v2.dphn.ai install script." >&2
        exit 1
    fi
    with_dolphin_lock download_worker_binary
}

# `update` rewrites the binary in the shared cache volume, so siblings updating at once would
# race on the same file.
refresh_binary() {
    with_dolphin_lock "${WORKER_BIN}" update \
        || echo "[dolphin] update failed; starting current version" >&2
}

# The plan's outputs are read by the supervisor loop, by its traps and by the watchdogs alike, so
# they live at script scope instead of being threaded through six signatures.
GPU_SETS=()
INSTANCE_HOMES=()
WORKER_PIDS=()
WATCHDOG_PIDS=()
SIDECAR_PID=""
BASE_HOME="${HOME:-/root}"
SHARED_CACHE="${BASE_HOME}/.cache"

# Decide which cards each worker instance gets, then give every instance its own HOME and its own
# worker.json. Fills GPU_SETS (one entry per worker) and INSTANCE_HOMES parallel to it.
plan_worker_instances() {
    local gpu_set_line
    GPU_SETS=()
    while IFS= read -r gpu_set_line; do
        [[ -n "${gpu_set_line}" ]] && GPU_SETS+=("${gpu_set_line}")
    done < <(plan_worker_gpu_sets)


    local i
    INSTANCE_HOMES=()
    if (( ${#GPU_SETS[@]} == 1 )); then
        # Single-worker path: same config location as always (prod-proven behavior).
        INSTANCE_HOMES=("${BASE_HOME}")
    else
        for i in "${!GPU_SETS[@]}"; do
            INSTANCE_HOMES+=("${BASE_HOME}/dolphin-workers/$(instance_tag "${GPU_SETS[$i]}")")
            prepare_instance_home "${INSTANCE_HOMES[$i]}" "${SHARED_CACHE}"
        done
    fi
    for i in "${!GPU_SETS[@]}"; do
        render_worker_config "${INSTANCE_HOMES[$i]}/.config/dolphinpod" "${GPU_SETS[$i]}"
    done
    echo "[dolphin] spawning ${#GPU_SETS[@]} worker(s): $(printf '[%s] ' "${GPU_SETS[@]}")" >&2
}

# Metrics sidecar (DAH-2468): proxies every engine's uds /metrics onto :9101. Own restart loop with
# backoff so a broken sidecar can neither kill a worker nor spin hot. Orphaned python (if the
# subshell dies first on TERM) is reaped by container teardown when PID 1 exits. ENGINES_EXPECTED
# lets it publish up-vs-expected, so one dead engine among N reads as a gap rather than as a
# quieter machine.
start_metrics_sidecar() {
    export DOLPHIN_ENGINES_EXPECTED="${#GPU_SETS[@]}"
    SIDECAR_PID=""
    [[ -f "${DOLPHIN_HOME}/metrics_sidecar.py" ]] || return 0
    (
        while true; do
            python3 "${DOLPHIN_HOME}/metrics_sidecar.py" || true
            sleep 5
        done
    ) &
    SIDECAR_PID=$!
}

# Engine watchdog: restarts a vLLM engine that wedged inside a CUDA kernel (requests in flight,
# token counter frozen, GPU pinned at 100% on a third of normal power — observed live on this
# image 2026-07-23).
#
# One watchdog per instance, each told its own HOME. It reads only its own engine's socket and
# kills only its own processes, so a wedge on one instance no longer takes the others down: every
# worker is spawned with a HOME of its own, which /proc reports for the engine it exec'd and for
# the children below it, giving a home <-> pid <-> socket mapping. The cards cannot serve as that
# key alone once a node is planned per bundle, so they ride along as a label only. When the
# mapping is ambiguous the watchdog kills nothing and publishes engine_found 0.
#
# A single instance gets the unscoped watchdog and the original state path, so the single-worker
# fleet keeps exactly the behavior it runs today.
#
# State lives in the container's own /tmp, never on DOLPHIN_HOME: that volume is shared by every
# filler container on the node, so state there would mix the counters of every watchdog on the
# host (lium-io#1161). A restarted container keeps its /tmp, so a previous run's split is still
# cleared before starting — stale files would otherwise publish forever as dead watchdogs for
# instances that no longer exist.
start_engine_watchdogs() {
    WATCHDOG_PIDS=()
    [[ "${DOLPHIN_WATCHDOG_ENABLED:-1}" != "0" && -f "${DOLPHIN_HOME}/watchdog.py" ]] || return 0
    rm -f "${WATCHDOG_STATE_DIR}"/dolphin_watchdog_state*.json
    local i watchdog_gpu_set watchdog_instance_home watchdog_state
    for i in "${!GPU_SETS[@]}"; do
        watchdog_gpu_set=""
        watchdog_instance_home=""
        watchdog_state="${WATCHDOG_STATE_DIR}/dolphin_watchdog_state.json"
        if (( ${#GPU_SETS[@]} > 1 )); then
            watchdog_gpu_set="${GPU_SETS[$i]}"
            watchdog_instance_home="${INSTANCE_HOMES[$i]}"
            # Named from the home rather than from instance_tag again: watchdog.py derives its own
            # instance label the same way, so one construction feeds both sides.
            watchdog_state="${WATCHDOG_STATE_DIR}/dolphin_watchdog_state_$(basename "${INSTANCE_HOMES[$i]}").json"
        fi
        (
            while true; do
                DOLPHIN_WATCHDOG_GPU_SET="${watchdog_gpu_set}" \
                DOLPHIN_WATCHDOG_INSTANCE_HOME="${watchdog_instance_home}" \
                DOLPHIN_WATCHDOG_STATE="${watchdog_state}" \
                    python3 "${DOLPHIN_HOME}/watchdog.py" || true
                sleep 5
            done
        ) &
        WATCHDOG_PIDS+=($!)
    done
    if (( ${#GPU_SETS[@]} > 1 )); then
        echo "[dolphin] ${#WATCHDOG_PIDS[@]} per-engine watchdog(s) started" >&2
    fi
}

# DAH-2743: vLLM resolves the model's UNPINNED revision (`main`) through the Hub API on EVERY
# engine start, because the HF cache is keyed by commit sha — cached weights do not spare it.
# HuggingFace allows 500 API requests per 5 minutes PER IP for anonymous callers, and a farm of
# 13 machines behind one NAT IP (2 workers, 8 processes each) blows that on a simultaneous cold
# start. hf_hub then sleeps ~200 s on the 429 while the worker's own startup timeout kills the
# engine first, and the restart spends another burst of calls: on 2026-08-20 that livelock held
# seven prod machines at zero tokens for 13 h while their weights sat complete on disk.
#
# So once the cache is complete we turn the HF library to offline mode, and it reads the local
# snapshot without one network call. The switch is a .pth file in the runtime's site-packages,
# because the env var CANNOT be used here: the closed worker binary rebuilds its child's
# environment from a fixed whitelist (CUDA_*, HF_HOME, HOME, LD_LIBRARY_PATH, PATH, PWD,
# PYTHONNOUSERSITE, SHLVL, TMPDIR, XDG_CACHE_HOME) and drops the rest. Nothing else on the network
# changes, so the worker still updates its own binary from updates.dphn.ai.
hf_cache_dir_name() {
    # "nvidia/Qwen3.6-35B-A3B-NVFP4" -> "models--nvidia--Qwen3.6-35B-A3B-NVFP4", the HF cache layout.
    echo "models--${1//\//--}"
}

snapshot_under_ref_is_complete() {
    # Complete = the snapshot that `refs/main` NAMES holds the index, every shard the index names,
    # and the two files the tokenizer/config load needs.
    #
    # The ref decides, never "some complete snapshot on disk". The cache is keyed by commit sha, so
    # a new commit upstream gives the model a SECOND, half-downloaded snapshot beside the complete
    # old one — and hf_hub writes the new sha into refs/main BEFORE it fetches one byte (verified in
    # file_download.py). vLLM resolves `main` through that same ref, so a check that accepted the
    # old snapshot would take the node offline against a snapshot the engine never opens.
    local repo_dir="$1"
    local ref_file="${repo_dir}/refs/main"
    local revision snapshot index shard missing=0 listed=0
    # `$(<file)`, not `read`: hf_hub writes the sha with NO trailing newline, and `read` then
    # returns non-zero at EOF, which would reject every real cache on a real node.
    [[ -f "${ref_file}" ]] || return 1
    revision="$(<"${ref_file}")"
    [[ -n "${revision}" ]] || return 1
    snapshot="${repo_dir}/snapshots/${revision}/"
    index="${snapshot}model.safetensors.index.json"
    [[ -f "${index}" && -f "${snapshot}config.json" && -f "${snapshot}tokenizer.json" ]] || return 1
    while read -r shard; do
        listed=$((listed + 1))
        [[ -f "${snapshot}${shard}" ]] || missing=1
    done < <(grep -oE '"model-[^"]+\.safetensors"' "${index}" | tr -d '"' | sort -u)
    # A truncated index names no shard at all. Counting it as complete would take the node offline
    # against a cache the engine cannot load, so an empty list is a NO like any gap.
    (( listed > 0 && ! missing ))
}

model_cache_is_complete() {
    # EVERY copy of this model under the shared volume must be complete, not merely one of them.
    # The worker has moved its cache directory before (this entrypoint exports
    # <home>/.cache/huggingface, the worker uses <home>/.cache/dolphinpod-worker/cache), so a stale
    # complete copy under the old root can sit beside the half-downloaded copy the engine actually
    # reads. Accepting the stale one takes the node offline and the real download can never finish.
    # Demanding all of them only ever errs towards staying online, which is what the node did
    # before DAH-2743.
    #
    # The copies are SEARCHED rather than read from a fixed path, so the next move survives too.
    # `.locks` is PRUNED: hf_hub puts its download locks in `<cache>/.locks/models--<repo>/`, which
    # carries the very same directory name and holds no refs at all. Left in, that lock directory
    # reads as a forever-incomplete copy and the node never goes offline.
    local repo_dir found=0
    while read -r repo_dir; do
        found=1
        snapshot_under_ref_is_complete "${repo_dir}" || return 1
    done < <(find "${SHARED_CACHE}" -maxdepth 5 -name .locks -prune -o \
        -type d -name "$(hf_cache_dir_name "${MODEL}")" -print 2>/dev/null)
    (( found ))
}

worker_runtime_site_packages_dirs() {
    # Every runtime the worker downloaded under DOLPHIN_HOME. The glob covers the worker type and
    # the Python version, both of which can change under us when the worker updates itself.
    find "${DOLPHIN_HOME}/runtimes" -maxdepth 4 -type d -name site-packages 2>/dev/null
}

enable_hf_offline() {
    # Python runs every `import` line of a .pth file in site-packages at interpreter startup, so
    # the switch reaches a child whose environment the worker rebuilt without it.
    #
    # Do NOT block the Hub at the network level instead. Measured on 2026-08-21: with
    # `127.0.0.1 huggingface.co` in /etc/hosts the library raises on the connection error rather
    # than falling back to the cache, and every engine dies with "inference backend exited".
    # Offline mode is the path the library supports: a file that is absent from the repo reads as
    # absent instead of as an error.
    local site_dir target staged wrote=0
    while read -r site_dir; do
        target="${site_dir}/${HF_OFFLINE_PTH_NAME}"
        [[ -f "${target}" ]] && continue
        # Staged and renamed, like every other write to the shared DOLPHIN_HOME volume (DAH-2475).
        # A plain redirect truncates the file before it writes it, and a sibling container reads
        # this same path at every interpreter start, so it can get an empty file and call the Hub.
        if staged="$(mktemp "${site_dir}/.${HF_OFFLINE_PTH_NAME}.XXXXXX" 2>/dev/null)" \
            && printf 'import os; os.environ.setdefault("HF_HUB_OFFLINE", "1")\n' >"${staged}" \
            && mv -f "${staged}" "${target}"; then
            wrote=1
        else
            [[ -n "${staged}" ]] && rm -f "${staged}"
            echo "[dolphin] WARNING: cannot write ${target}; engine starts still depend on the Hub" >&2
        fi
    done < <(worker_runtime_site_packages_dirs)
    (( wrote )) && echo "[dolphin] model cache is complete; HF offline mode is on, so engine starts never wait on a Hub rate limit" >&2
    return 0
}

disable_hf_offline() {
    # The counterpart of enable_hf_offline, and the reason the switch is SYNCED rather than only
    # armed: DOLPHIN_MODEL can change under a container whose runtime still carries the .pth from
    # the previous model. Offline mode would then forbid the download the new model needs, and the
    # node could never mine again. An incomplete cache therefore always re-opens the Hub.
    local site_dir target removed=0
    while read -r site_dir; do
        target="${site_dir}/${HF_OFFLINE_PTH_NAME}"
        [[ -f "${target}" ]] || continue
        rm -f "${target}" 2>/dev/null && removed=1
    done < <(worker_runtime_site_packages_dirs)
    (( removed )) && echo "[dolphin] model cache is not complete; HF offline mode is off so the weights can be downloaded" >&2
    return 0
}

sync_hf_offline_with_cache() {
    if model_cache_is_complete; then
        enable_hf_offline
    else
        disable_hf_offline
    fi
}

spawn_instance() {
    local idx="$1"
    (cd "${DOLPHIN_HOME}" && HOME="${INSTANCE_HOMES[$idx]}" exec "${WORKER_BIN}" start) &
    WORKER_PIDS[idx]=$!
}

# DAH-2551: the wait is BOUNDED. A customer rent blocks on this teardown, and the old
# unbounded `wait` made the container exit only after the slowest worker — 8 vLLM engines
# holding 11-13 GB each take ~12s to release their CUDA memory (measured on 8xB200), so the
# renter paid for every one of those seconds. Past the bound the stragglers are killed: the
# container is force-removed right after anyway, so there is nothing left to flush.
terminate_workers() {
    local pid deadline any_alive
    for pid in ${WORKER_PIDS[@]+"${WORKER_PIDS[@]}"}; do
        [[ -n "${pid}" ]] && kill -TERM "${pid}" 2>/dev/null || true
    done

    deadline=$(( SECONDS + TERM_TIMEOUT_SECONDS ))
    while (( SECONDS < deadline )); do
        any_alive=0
        for pid in ${WORKER_PIDS[@]+"${WORKER_PIDS[@]}"}; do
            [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null && any_alive=1
        done
        (( any_alive )) || break
        sleep "${TERM_POLL_SECONDS}"
    done

    # Children first: a worker killed before its engine leaves the engine reparented to PID 1,
    # which is what the `wait` below would then hang on.
    for pid in ${WORKER_PIDS[@]+"${WORKER_PIDS[@]}"}; do
        [[ -n "${pid}" ]] || continue
        kill -0 "${pid}" 2>/dev/null || continue
        pkill -KILL -P "${pid}" 2>/dev/null || true
        kill -KILL "${pid}" 2>/dev/null || true
    done

    for pid in ${WORKER_PIDS[@]+"${WORKER_PIDS[@]}"}; do
        [[ -n "${pid}" ]] && wait "${pid}" 2>/dev/null || true
    done
}

on_term() {
    if [[ -n "${SIDECAR_PID}" ]]; then
        kill -TERM "${SIDECAR_PID}" 2>/dev/null || true
    fi
    local watchdog_pid
    for watchdog_pid in ${WATCHDOG_PIDS[@]+"${WATCHDOG_PIDS[@]}"}; do
        kill -TERM "${watchdog_pid}" 2>/dev/null || true
    done
    terminate_workers
    exit 0
}

# First start of every instance. Spaced out because instance 0 is what seeds the shared cache.
spawn_all_instances() {
    local i
    WORKER_PIDS=()
    # A warm node — the shared cache volume already holds the weights from an earlier container —
    # needs no Hub at all, not even for instance 0.
    sync_hf_offline_with_cache
    for i in "${!GPU_SETS[@]}"; do
        if (( i == 1 )); then
            # Only before the SECOND instance: once instance 0 serves, the runtime and the weights
            # are on disk, so 2..N all start warm and need no further wait.
            wait_for_cache_seed
            # Instance 0 has just seeded the cache, so it was the only process that ever needed the
            # Hub: close it for the siblings before they can spend the shared per-IP quota.
            sync_hf_offline_with_cache
        fi
        if (( i > 0 && SPLIT_STAGGER_SECONDS > 0 )); then
            interruptible_sleep "${SPLIT_STAGGER_SECONDS}"
        fi
        spawn_instance "${i}"
    done
}

# Keep the running workers alive until a NEW worker binary is published, respawning any that exit
# on their own meanwhile. Returns only when the whole set has to be restarted for an update.
supervise_running_workers_until_new_binary_published() {
    local running_etag="$1"
    local elapsed=0 i latest_etag
    while true; do
        interruptible_sleep "${LIVENESS_INTERVAL}"
        # Every cycle, because the seed wait ends when the first worker opens its engine socket,
        # about 30 s after start — minutes BEFORE the download of the weights completes (measured
        # on a cold 8xH100 node, 2026-08-21). A check at spawn time alone sees a partial cache and
        # leaves the container on the Hub for the rest of its life.
        sync_hf_offline_with_cache
        for i in "${!WORKER_PIDS[@]}"; do
            if ! kill -0 "${WORKER_PIDS[$i]}" 2>/dev/null; then
                wait "${WORKER_PIDS[$i]}" 2>/dev/null || true
                echo "[dolphin] worker [${GPU_SETS[$i]}] exited; restarting" >&2
                refresh_binary
                spawn_instance "${i}"
                # A worker exits to self-update onto a freshly published binary; refresh_binary
                # just pulled it, so re-baseline the etag — otherwise the poll below still sees the
                # old baseline and forces a redundant full restart of every worker.
                running_etag="$(published_etag || true)"
            fi
        done
        elapsed=$((elapsed + LIVENESS_INTERVAL))
        if (( elapsed < CHECK_INTERVAL )); then
            continue
        fi
        elapsed=0
        latest_etag="$(published_etag || true)"
        if [[ -n "${latest_etag}" && -n "${running_etag}" && "${latest_etag}" != "${running_etag}" ]]; then
            echo "[dolphin] new worker binary published; restarting workers to update" >&2
            return 0
        fi
    done
}

# The worker's own self-update downloads a new binary and then exits expecting an external
# supervisor to restart it (systemd in Dolphin's reference install) — so every (re)spawn goes
# through `update` (DAH-2457). The etag poll is the fallback for when no instance's self-update
# fires: a changed etag on WORKER_URL restarts them all.
run_worker_supervisor_loop() {
    local running_etag
    while true; do
        refresh_binary
        running_etag="$(published_etag || true)"
        spawn_all_instances
        supervise_running_workers_until_new_binary_published "${running_etag}"
        terminate_workers
        echo "[dolphin] workers stopped for update; restarting in 5s" >&2
        interruptible_sleep 5
    done
}

main() {
    if [[ -z "${API_KEY}" ]]; then
        echo "[dolphin] DOLPHIN_API_KEY is required (dp-... key from v2.dphn.ai)." >&2
        exit 1
    fi
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${SHARED_CACHE}}"
    export HF_HOME="${HF_HOME:-${XDG_CACHE_HOME}/huggingface}"

    ensure_worker_binary
    plan_worker_instances
    start_metrics_sidecar
    start_engine_watchdogs
    trap on_term TERM INT
    run_worker_supervisor_loop
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
