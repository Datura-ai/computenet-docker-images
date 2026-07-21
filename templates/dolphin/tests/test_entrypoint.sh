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
    assert_eq "8x32GB (below floor) keeps all-GPUs worker" "all" "$(plan_as_line)"

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
    sleep 300
fi
exit 0
EOF
    chmod +x "${DOLPHIN_HOME}/dolphinpod-worker"

    DOLPHIN_API_KEY="dp-test" DOLPHIN_SPLIT_STAGGER_SECONDS=0 bash "${ENTRYPOINT}" &
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

test_plan
test_render
test_spawn_smoke

if [[ ${FAILURES} -gt 0 ]]; then
    echo "${FAILURES} test(s) failed"
    exit 1
fi
echo "all tests passed"
