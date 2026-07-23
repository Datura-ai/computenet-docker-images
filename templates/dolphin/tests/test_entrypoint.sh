#!/usr/bin/env bash
#
# Unit + smoke tests for the dolphin entrypoint's per-GPU worker split (DAH-2465).
# Mocks nvidia-smi / curl / dolphinpod-worker on PATH; no GPU or network needed.
# Run: bash templates/dolphin/tests/test_entrypoint.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="${HERE}/../entrypoint.sh"
FAILURES=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        echo "ok   ${label}"
    else
        echo "FAIL ${label}: expected [${expected}] got [${actual}]"
        FAILURES=$((FAILURES + 1))
    fi
}

make_sandbox() {
    SANDBOX="$(mktemp -d)"
    mkdir -p "${SANDBOX}/bin"
    export PATH="${SANDBOX}/bin:${PATH}"
    export HOME="${SANDBOX}/home"
    mkdir -p "${HOME}"
}

mock_nvidia_smi() {
    # Args: one "index:vram_mb" pair per GPU; exit 1 when none given.
    local spec_file="${SANDBOX}/bin/gpus.txt"
    : >"${spec_file}"
    local pair
    for pair in "$@"; do
        echo "${pair%%:*}, ${pair##*:}" >>"${spec_file}"
    done
    cat >"${SANDBOX}/bin/nvidia-smi" <<EOF
#!/usr/bin/env bash
[[ -s "${spec_file}" ]] || exit 1
cat "${spec_file}"
EOF
    chmod +x "${SANDBOX}/bin/nvidia-smi"
}

# Source the entrypoint's function definitions only (main is guarded by BASH_SOURCE).
load_entrypoint() {
    export DOLPHIN_API_KEY="dp-test"
    # shellcheck disable=SC1090
    source "${ENTRYPOINT}"
}

plan_as_line() {
    plan_worker_gpu_sets | paste -sd'|' -
}

# ---------------------------------------------------------------- plan_worker_gpu_sets
test_plan() {
    make_sandbox
    load_entrypoint

    unset DOLPHIN_GPU_IDS DOLPHIN_WORKER_PER_GPU DOLPHIN_SPLIT_MIN_VRAM_MB || true

    mock_nvidia_smi "0:97887" "1:97887" "2:97887" "3:97887" "4:97887" "5:97887" "6:97887" "7:97887"
    assert_eq "8x96GB splits per GPU" "0|1|2|3|4|5|6|7" "$(plan_as_line)"

    mock_nvidia_smi "0:97887"
    assert_eq "single GPU keeps all-GPUs worker" "all" "$(plan_as_line)"

    mock_nvidia_smi "0:32607" "1:32607" "2:32607" "3:32607" "4:32607" "5:32607" "6:32607" "7:32607"
    assert_eq "8x32GB (5090) bundles into 2 workers x4 GPUs" "0,1,2,3|4,5,6,7" "$(plan_as_line)"

    mock_nvidia_smi "0:46068" "1:46068" "2:46068" "3:46068" "4:46068" "5:46068" "6:46068" "7:46068"
    assert_eq "8x48GB (L40S) bundles into 4 workers x2 GPUs" "0,1|2,3|4,5|6,7" "$(plan_as_line)"

    mock_nvidia_smi "0:46068" "1:46068" "2:46068" "3:46068"
    assert_eq "4x48GB bundles into 2 workers x2 GPUs" "0,1|2,3" "$(plan_as_line)"

    mock_nvidia_smi "0:46068" "1:46068"
    assert_eq "2x48GB (one bundle = whole node) keeps all-GPUs worker" "all" "$(plan_as_line)"

    mock_nvidia_smi "0:32607" "1:32607" "2:32607"
    assert_eq "3x32GB (one bundle = whole node) keeps all-GPUs worker" "all" "$(plan_as_line)"

    mock_nvidia_smi "0:81559" "1:81559"
    assert_eq "2xH100 splits per GPU" "0|1" "$(plan_as_line)"

    mock_nvidia_smi "0:97887" "1:32607"
    assert_eq "mixed VRAM below floor keeps all-GPUs worker" "all" "$(plan_as_line)"

    DOLPHIN_GPU_IDS="0,1"
    mock_nvidia_smi "0:97887" "1:97887" "2:97887"
    assert_eq "explicit DOLPHIN_GPU_IDS wins over split" "0,1" "$(plan_as_line)"
    unset DOLPHIN_GPU_IDS

    DOLPHIN_WORKER_PER_GPU="0"
    mock_nvidia_smi "0:97887" "1:97887"
    assert_eq "split disabled by env" "all" "$(plan_as_line)"
    unset DOLPHIN_WORKER_PER_GPU

    mock_nvidia_smi  # nvidia-smi exits 1
    assert_eq "nvidia-smi failure falls back to all-GPUs worker" "all" "$(plan_as_line)"
}

# ---------------------------------------------------------------- render_worker_config
test_render() {
    make_sandbox
    load_entrypoint

    local dir="${SANDBOX}/cfg-all"
    render_worker_config "${dir}" "all"
    assert_eq "config gpu_ids null for 'all'" "null" "$(jq -c '.gpu_ids' "${dir}/worker.json")"
    assert_eq "config api_key" "dp-test" "$(jq -r '.api_key' "${dir}/worker.json")"
    assert_eq "config mode 0600" "600" "$(stat -f '%Lp' "${dir}/worker.json" 2>/dev/null || stat -c '%a' "${dir}/worker.json")"

    dir="${SANDBOX}/cfg-split"
    render_worker_config "${dir}" "3"
    assert_eq "config gpu_ids pinned" "[3]" "$(jq -c '.gpu_ids' "${dir}/worker.json")"
}

# ---------------------------------------------------------------- spawn smoke test
test_spawn_smoke() {
    make_sandbox
    export DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}"
    mock_nvidia_smi "0:97887" "1:97887"
    cat >"${SANDBOX}/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${SANDBOX}/bin/curl"
    # Worker mock records each start's HOME + visible config, then sleeps.
    cat >"${DOLPHIN_HOME}/dolphinpod-worker" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "start" ]]; then
    jq -c '.gpu_ids' "\${HOME}/.config/dolphinpod/worker.json" >>"${SANDBOX}/starts.log"
    # A real worker opens its engine socket once the runtime + weights are on disk; that is
    # the signal siblings wait for, so the mock must produce it or instance 1 never launches.
    mkdir -p "${SANDBOX}/dp-\$\$" && touch "${SANDBOX}/dp-\$\$/v.sock"
    # exec, not a plain call: bash defers TERM until a foreground command returns, so a
    # non-exec sleep would outlive the test by its full duration and hang the suite.
    exec sleep 300
fi
exit 0
EOF
    chmod +x "${DOLPHIN_HOME}/dolphinpod-worker"

    DOLPHIN_API_KEY="dp-test" DOLPHIN_SPLIT_STAGGER_SECONDS=0 \
        METRICS_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock" bash "${ENTRYPOINT}" &
    local entry_pid=$!
    local waited=0
    while [[ ! -s "${SANDBOX}/starts.log" || "$(wc -l <"${SANDBOX}/starts.log")" -lt 2 ]]; do
        sleep 1
        waited=$((waited + 1))
        if [[ ${waited} -ge 20 ]]; then break; fi
    done
    kill -TERM "${entry_pid}" 2>/dev/null
    wait "${entry_pid}" 2>/dev/null
    assert_eq "two pinned workers started" "[0]
[1]" "$(sort "${SANDBOX}/starts.log" 2>/dev/null)"
}

# ---------------------------------------------------------------- shared cache wiring
test_prepare_instance_home() {
    make_sandbox
    load_entrypoint

    local shared="${SANDBOX}/home/.cache"
    local instance="${SANDBOX}/home/dolphin-workers/gpu0"
    prepare_instance_home "${instance}" "${shared}"

    # The symlink is what keeps ONE copy of the ~35GB cache: the closed worker binary scrubs
    # its child's environment, so HF_HOME/XDG_CACHE_HOME alone cannot be relied on.
    assert_eq "instance cache is a symlink" "yes" \
        "$([[ -L "${instance}/.cache" ]] && echo yes || echo no)"
    assert_eq "instance cache resolves to the shared dir" "${shared}" \
        "$(readlink "${instance}/.cache")"

    # Idempotent: a container restart must not stack links or fail.
    prepare_instance_home "${instance}" "${shared}"
    assert_eq "second call keeps one symlink" "${shared}" "$(readlink "${instance}/.cache")"

    # A real directory (single-worker layout upgraded in place) must NOT be clobbered.
    local legacy="${SANDBOX}/home/dolphin-workers/gpu1"
    mkdir -p "${legacy}/.cache"
    prepare_instance_home "${legacy}" "${shared}"
    assert_eq "existing real cache dir is left alone" "no" \
        "$([[ -L "${legacy}/.cache" ]] && echo yes || echo no)"
}

# ---------------------------------------------------------------- cold-cache seed gate
test_wait_for_cache_seed() {
    make_sandbox
    export METRICS_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock"
    load_entrypoint

    # Measured 2026-07-23: with only a fixed stagger, two cold workers downloaded the same
    # ~12 GB runtime side by side over a throttled link. Siblings must wait for a real engine.
    assert_eq "no socket yet means not seeded" "no" \
        "$(engine_socket_present && echo yes || echo no)"

    mkdir -p "${SANDBOX}/dp-abc"
    touch "${SANDBOX}/dp-abc/v.sock"
    assert_eq "an engine socket means seeded" "yes" \
        "$(engine_socket_present && echo yes || echo no)"

    # Already seeded -> returns at once (a warm node must not pay the wait).
    SEED_WAIT_SECONDS=30
    local started elapsed
    started=$(date +%s)
    wait_for_cache_seed 2>/dev/null
    elapsed=$(( $(date +%s) - started ))
    assert_eq "seeded cache returns immediately" "yes" \
        "$([[ ${elapsed} -le 2 ]] && echo yes || echo no)"

    # Never seeded -> bounded, then proceeds anyway rather than wedging the node.
    rm -f "${SANDBOX}/dp-abc/v.sock"
    SEED_WAIT_SECONDS=10
    started=$(date +%s)
    wait_for_cache_seed 2>/dev/null
    elapsed=$(( $(date +%s) - started ))
    assert_eq "unseeded cache gives up after the bound" "yes" \
        "$([[ ${elapsed} -ge 10 && ${elapsed} -le 20 ]] && echo yes || echo no)"

    # 0 disables the gate entirely.
    SEED_WAIT_SECONDS=0
    started=$(date +%s)
    wait_for_cache_seed 2>/dev/null
    elapsed=$(( $(date +%s) - started ))
    assert_eq "seed wait disabled by 0" "yes" \
        "$([[ ${elapsed} -le 2 ]] && echo yes || echo no)"

    unset METRICS_SOCKET_GLOB
}

# ------------------------------------------------- sidecar/watchdog wiring in split mode
test_split_sidecar_and_watchdog_wiring() {
    make_sandbox
    export DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}"
    mock_nvidia_smi "0:97887" "1:97887"
    cat >"${SANDBOX}/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${SANDBOX}/bin/curl"
    touch "${DOLPHIN_HOME}/metrics_sidecar.py" "${DOLPHIN_HOME}/watchdog.py"
    # Record which helper was launched and what engine count it was told about.
    cat >"${SANDBOX}/bin/python3" <<EOF
#!/usr/bin/env bash
echo "\$(basename "\$1") expected=\${DOLPHIN_ENGINES_EXPECTED:-unset}" >>"${SANDBOX}/python.log"
exec sleep 300
EOF
    chmod +x "${SANDBOX}/bin/python3"
    cat >"${DOLPHIN_HOME}/dolphinpod-worker" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "start" ]] && exec sleep 300
exit 0
EOF
    chmod +x "${DOLPHIN_HOME}/dolphinpod-worker"

    DOLPHIN_API_KEY="dp-test" DOLPHIN_SPLIT_STAGGER_SECONDS=0 bash "${ENTRYPOINT}" >/dev/null 2>&1 &
    local entry_pid=$!
    local waited=0
    while [[ ! -s "${SANDBOX}/python.log" ]] && (( waited < 20 )); do
        sleep 1
        waited=$((waited + 1))
    done
    sleep 1
    kill -TERM "${entry_pid}" 2>/dev/null
    wait "${entry_pid}" 2>/dev/null

    local log="${SANDBOX}/python.log"
    assert_eq "sidecar told how many engines to expect" "metrics_sidecar.py expected=2" \
        "$(grep metrics_sidecar "${log}" 2>/dev/null | head -1)"
    # The watchdog SIGKILLs every `vllm serve` in the container, so with N engines one wedge
    # would take down every bundle. It must stay off until it can target a single engine.
    assert_eq "watchdog stays off with 2 engines" "" \
        "$(grep watchdog "${log}" 2>/dev/null | head -1)"
}

# ------------------------------------------- per-engine watchdog hook (off by default)
test_per_engine_watchdog_hook() {
    make_sandbox
    export DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}"
    mock_nvidia_smi "0:97887" "1:97887"
    cat >"${SANDBOX}/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${SANDBOX}/bin/curl"
    touch "${DOLPHIN_HOME}/metrics_sidecar.py" "${DOLPHIN_HOME}/watchdog.py"
    cat >"${SANDBOX}/bin/python3" <<EOF
#!/usr/bin/env bash
echo "\$(basename "\$1") gpus=\${DOLPHIN_WATCHDOG_GPU_SET:-none} state=\$(basename "\${DOLPHIN_WATCHDOG_STATE:-none}")" >>"${SANDBOX}/python.log"
exec sleep 300
EOF
    chmod +x "${SANDBOX}/bin/python3"
    cat >"${DOLPHIN_HOME}/dolphinpod-worker" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "start" ]]; then
    mkdir -p "${SANDBOX}/dp-\$\$" && touch "${SANDBOX}/dp-\$\$/v.sock"
    exec sleep 300
fi
exit 0
EOF
    chmod +x "${DOLPHIN_HOME}/dolphinpod-worker"

    # The flag is what the watchdog task flips once it can target a single engine; until then
    # the default path (tested above) runs none. Each instance must get its own GPU set AND its
    # own state file, since one file cannot describe N engines.
    DOLPHIN_API_KEY="dp-test" DOLPHIN_SPLIT_STAGGER_SECONDS=0 DOLPHIN_WATCHDOG_MULTI_ENGINE=1 \
        METRICS_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock" bash "${ENTRYPOINT}" >/dev/null 2>&1 &
    local entry_pid=$!
    local waited=0
    while [[ "$(grep -c watchdog "${SANDBOX}/python.log" 2>/dev/null || echo 0)" -lt 2 ]] && (( waited < 25 )); do
        sleep 1
        waited=$((waited + 1))
    done
    kill -TERM "${entry_pid}" 2>/dev/null
    wait "${entry_pid}" 2>/dev/null

    assert_eq "one watchdog per bundle, each told its cards" "watchdog.py gpus=0 state=watchdog_state_gpu0.json
watchdog.py gpus=1 state=watchdog_state_gpu1.json" \
        "$(grep watchdog "${SANDBOX}/python.log" 2>/dev/null | sort)"
}

test_plan
test_render
test_prepare_instance_home
test_wait_for_cache_seed
test_per_engine_watchdog_hook
test_split_sidecar_and_watchdog_wiring
test_spawn_smoke

if [[ ${FAILURES} -gt 0 ]]; then
    echo "${FAILURES} test(s) failed"
    exit 1
fi
echo "all tests passed"
