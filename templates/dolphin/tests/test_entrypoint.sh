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

assert_fails() {
    local label="$1"
    shift
    if "$@" 2>/dev/null; then
        echo "FAIL ${label}"
        FAILURES=$((FAILURES + 1))
    else
        echo "ok   ${label}"
    fi
}

mock_df_free_gb() {
    # df -Pk prints KiB; the entrypoint reads the 4th column of the second line.
    cat >"${SANDBOX}/bin/df" <<EOF
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/sda1 100000000 1 $(( $1 * 1048576 )) 1% /"
EOF
    chmod +x "${SANDBOX}/bin/df"
}

mock_df_fails() {
    cat >"${SANDBOX}/bin/df" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${SANDBOX}/bin/df"
}

make_sandbox() {
    SANDBOX="$(mktemp -d)"
    mkdir -p "${SANDBOX}/bin"
    export PATH="${SANDBOX}/bin:${PATH}"
    # A roomy disk by default: the download floor reads df, and a laptop under the floor would
    # otherwise fail every test that spawns a worker.
    mock_df_free_gb 900
    export HOME="${SANDBOX}/home"
    export DOLPHIN_WATCHDOG_STATE_DIR="${SANDBOX}/state"
    mkdir -p "${HOME}" "${DOLPHIN_WATCHDOG_STATE_DIR}"
    mock_curl
    engine_answers_health yes
    # An earlier test's pgrep stub stays on PATH (the sandbox bins stack); without its file it prints
    # nothing, which is what the real pgrep prints on a host with no engine.
    unset DOLPHIN_TEST_PGREP_FILE
}

mock_curl() {
    # ONE curl for the whole suite. A /health request over a unix socket succeeds when the socket
    # exists AND the test marked the engine healthy; every other curl fails, which is what the
    # inline stubs did before DAH-3341 made "serving" a health answer instead of a socket file.
    cat >"${SANDBOX}/bin/curl" <<EOF
#!/usr/bin/env bash
socket=""
for (( i = 1; i <= \$#; i++ )); do
    [[ "\${!i}" == "--unix-socket" ]] && { j=\$((i + 1)); socket="\${!j}"; }
done
[[ -n "\${socket}" && -e "\${socket}" && -f "${SANDBOX}/engine_healthy" ]] && exit 0
exit 1
EOF
    chmod +x "${SANDBOX}/bin/curl"
}

engine_answers_health() {
    # Args: yes|no. The socket file alone no longer means serving (DAH-3341).
    if [[ "$1" == "yes" ]]; then touch "${SANDBOX}/engine_healthy"; else rm -f "${SANDBOX}/engine_healthy"; fi
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
    # The entrypoint sets -euo pipefail for its own run, and sourcing leaks that into the harness:
    # under -e the first non-zero probe kills the whole suite mid-run, which looks the same as a
    # clean exit 1 whether or not anything actually failed. Put the harness's own options back.
    local harness_opts
    harness_opts="$(set +o)"
    # shellcheck disable=SC1090
    source "${ENTRYPOINT}"
    eval "${harness_opts}"
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

    # A bundle's card count IS vLLM's --tensor-parallel-size, and only 1/2/4/8/16 divide the model's
    # 16 attention heads. The backend used to guarantee that by planning bundles itself; it now
    # hands the whole node over, so a plan that emits any other size crash-loops that engine before
    # it downloads a byte. Both ways of producing one are covered:
    mock_nvidia_smi "0:32607" "1:32607" "2:32607" "3:32607" "4:32607" "5:32607"
    assert_eq "6x32GB rounds the 3-card bundle up to 4 and leaves 2 cards idle" \
        "0,1,2,3" "$(plan_as_line)"

    mock_nvidia_smi "0:46068" "1:46068" "2:46068" "3:46068" "4:46068" "5:46068" "6:46068" "7:46068" "8:46068"
    assert_eq "9x48GB cuts whole pairs and idles the odd card, never a bundle of 3" \
        "0,1|2,3|4,5|6,7" "$(plan_as_line)"

    mock_nvidia_smi "0:97887" "1:97887" "2:97887"
    assert_eq "3x96GB gives each card its own worker" "0|1|2" "$(plan_as_line)"

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
    # GNU first: `stat -f` means "the filesystem" there and succeeds with unrelated output,
    # so probing BSD-style first would silently pass garbage into the comparison.
    assert_eq "config mode 0600" "600" "$(stat -c '%a' "${dir}/worker.json" 2>/dev/null || stat -f '%Lp' "${dir}/worker.json")"

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
    mock_curl
    # Worker mock records each start's HOME + visible config, then sleeps.
    cat >"${DOLPHIN_HOME}/dolphinpod-worker" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "start" ]]; then
    jq -c '.gpu_ids' "\${HOME}/.config/dolphinpod/worker.json" >>"${SANDBOX}/starts.log"
    # A real worker opens its engine socket once the runtime + weights are on disk; that is
    # the signal siblings wait for, so the mock must produce it or instance 1 never launches.
    mkdir -p "${SANDBOX}/dp-\$\$" && touch "${SANDBOX}/dp-\$\$/v.sock"
    touch "${SANDBOX}/engine_healthy"
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
# ------------------------------------------------- worker log capture + spawn counters
test_worker_log_and_spawn_counters() {
    make_sandbox
    export DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    export DOLPHIN_WORKER_SPAWN_STATE="${SANDBOX}/spawns.json"
    mkdir -p "${DOLPHIN_HOME}"
    cat >"${DOLPHIN_HOME}/dolphinpod-worker" <<'STUB'
#!/usr/bin/env bash
echo "boom from worker"
exit 7
STUB
    chmod +x "${DOLPHIN_HOME}/dolphinpod-worker"
    load_entrypoint

    GPU_SETS=("0,1")
    INSTANCE_HOMES=("${SANDBOX}/home")
    spawn_instance 0
    wait "${WORKER_PIDS[0]}" 2>/dev/null
    spawn_instance 0
    wait "${WORKER_PIDS[0]}" 2>/dev/null

    assert_eq "worker stdout lands in the shared-volume log" "boom from worker" \
        "$(head -1 "${WORKER_LOG_DIR}/worker-0.log" 2>/dev/null)"
    # grep, not python3: an earlier test's sandbox may have left a python3 stub on PATH.
    assert_eq "spawn counter counts respawns" '"spawns":2' \
        "$(grep -o '"spawns":[0-9]*' "${DOLPHIN_WORKER_SPAWN_STATE}" 2>/dev/null | head -1)"
}

# ------------------------------------- DAH-2843: a respawn is spaced out like a cold start
test_respawns_are_staggered() {
    make_sandbox
    export DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    export DOLPHIN_WORKER_SPAWN_STATE="${SANDBOX}/spawns.json"
    mkdir -p "${DOLPHIN_HOME}"
    cat >"${DOLPHIN_HOME}/dolphinpod-worker" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
    chmod +x "${DOLPHIN_HOME}/dolphinpod-worker"
    load_entrypoint
    GPU_SETS=("0,1" "2,3")
    INSTANCE_HOMES=("${SANDBOX}/home" "${SANDBOX}/home")

    # Before anything ran, the gate must let the first worker through.
    assert_eq "the first spawn is never held back" "yes" \
        "$(if (( SECONDS - LAST_SPAWN_AT >= SPLIT_STAGGER_SECONDS )); then echo yes; else echo no; fi)"

    spawn_instance 0
    kill "${WORKER_PIDS[0]}" 2>/dev/null
    # Four workers that die together used to come back together and read the same 23 GB at once.
    assert_eq "a sibling waits its turn in the same cycle" "no" \
        "$(if (( SECONDS - LAST_SPAWN_AT >= SPLIT_STAGGER_SECONDS )); then echo yes; else echo no; fi)"

    # The gate is a timestamp, so the wait costs nothing: a later cycle lets the sibling in.
    LAST_SPAWN_AT=$(( SECONDS - SPLIT_STAGGER_SECONDS ))
    assert_eq "a later cycle lets the sibling in" "yes" \
        "$(if (( SECONDS - LAST_SPAWN_AT >= SPLIT_STAGGER_SECONDS )); then echo yes; else echo no; fi)"

    # Driving the expression here would still pass if someone dropped it from the loop.
    assert_eq "the supervisor gates every respawn on it" "1" \
        "$(sed -n '/^supervise_running_workers_until_new_binary_published/,/^}/p' "${ENTRYPOINT}" \
            | grep -c 'SECONDS - LAST_SPAWN_AT >= SPLIT_STAGGER_SECONDS')"
}

# ------------------------------------- backoff keys on "served", not on how long the worker lived
test_backoff_counts_a_long_dead_download_as_failed() {
    make_sandbox
    export DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    export DOLPHIN_WORKER_SPAWN_STATE="${SANDBOX}/spawns.json"
    export METRICS_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock"
    mkdir -p "${DOLPHIN_HOME}"
    load_entrypoint

    GPU_SETS=("all")
    INSTANCE_HOMES=("${SANDBOX}/home")

    # The DAH-2763 incident: a runtime download that dies after 15-27 minutes, never serving.
    # A wall-clock rule would call that healthy; only "no engine socket" catches it.
    WORKER_SERVED=(0)
    WORKER_FAST_EXITS=(0)
    assert_eq "a worker that never served counts as a failed exit" "1" \
        "$(( ${WORKER_SERVED[0]} ? 0 : WORKER_FAST_EXITS[0] + 1 ))"

    WORKER_SERVED=(1)
    WORKER_FAST_EXITS=(3)
    assert_eq "a worker that served resets the streak" "0" \
        "$(( ${WORKER_SERVED[0]} ? 0 : WORKER_FAST_EXITS[0] + 1 ))"

    # A live engine socket is what marks the worker as served.
    mkdir -p "${SANDBOX}/dp-aaa" && touch "${SANDBOX}/dp-aaa/v.sock"
    assert_eq "an engine socket reads as serving" "0" "$(engine_socket_present; echo $?)"
    rm -rf "${SANDBOX}/dp-aaa"
    assert_eq "no socket reads as not serving" "1" "$(engine_socket_present; echo $?)"
}

# ------------------------------------------------- per-container log dir + pruning of dead ones
test_worker_logs_are_per_container_and_pruned() {
    make_sandbox
    export DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    export HOSTNAME="containerA"
    unset DOLPHIN_WORKER_LOG_DIR || true
    mkdir -p "${DOLPHIN_HOME}"
    load_entrypoint

    assert_eq "log dir is keyed on the container" "${DOLPHIN_HOME}/logs/containerA" "${WORKER_LOG_DIR}"

    mkdir -p "${DOLPHIN_HOME}/logs/containerA" "${DOLPHIN_HOME}/logs/oldcontainer" "${DOLPHIN_HOME}/logs/freshcontainer"
    touch -d "30 days ago" "${DOLPHIN_HOME}/logs/oldcontainer" 2>/dev/null \
        || touch -t "$(date -v-30d +%Y%m%d%H%M 2>/dev/null)" "${DOLPHIN_HOME}/logs/oldcontainer"
    prune_stale_worker_logs

    assert_eq "a dead container's old logs are pruned" "absent" \
        "$([[ -d "${DOLPHIN_HOME}/logs/oldcontainer" ]] && echo present || echo absent)"
    assert_eq "a recent container's logs are kept" "present" \
        "$([[ -d "${DOLPHIN_HOME}/logs/freshcontainer" ]] && echo present || echo absent)"
    assert_eq "our own log dir is never pruned" "present" \
        "$([[ -d "${DOLPHIN_HOME}/logs/containerA" ]] && echo present || echo absent)"
}

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
    mock_curl
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
    # One watchdog per bundle: it kills only the engine on its own cards, so a wedge no
    # longer costs the siblings. A single container-wide watchdog is what had to stay off.
    assert_eq "one watchdog per engine" "2" \
        "$(grep -c watchdog "${log}" 2>/dev/null || echo 0)"
}

# ------------------------------------------------- per-engine watchdog scoping in split mode
test_per_engine_watchdog_in_split_mode() {
    make_sandbox
    export DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}"
    mock_nvidia_smi "0:97887" "1:97887"
    mock_curl
    touch "${DOLPHIN_HOME}/metrics_sidecar.py" "${DOLPHIN_HOME}/watchdog.py"
    cat >"${SANDBOX}/bin/python3" <<EOF
#!/usr/bin/env bash
echo "\$(basename "\$1") gpus=\${DOLPHIN_WATCHDOG_GPU_SET:-none} home=\$(basename "\${DOLPHIN_WATCHDOG_INSTANCE_HOME:-none}") state=\$(basename "\${DOLPHIN_WATCHDOG_STATE:-none}")" >>"${SANDBOX}/python.log"
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

    # Each instance must get its own HOME AND its own state file: the HOME is how the watchdog
    # finds the one engine it may kill, and one file cannot describe N engines. The cards ride
    # along as a label — they cannot identify anything once two workers share a card.
    DOLPHIN_API_KEY="dp-test" DOLPHIN_SPLIT_STAGGER_SECONDS=0 \
        METRICS_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock" bash "${ENTRYPOINT}" >/dev/null 2>&1 &
    local entry_pid=$!
    local waited=0
    while [[ "$(grep -c watchdog "${SANDBOX}/python.log" 2>/dev/null || echo 0)" -lt 2 ]] && (( waited < 25 )); do
        sleep 1
        waited=$((waited + 1))
    done
    kill -TERM "${entry_pid}" 2>/dev/null
    wait "${entry_pid}" 2>/dev/null

    assert_eq "one watchdog per instance, each told its home" \
        "watchdog.py gpus=0 home=gpu0 state=dolphin_watchdog_state_gpu0.json
watchdog.py gpus=1 home=gpu1 state=dolphin_watchdog_state_gpu1.json" \
        "$(grep watchdog "${SANDBOX}/python.log" 2>/dev/null | sort)"
}

# --------------------------- single engine keeps the unscoped watchdog, and stale state goes
test_single_engine_watchdog() {
    make_sandbox
    export DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}"
    mock_nvidia_smi "0:97887"
    mock_curl
    touch "${DOLPHIN_HOME}/metrics_sidecar.py" "${DOLPHIN_HOME}/watchdog.py"
    # A restarted container keeps its /tmp, so a previous run's split leaves state files
    # behind. They would publish as dead watchdogs for bundles that no longer exist.
    echo '{}' >"${DOLPHIN_WATCHDOG_STATE_DIR}/dolphin_watchdog_state_gpu7.json"
    cat >"${SANDBOX}/bin/python3" <<EOF
#!/usr/bin/env bash
echo "\$(basename "\$1") gpus=\${DOLPHIN_WATCHDOG_GPU_SET:-none} home=\$(basename "\${DOLPHIN_WATCHDOG_INSTANCE_HOME:-none}") state=\$(basename "\${DOLPHIN_WATCHDOG_STATE:-none}")" >>"${SANDBOX}/python.log"
exec sleep 300
EOF
    chmod +x "${SANDBOX}/bin/python3"
    cat >"${DOLPHIN_HOME}/dolphinpod-worker" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "start" ]] && exec sleep 300
exit 0
EOF
    chmod +x "${DOLPHIN_HOME}/dolphinpod-worker"

    DOLPHIN_API_KEY="dp-test" bash "${ENTRYPOINT}" >/dev/null 2>&1 &
    local entry_pid=$!
    local waited=0
    while [[ "$(grep -c watchdog "${SANDBOX}/python.log" 2>/dev/null || echo 0)" -lt 1 ]] && (( waited < 20 )); do
        sleep 1
        waited=$((waited + 1))
    done
    kill -TERM "${entry_pid}" 2>/dev/null
    wait "${entry_pid}" 2>/dev/null

    # No GPU set: with one engine per container every vLLM process is that engine's, which is
    # the behavior the whole single-worker fleet runs today.
    assert_eq "single engine gets the unscoped watchdog" \
        "watchdog.py gpus=none home=none state=dolphin_watchdog_state.json" \
        "$(grep watchdog "${SANDBOX}/python.log" 2>/dev/null)"
    assert_eq "stale bundle state is cleared at boot" "" \
        "$(ls "${DOLPHIN_WATCHDOG_STATE_DIR}"/dolphin_watchdog_state_gpu7.json 2>/dev/null)"
}

# ---------------------------------------------------------------- terminate_workers bound
# DAH-2551: a worker that ignores SIGTERM must not hold the container past the bound — a
# customer rent is blocked on exactly this window.
test_terminate_workers_is_bounded() {
    make_sandbox
    load_entrypoint

    # Deaf worker: traps TERM and keeps running, like a vLLM engine still freeing its memory.
    bash -c 'trap "" TERM; sleep 300' &
    local deaf_pid=$!
    WORKER_PIDS=("${deaf_pid}")

    local started elapsed
    started="${SECONDS}"
    TERM_TIMEOUT_SECONDS=1 TERM_POLL_SECONDS=0.1 terminate_workers
    elapsed=$(( SECONDS - started ))

    if (( elapsed <= 3 )); then
        echo "ok   deaf worker killed within the bound (${elapsed}s)"
    else
        echo "FAIL deaf worker held the container for ${elapsed}s"
        FAILURES=$((FAILURES + 1))
    fi
    assert_eq "deaf worker is gone" "" "$(ps -o pid= -p "${deaf_pid}" 2>/dev/null | tr -d ' ')"
}

# ------------------------------------------------------------- HF hub offline mode (DAH-2743)
# 2026-08-20 prod: seven 8x5090 machines behind ONE NAT IP crash-looped their engines for 13 h.
# vLLM resolves the UNPINNED revision `main` through the Hub API on every engine start, the farm
# blew the anonymous 500-req/5-min per-IP quota, hf_hub slept ~200 s on the 429 and the worker's
# own startup timeout killed the engine first — a livelock the cached weights could not prevent.
hf_repo_cache_dir() {
    # The path the CLOSED worker uses, read off a live prod container
    # (HF_HOME=/root/.cache/dolphinpod-worker/cache) — NOT the HF_HOME this entrypoint exports.
    # The two differ, and a check pointed at ours finds an empty cache on every real node.
    echo "${SHARED_CACHE}/dolphinpod-worker/cache/hub/$(hf_cache_dir_name "${MODEL}")"
}

hf_snapshot_dir() {
    echo "$(hf_repo_cache_dir)/snapshots/${1:-deadbeef}"
}

point_hf_ref_main_at() {
    # hf_hub writes the sha into refs/main as soon as it resolves the revision, BEFORE it fetches
    # one byte. That is how a ref comes to name a snapshot that is still half on disk.
    mkdir -p "$(hf_repo_cache_dir)/refs"
    # NO trailing newline — that is exactly how huggingface_hub writes the file, and `read` would
    # report EOF on it.
    printf '%s' "$1" >"$(hf_repo_cache_dir)/refs/main"
}

seed_hf_cache_revision() {
    # Args: <revision> then the shard file names to actually create. The index always lists all
    # three shards, so leaving one out is how a half-downloaded cache is expressed.
    local revision="$1"
    shift
    local snapshot
    snapshot="$(hf_snapshot_dir "${revision}")"
    mkdir -p "${snapshot}"
    printf '%s' '{"weight_map":{"a":"model-00001-of-00003.safetensors","b":"model-00002-of-00003.safetensors","c":"model-00003-of-00003.safetensors"}}' \
        >"${snapshot}/model.safetensors.index.json"
    touch "${snapshot}/config.json" "${snapshot}/tokenizer.json"
    local shard
    for shard in "$@"; do
        touch "${snapshot}/${shard}"
    done
}

seed_hf_cache() {
    seed_hf_cache_revision deadbeef "$@"
    point_hf_ref_main_at deadbeef
    # hf_hub leaves a lock directory of the SAME name beside the cache on every download, and it
    # holds no refs. Every fixture carries it, so no check may trip over it.
    mkdir -p "${SHARED_CACHE}/dolphinpod-worker/cache/hub/.locks/$(hf_cache_dir_name "${MODEL}")"
    touch "${SHARED_CACHE}/dolphinpod-worker/cache/hub/.locks/$(hf_cache_dir_name "${MODEL}")/e7.lock"
}

test_model_cache_is_complete() {
    make_sandbox
    load_entrypoint

    assert_eq "empty cache is not complete" "no" \
        "$(model_cache_is_complete && echo yes || echo no)"

    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors"
    assert_eq "half-downloaded cache is not complete" "no" \
        "$(model_cache_is_complete && echo yes || echo no)"

    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors" \
        "model-00003-of-00003.safetensors"
    assert_eq "every shard present means complete" "yes" \
        "$(model_cache_is_complete && echo yes || echo no)"

    # A shard listed in the index but missing on disk is the seeder-died-midway case: it must
    # stay online and resume, never go offline against an unusable cache.
    rm "$(hf_snapshot_dir)/model-00002-of-00003.safetensors"
    assert_eq "a shard deleted after the fact reopens the network" "no" \
        "$(model_cache_is_complete && echo yes || echo no)"

    # A half-written index lists nothing; treating "no shard is missing" as complete would
    # take the node offline against a cache the engine cannot load.
    : >"$(hf_snapshot_dir)/model.safetensors.index.json"
    assert_eq "a truncated index is not complete" "no" \
        "$(model_cache_is_complete && echo yes || echo no)"

    # A cache for a DIFFERENT model must not license going offline for this one.
    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors" \
        "model-00003-of-00003.safetensors"
    MODEL="nvidia/SomeOtherModel"
    assert_eq "another model's cache does not count" "no" \
        "$(model_cache_is_complete && echo yes || echo no)"
}

test_the_cache_check_follows_the_model_the_worker_launches() {
    # DAH-3341, 2026-09-10: Dolphin's forced update to worker v2.4.2 moved the served model from
    # nvidia/Qwen3.6-35B-A3B-NVFP4 to unsloth/Qwen3.8-27B-NVFP4. DOLPHIN_MODEL still named the old
    # one, its cache was complete, the switch armed on it, and the engine could not download the
    # new weights on 32 prod nodes. The model the engine was STARTED with decides.
    make_sandbox
    load_entrypoint
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}/runtimes/text-v/bin"

    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors" \
        "model-00003-of-00003.safetensors"
    assert_eq "with no engine running, DOLPHIN_MODEL still decides" "yes" \
        "$(model_cache_is_complete && echo yes || echo no)"

    # An engine serving ANOTHER model. Its cache holds config + tokenizer and no shard, exactly
    # what a fresh model looks like the moment hf_hub wrote its ref.
    local other="unsloth/Qwen3.8-27B-NVFP4"
    engine_launched_models() { echo "${other}"; }
    local other_repo="${SHARED_CACHE}/dolphinpod-worker/cache/hub/$(hf_cache_dir_name "${other}")"
    mkdir -p "${other_repo}/refs" "${other_repo}/snapshots/beefdead"
    printf '%s' beefdead >"${other_repo}/refs/main"
    printf '%s' '{"weight_map":{"a":"model-00001-of-00001.safetensors"}}' \
        >"${other_repo}/snapshots/beefdead/model.safetensors.index.json"
    touch "${other_repo}/snapshots/beefdead/config.json" "${other_repo}/snapshots/beefdead/tokenizer.json"

    assert_eq "a complete cache for the OLD model licenses nothing" "no" \
        "$(model_cache_is_complete && echo yes || echo no)"

    touch "${other_repo}/snapshots/beefdead/model-00001-of-00001.safetensors"
    assert_eq "the launched model's own cache is what counts" "yes" \
        "$(model_cache_is_complete && echo yes || echo no)"
}

test_a_socket_that_answers_nothing_is_not_serving() {
    # DAH-3341: vLLM opened its unix socket at the END of the weight load, so the socket meant
    # serving. Aphrodite 0.24 (worker v2.4.2) opens it BEFORE loading, so a crash-looping engine
    # holds a socket that answers nothing — and the offline switch's self-heal never fired.
    make_sandbox
    export METRICS_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock"
    load_entrypoint

    mkdir -p "${SANDBOX}/dp-abc"
    touch "${SANDBOX}/dp-abc/v.sock"
    engine_answers_health no
    assert_eq "a socket is present" "yes" "$(engine_socket_present && echo yes || echo no)"
    assert_eq "but it is not serving" "no" "$(engine_is_serving && echo yes || echo no)"

    engine_answers_health yes
    assert_eq "an answering engine is serving" "yes" "$(engine_is_serving && echo yes || echo no)"
}

test_enable_hf_offline() {
    make_sandbox
    load_entrypoint
    local site_packages="${SANDBOX}/dolphinpod/runtimes/text-v/lib/python3.12/site-packages"
    mkdir -p "${site_packages}"
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"

    enable_hf_offline
    assert_eq "the offline switch lands in site-packages" "1" \
        "$(ls "${site_packages}/zz-dolphin-hf-offline.pth" 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "the switch sets HF_HUB_OFFLINE" "1" \
        "$(grep -c 'HF_HUB_OFFLINE' "${site_packages}/zz-dolphin-hf-offline.pth")"

    # A .pth file, not sitecustomize.py: the runtime belongs to the closed worker, and a file of
    # our own name can never overwrite one of theirs.
    assert_eq "no sitecustomize.py is written" "0" \
        "$(ls "${site_packages}/sitecustomize.py" 2>/dev/null | wc -l | tr -d ' ')"

    # The supervisor calls this every 30 s. It must not rewrite the file each time.
    local before after
    before=$(stat -f %m "${site_packages}/zz-dolphin-hf-offline.pth" 2>/dev/null || stat -c %Y "${site_packages}/zz-dolphin-hf-offline.pth")
    enable_hf_offline
    after=$(stat -f %m "${site_packages}/zz-dolphin-hf-offline.pth" 2>/dev/null || stat -c %Y "${site_packages}/zz-dolphin-hf-offline.pth")
    assert_eq "a second call leaves the file alone" "${before}" "${after}"

    # A worker that updates its runtime brings a new site-packages. The next call must arm it too.
    local second_site_packages="${SANDBOX}/dolphinpod/runtimes/text-v2/lib/python3.13/site-packages"
    mkdir -p "${second_site_packages}"
    enable_hf_offline
    assert_eq "a new runtime gets the switch as well" "1" \
        "$(ls "${second_site_packages}/zz-dolphin-hf-offline.pth" 2>/dev/null | wc -l | tr -d ' ')"

    # No runtime yet (cold container): must not fail under `set -e`. The harness puts errexit back
    # OFF after sourcing, so the claim is only worth anything inside a subshell that turns it on —
    # which is how the real entrypoint runs.
    DOLPHIN_HOME="${SANDBOX}/empty"
    assert_eq "no runtime directory is survivable under set -e" "ok" \
        "$(set -euo pipefail; enable_hf_offline 2>/dev/null && echo ok)"
}

test_hf_offline_wiring() {
    make_sandbox
    load_entrypoint
    export METRICS_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock"
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages"
    local pth_file="${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages/zz-dolphin-hf-offline.pth"
    install_stub_python
    touch "${SANDBOX}/topped_up"
    offline_mode_on() { [[ -f "${pth_file}" ]] && echo yes || echo no; }

    # Cold node: the cache must be seeded from the Hub, so the Hub stays reachable.
    sync_hf_offline_with_cache
    assert_eq "cold cache keeps the Hub reachable" "no" "$(offline_mode_on)"

    # Warm node (the shared cache volume already holds the weights) — no worker needs the Hub.
    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors" \
        "model-00003-of-00003.safetensors"
    sync_hf_offline_with_cache
    assert_eq "complete cache turns offline mode on" "yes" "$(offline_mode_on)"
}

test_hf_offline_is_re_evaluated_later() {
    make_sandbox
    load_entrypoint
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages"
    local pth_file="${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages/zz-dolphin-hf-offline.pth"
    install_stub_python
    touch "${SANDBOX}/topped_up"
    offline_mode_on() { [[ -f "${pth_file}" ]] && echo yes || echo no; }

    # Measured on a real cold node 2026-08-21: the worker opens its engine socket about 30 s after
    # start, while the download of the weights continues for minutes. The seed wait therefore ends
    # too early, and a check that runs one time only leaves the container online for its full life.
    seed_hf_cache "model-00001-of-00003.safetensors"
    sync_hf_offline_with_cache
    assert_eq "an early check with a partial cache stays online" "no" "$(offline_mode_on)"

    # The download completes some minutes later. The supervisor calls the same function again.
    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors" \
        "model-00003-of-00003.safetensors"
    sync_hf_offline_with_cache
    assert_eq "a later check turns offline mode on" "yes" "$(offline_mode_on)"

    # DOLPHIN_MODEL changes to a model this node has never held. The switch must come OFF again,
    # or offline mode forbids the very download the new model needs and the node never mines.
    MODEL="nvidia/SomeNewModel"
    sync_hf_offline_with_cache
    assert_eq "a new model re-opens the Hub" "no" "$(offline_mode_on)"

    # The two calls above drive the function directly, so they would still pass if someone deleted
    # the supervisor's call. Guard the wiring itself.
    assert_eq "the supervisor re-checks it every cycle" "1" \
        "$(sed -n '/^supervise_running_workers_until_new_binary_published/,/^}/p' "${ENTRYPOINT}" \
            | grep -c 'sync_hf_offline_with_cache_and_engines')"
}

# --- DAH-2843: the library, not our file list, decides whether offline mode may arm ------------

# A stand-in for the runtime interpreter. It answers like huggingface_hub 1.29 does: the local
# cache is refused until an online pass has run once. The mode is read from HF_HUB_OFFLINE, and
# the online pass leaves a marker, so the sequence check -> top-up -> check is observable.
install_stub_python() {
    local runtime_bin="${DOLPHIN_HOME}/runtimes/text-v/bin"
    mkdir -p "${runtime_bin}"
    cat >"${runtime_bin}/python" <<EOF
#!/usr/bin/env bash
echo "\${HF_HUB_OFFLINE}:\${HF_HOME}" >>"${SANDBOX}/hf_calls"
if [[ "\${HF_HUB_OFFLINE}" == "0" ]]; then
    echo "revision=\${DOLPHIN_HF_REVISION} ignore=\${DOLPHIN_HF_IGNORE}" >>"${SANDBOX}/hf_calls"
    ${1:-touch "${SANDBOX}/topped_up"}
    exit \${ONLINE_EXIT:-0}
fi
echo "offline-revision=\${DOLPHIN_HF_REVISION:-none}" >>"${SANDBOX}/hf_calls"
[[ -f "${SANDBOX}/topped_up" ]]
EOF
    chmod +x "${runtime_bin}/python"
}

test_hf_offline_waits_for_the_library() {
    make_sandbox
    load_entrypoint
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages"
    local pth_file="${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages/zz-dolphin-hf-offline.pth"
    offline_mode_on() { [[ -f "${pth_file}" ]] && echo yes || echo no; }
    install_stub_python
    ENGINE_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock"
    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors" \
        "model-00003-of-00003.safetensors"

    # The weights are all there, so the old check said "complete" and armed the switch at once.
    # The library still refuses the cache until the small files of the commit are fetched.
    sync_hf_offline_with_cache
    assert_eq "the missing small files are fetched once" "yes" \
        "$([[ -f "${SANDBOX}/topped_up" ]] && echo yes || echo no)"
    assert_eq "offline mode arms after the library accepts the cache" "yes" "$(offline_mode_on)"
    # Two offline calls, one before the top-up and one after, both against the cache ROOT: the
    # library resolves <HF_HOME>/hub/models--<repo> itself and cannot be handed the repo dir.
    assert_eq "HF_HOME is the cache root, not the repo dir" "2" \
        "$(grep -c "1:${SHARED_CACHE}/dolphinpod-worker/cache\$" "${SANDBOX}/hf_calls")"
    # Unpinned, the online call resolves `main` at call time. A commit published upstream in that
    # moment would make it fetch the new weights — 23 GB, past the disk floor.
    # Pinned, and unable to fetch a shard even so: a commit that lands between the check and the
    # call must never cost 23 GB of weights.
    assert_eq "the top-up is pinned and cannot fetch weights" \
        "revision=deadbeef ignore=*.safetensors,*.bin,*.pth,*.pt,*.ckpt,*.gguf,*.h5,*.msgpack,*.onnx" \
        "$(grep '^revision=' "${SANDBOX}/hf_calls" | head -1)"

    # Armed AND an engine serves: the files are proven good, so no interpreter runs on later cycles.
    mkdir -p "${SANDBOX}/dp-1/" && touch "${SANDBOX}/dp-1/v.sock"
    local calls_before
    calls_before="$(wc -l <"${SANDBOX}/hf_calls")"
    sync_hf_offline_with_cache
    assert_eq "an armed switch with a serving engine costs no python start" "${calls_before}" \
        "$(wc -l <"${SANDBOX}/hf_calls")"

    # The 2026-09-02 shape: the switch survives in the runtime from an earlier container and no
    # engine serves. The library must be asked again, or the node stays offline against a cache it
    # rejects for the whole life of the container.
    rm -f "${SANDBOX}/dp-1/v.sock" "${SANDBOX}/topped_up"
    sync_hf_offline_with_cache
    assert_eq "an armed switch with no engine is checked again" "yes" \
        "$([[ "$(wc -l <"${SANDBOX}/hf_calls")" -gt "${calls_before}" ]] && echo yes || echo no)"
}

test_a_half_installed_runtime_never_arms() {
    make_sandbox
    load_entrypoint
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    # site-packages already on disk, the interpreter not yet. The switch is written into
    # site-packages, so arming here would put it into a runtime that never approved the cache.
    mkdir -p "${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages"
    local pth_file="${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages/zz-dolphin-hf-offline.pth"
    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors" \
        "model-00003-of-00003.safetensors"

    sync_hf_offline_with_cache
    assert_eq "a runtime with no interpreter keeps the Hub" "no" \
        "$([[ -f "${pth_file}" ]] && echo yes || echo no)"

    # A second runtime that CAN be asked does not excuse the first: the switch is written into
    # every site-packages, so a runtime nothing asked would still receive it.
    local old_runtime="${DOLPHIN_HOME}/runtimes/text-old"
    mkdir -p "${old_runtime}/lib/python3.12/site-packages" "${old_runtime}/bin"
    cat >"${old_runtime}/bin/python" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "${old_runtime}/bin/python"
    sync_hf_offline_with_cache
    assert_eq "one runnable runtime does not excuse a half-installed sibling" "no" \
        "$([[ -f "${pth_file}" ]] && echo yes || echo no)"

    # A runtime the worker has just installed carries no switch yet. Reading "armed" off the old
    # one would skip the new one for good, and its first engine start would go back to the Hub.
    touch "${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages/zz-dolphin-hf-offline.pth"
    assert_eq "a runtime without the switch means not armed" "no" \
        "$(hf_offline_is_armed && echo yes || echo no)"
}

test_hf_offline_top_up_respects_the_disk_floor() {
    make_sandbox
    load_entrypoint
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages"
    local pth_file="${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages/zz-dolphin-hf-offline.pth"
    install_stub_python
    ENGINE_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock"
    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors" \
        "model-00003-of-00003.safetensors"

    # A full shared volume takes every filler container on the node down with it, so the one
    # download that was not behind the floor is behind it now.
    mock_df_free_gb 1
    sync_hf_offline_with_cache
    assert_eq "a full disk holds back the top-up" "no" \
        "$([[ -f "${SANDBOX}/topped_up" ]] && echo yes || echo no)"
    assert_eq "a held-back top-up keeps the Hub" "no" \
        "$([[ -f "${pth_file}" ]] && echo yes || echo no)"

    mock_df_free_gb 900
    sync_hf_offline_with_cache
    assert_eq "room on the disk lets the top-up run" "yes" \
        "$([[ -f "${SANDBOX}/topped_up" ]] && echo yes || echo no)"
}

test_hf_offline_needs_a_cache_the_library_can_read() {
    make_sandbox
    load_entrypoint
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages"
    local pth_file="${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages/zz-dolphin-hf-offline.pth"
    install_stub_python
    ENGINE_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock"
    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors" \
        "model-00003-of-00003.safetensors"

    # Move the whole cache out of `hub`. The library resolves <HF_HOME>/hub/models--<repo> and
    # reads nothing here, so arming offline mode would leave the engine with no weights it can open.
    mv "${SHARED_CACHE}/dolphinpod-worker/cache/hub" "${SHARED_CACHE}/dolphinpod-worker/cache/notahub"
    sync_hf_offline_with_cache
    assert_eq "a cache the library cannot read keeps the Hub" "no" \
        "$([[ -f "${pth_file}" ]] && echo yes || echo no)"
}

test_hf_offline_stays_off_when_the_top_up_fails() {
    make_sandbox
    load_entrypoint
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages"
    local pth_file="${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages/zz-dolphin-hf-offline.pth"
    install_stub_python "true"
    ENGINE_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock"
    export ONLINE_EXIT=1
    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors" \
        "model-00003-of-00003.safetensors"

    # A Hub that answers 429 (the 2026-09-02 outage) must leave the node exactly as it was:
    # online, able to try again, never armed against a cache the engine cannot open.
    sync_hf_offline_with_cache
    assert_eq "a failed top-up keeps the Hub reachable" "no" \
        "$([[ -f "${pth_file}" ]] && echo yes || echo no)"

    # The top-up blocks the supervisor for as long as it waits. A Hub that keeps answering 429
    # must not buy that wait again on the very next 30 s cycle.
    sync_hf_offline_with_cache
    assert_eq "a failed top-up is not retried on the next cycle" "1" \
        "$(grep -c '^0:' "${SANDBOX}/hf_calls")"
    unset ONLINE_EXIT
}

test_only_the_snapshot_under_the_ref_counts() {
    make_sandbox
    load_entrypoint

    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors" \
        "model-00003-of-00003.safetensors"
    assert_eq "the snapshot the ref names is complete" "yes" \
        "$(model_cache_is_complete && echo yes || echo no)"

    # Upstream published a new commit. hf_hub moved refs/main to it and began the download, so a
    # half-filled snapshot now sits beside the complete old one. vLLM resolves `main` through the
    # same ref, so the old snapshot must NOT license offline mode — the engine would look into the
    # new one, find no shards, and never start again.
    seed_hf_cache_revision cafebabe "model-00001-of-00003.safetensors"
    point_hf_ref_main_at cafebabe
    assert_eq "a partial snapshot under the ref is not complete" "no" \
        "$(model_cache_is_complete && echo yes || echo no)"

    seed_hf_cache_revision cafebabe "model-00001-of-00003.safetensors" \
        "model-00002-of-00003.safetensors" "model-00003-of-00003.safetensors"
    assert_eq "the finished new snapshot is complete" "yes" \
        "$(model_cache_is_complete && echo yes || echo no)"

    # No ref at all: the revision has never been resolved on this node, so the Hub is still needed.
    rm "$(hf_repo_cache_dir)/refs/main"
    assert_eq "a cache with no ref is not complete" "no" \
        "$(model_cache_is_complete && echo yes || echo no)"
}

test_a_stale_copy_under_another_root_does_not_count() {
    make_sandbox
    load_entrypoint

    # The worker has moved its cache directory once already, so the volume can hold the model twice:
    # a complete copy under the root an older image used, and the copy the engine reads now, still
    # downloading. Going offline on the strength of the stale one strands the real download.
    local stale="${SHARED_CACHE}/huggingface/hub/$(hf_cache_dir_name "${MODEL}")"
    mkdir -p "${stale}/refs" "${stale}/snapshots/deadbeef"
    printf '%s' deadbeef >"${stale}/refs/main"
    printf '%s' '{"weight_map":{"a":"model-00001-of-00001.safetensors"}}' \
        >"${stale}/snapshots/deadbeef/model.safetensors.index.json"
    touch "${stale}/snapshots/deadbeef/config.json" "${stale}/snapshots/deadbeef/tokenizer.json" \
        "${stale}/snapshots/deadbeef/model-00001-of-00001.safetensors"
    assert_eq "one complete copy on its own is complete" "yes" \
        "$(model_cache_is_complete && echo yes || echo no)"

    seed_hf_cache "model-00001-of-00003.safetensors"
    assert_eq "a half-downloaded second copy keeps the Hub reachable" "no" \
        "$(model_cache_is_complete && echo yes || echo no)"

    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors" \
        "model-00003-of-00003.safetensors"
    assert_eq "both copies complete is complete" "yes" \
        "$(model_cache_is_complete && echo yes || echo no)"
}

test_hf_offline_self_heals_when_no_engine_serves() {
    make_sandbox
    export METRICS_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock"
    load_entrypoint
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages"
    local pth_file="${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages/zz-dolphin-hf-offline.pth"
    install_stub_python
    touch "${SANDBOX}/topped_up"
    offline_mode_on() { [[ -f "${pth_file}" ]] && echo yes || echo no; }
    run_cycles() { local n="$1" i; for (( i = 0; i < n; i++ )); do sync_hf_offline_with_cache_and_engines; done; }

    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors" \
        "model-00003-of-00003.safetensors"

    # An engine is serving, so the cache the check read is the cache the engine can load.
    mkdir -p "${SANDBOX}/dp-abc"
    touch "${SANDBOX}/dp-abc/v.sock"
    run_cycles $(( HF_OFFLINE_MAX_CYCLES_WITHOUT_ENGINE + 3 ))
    assert_eq "a serving engine keeps offline mode on" "yes" "$(offline_mode_on)"

    # The engine goes away. Below the limit the switch must not move: engines take a while to
    # come up, and dropping the switch on the first quiet cycle would re-open the Hub for nothing.
    rm "${SANDBOX}/dp-abc/v.sock"
    run_cycles $(( HF_OFFLINE_MAX_CYCLES_WITHOUT_ENGINE - 1 ))
    assert_eq "a short quiet spell does not drop the switch" "yes" "$(offline_mode_on)"

    # Still nothing at the limit. The completeness check said "complete" and no engine ever served,
    # so the check is the suspect: take the switch off rather than sit at zero tokens forever.
    run_cycles 1
    assert_eq "no engine for the full limit takes the switch off" "no" "$(offline_mode_on)"

    # And it must LATCH. The cache still reads complete, so a plain re-sync would arm it again on
    # the very next cycle and the node would stay dark.
    run_cycles 5
    assert_eq "the switch stays off while no engine serves" "no" "$(offline_mode_on)"

    # An engine finally serves: the cache is provably usable, so offline mode is safe again.
    touch "${SANDBOX}/dp-abc/v.sock"
    run_cycles 1
    assert_eq "a serving engine arms it again" "yes" "$(offline_mode_on)"
}


# --- DAH-3393: the entrypoint fetches the weights itself; the check reads the worker's revision ----
# 2026-09-10 prod: the worker gives its engine 10 min to become ready. The model it serves since
# v2.4.2 (unsloth/Qwen3.8-27B-NVFP4) is ONE 21 GiB safetensors file, so a node must hold 37.6 MB/s
# for ten minutes with no pause; below that the worker kills the engine, huggingface_hub 1.18+ does
# not resume, and the next try starts at byte 0. Ten nodes (62 GPUs) looped like that. Two things
# in this file were blind to it: the completeness check read `refs/main`, which the worker never
# writes (it downloads a commit sha, and hf_hub writes no ref for one), and counted shards by the
# mask `model-*.safetensors`, which this one-file model does not match.

# The model the worker serves since v2.4.2, its cache laid out the way hf_hub lays it out for a
# download pinned to a commit sha: snapshots/<sha>/ and NO refs/main.
SINGLE_FILE_MODEL="unsloth/Qwen3.8-27B-NVFP4"
SERVE_REVISION="f0b7c9e722f5565102fff8481c99e4d86ae099c7"

single_file_repo_dir() {
    echo "${SHARED_CACHE}/dolphinpod-worker/cache/hub/$(hf_cache_dir_name "${SINGLE_FILE_MODEL}")"
}

seed_single_file_snapshot() {
    # Args: the weight files to create. The index names model.safetensors and model_mtp.safetensors —
    # the two files the Hub's index for this model maps tensors to (read 2026-09-11) — so leaving one
    # out is how a killed download is expressed.
    local revision="${SINGLE_FILE_REVISION:-${SERVE_REVISION}}"
    local snapshot="$(single_file_repo_dir)/snapshots/${revision}"
    rm -rf "${snapshot}"
    mkdir -p "${snapshot}"
    printf '%s' '{"weight_map":{"model.embed_tokens.weight":"model.safetensors","mtp.fc.weight":"model_mtp.safetensors"}}' \
        >"${snapshot}/model.safetensors.index.json"
    touch "${snapshot}/config.json" "${snapshot}/tokenizer.json"
    local weight
    for weight in "$@"; do
        touch "${snapshot}/${weight}"
    done
}

mock_engine_command_line() {
    # Args: <pid> [revision [model]]. What `pgrep -af` prints for the engine the worker launched from
    # its runtime: `serve <model> --revision <sha> --uds <socket>`. The stub prints the file named by
    # DOLPHIN_TEST_PGREP_FILE; without the variable it hands over to the pgrep it shadowed, so the
    # sandboxes of later tests (their bins stack on PATH) see the real process table.
    local pid="$1" revision="${2:-${SERVE_REVISION}}" model="${3:-${SINGLE_FILE_MODEL}}" real_pgrep
    export DOLPHIN_TEST_PGREP_FILE="${SANDBOX}/pgrep.txt"
    echo "${pid} ${DOLPHIN_HOME}/runtimes/text-v/bin/python3.12 ${DOLPHIN_HOME}/runtimes/text-v/bin/aphrodite serve ${model} --revision ${revision} --uds ${SANDBOX}/dp-abc/v.sock --tensor-parallel-size 1" \
        >"${DOLPHIN_TEST_PGREP_FILE}"
    # Written once per sandbox: a second write would resolve `pgrep` to this very stub.
    [[ -x "${SANDBOX}/bin/pgrep" ]] && return 0
    real_pgrep="$(command -v pgrep)"
    cat >"${SANDBOX}/bin/pgrep" <<EOF
#!/usr/bin/env bash
[[ -n "\${DOLPHIN_TEST_PGREP_FILE:-}" ]] || exec "${real_pgrep}" "\$@"
[[ -s "\${DOLPHIN_TEST_PGREP_FILE}" ]] || exit 1
cat "\${DOLPHIN_TEST_PGREP_FILE}"
EOF
    chmod +x "${SANDBOX}/bin/pgrep"
}

no_engine_process() {
    # The moment between the worker killing its engine and starting the next one.
    : >"${DOLPHIN_TEST_PGREP_FILE}"
}

install_slow_fetcher_python() {
    # Args: seconds one fetch takes. Stands in for the runtime's interpreter running
    # snapshot_download: records the call, takes its time like a throttled link, then lands every
    # file the index names under the snapshot it was pinned to. FETCH_EXIT=<n> makes it fail instead,
    # the way a Hub that keeps answering 429 does.
    local runtime_bin="${DOLPHIN_HOME}/runtimes/text-v/bin"
    mkdir -p "${runtime_bin}"
    cat >"${runtime_bin}/python" <<EOF
#!/usr/bin/env bash
echo "model=\${DOLPHIN_HF_MODEL} revision=\${DOLPHIN_HF_REVISION} offline=\${HF_HUB_OFFLINE} hf_home=\${HF_HOME}" >>"${SANDBOX}/fetch_calls"
sleep ${1}
[[ "\${FETCH_EXIT:-0}" == "0" ]] || exit "\${FETCH_EXIT}"
[[ -z "\${FETCH_LANDS_NOTHING:-}" ]] || exit 0
snapshot="\${HF_HOME}/hub/$(hf_cache_dir_name "${SINGLE_FILE_MODEL}")/snapshots/\${DOLPHIN_HF_REVISION}"
touch "\${snapshot}/model.safetensors" "\${snapshot}/model_mtp.safetensors"
echo "done" >>"${SANDBOX}/fetch_done"
EOF
    chmod +x "${runtime_bin}/python"
}

fetch_call_count() {
    if [[ -f "${SANDBOX}/fetch_calls" ]]; then wc -l <"${SANDBOX}/fetch_calls" | tr -d ' '; else echo 0; fi
}

wait_for_fetch_calls() {
    # The fetch is a background process, so its record lands a moment after ensure_weights_fetch returns.
    local n="$1" waited=0
    while (( $(fetch_call_count) < n && waited < 10 )); do
        sleep 0.5
        waited=$((waited + 1))
    done
}

wait_until_gone() {
    local pid="$1" waited=0
    while kill -0 "${pid}" 2>/dev/null && (( waited < 20 )); do
        sleep 1
        waited=$((waited + 1))
    done
}

test_completeness_check_reads_the_serve_revision_and_the_index() {
    make_sandbox
    load_entrypoint
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mock_engine_command_line 1111

    # The looping nodes' cache, once the download has landed: one file, no refs/main. The shipped
    # check said "not complete" here forever, so offline mode never armed and the download floor
    # read a complete cache as a download still to come.
    seed_single_file_snapshot model.safetensors model_mtp.safetensors
    assert_eq "a single-file snapshot under the serve revision is complete without refs/main" "yes" \
        "$(model_cache_is_complete && echo yes || echo no)"

    # The killed-download shape: the index names a file that is not on disk.
    rm "$(single_file_repo_dir)/snapshots/${SERVE_REVISION}/model_mtp.safetensors"
    assert_eq "a snapshot missing a file the index names is not complete" "no" \
        "$(model_cache_is_complete && echo yes || echo no)"

    # A repo with no index at all ships its weights as model.safetensors alone.
    seed_single_file_snapshot model.safetensors
    rm "$(single_file_repo_dir)/snapshots/${SERVE_REVISION}/model.safetensors.index.json"
    assert_eq "with no index, model.safetensors alone is complete" "yes" \
        "$(model_cache_is_complete && echo yes || echo no)"
    rm "$(single_file_repo_dir)/snapshots/${SERVE_REVISION}/model.safetensors"
    assert_eq "with no index and no model.safetensors it is not" "no" \
        "$(model_cache_is_complete && echo yes || echo no)"

    # refs/main names a complete OLDER snapshot while the engine was started with a newer sha whose
    # download has not landed. A check that fell back to the ref would arm offline mode against a
    # snapshot the engine never opens — the DAH-3341 shape again.
    seed_single_file_snapshot model.safetensors model_mtp.safetensors
    SINGLE_FILE_REVISION=57926bac57926bac57926bac57926bac57926bac seed_single_file_snapshot model.safetensors model_mtp.safetensors
    mkdir -p "$(single_file_repo_dir)/refs"
    printf '%s' 57926bac57926bac57926bac57926bac57926bac >"$(single_file_repo_dir)/refs/main"
    rm "$(single_file_repo_dir)/snapshots/${SERVE_REVISION}/model.safetensors"
    assert_eq "the serve revision decides, not refs/main" "no" \
        "$(model_cache_is_complete && echo yes || echo no)"

    # The worker has killed its engine and not yet started the next (no serve process). DOLPHIN_MODEL
    # still names the model the worker served BEFORE its update, and that model's cache is complete
    # under refs/main. The lately running engine's model is what the next engine opens, so its
    # half-downloaded snapshot is what decides — a yes here would arm offline mode against a cache no
    # engine reads (the DAH-3341 shape) and flap the switch on every kill/restart gap.
    # The cycle remembers the running engines in the entrypoint's own shell; the `$(...)` probes above
    # remembered them in a subshell, so do it here the way sync_hf_offline_with_cache does.
    remember_launched_engines
    no_engine_process
    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors" \
        "model-00003-of-00003.safetensors"
    assert_eq "in the kill/restart gap the lately running engine's model decides, not DOLPHIN_MODEL" "no" \
        "$(model_cache_is_complete && echo yes || echo no)"
    assert_eq "the model list in the gap is the lately running engine's" "${SINGLE_FILE_MODEL}" \
        "$(hf_offline_models)"

    # No engine has run yet and there is no ref: nothing says which snapshot the engine will open.
    LAUNCHED_MODELS=()
    LAUNCHED_REVISIONS=()
    rm "$(single_file_repo_dir)/refs/main"
    MODEL="${SINGLE_FILE_MODEL}"
    assert_eq "no revision from anywhere is not complete" "no" \
        "$(model_cache_is_complete && echo yes || echo no)"
    # pgrep exits 1 with no engine, and under the entrypoint's `set -euo pipefail` that status used to
    # end the `$(...)` in hf_offline_models before its DOLPHIN_MODEL fallback — every cycle with no
    # engine process evaluated no model at all.
    assert_eq "with no engine process the model list falls back to DOLPHIN_MODEL under set -e" \
        "${SINGLE_FILE_MODEL}" "$(set -euo pipefail; hf_offline_models)"

    # A restarted container with the full 21 GiB on disk and a full-ish disk: before its first engine
    # starts nothing names the revision, and the disk floor used to park it for ever (refs/main absent).
    # This check is biased towards yes — any complete snapshot means no download is coming.
    rm -rf "$(single_file_repo_dir)/snapshots/57926bac57926bac57926bac57926bac57926bac"
    seed_single_file_snapshot model.safetensors model_mtp.safetensors
    mock_df_free_gb 20
    assert_eq "a complete pinned cache is not parked by the disk floor before the first engine start" "no" \
        "$(download_floor_blocks_spawn && echo yes || echo no)"
    rm "$(single_file_repo_dir)/snapshots/${SERVE_REVISION}/model.safetensors"
    assert_eq "an incomplete one still is" "yes" \
        "$(download_floor_blocks_spawn && echo yes || echo no)"
    unset DOLPHIN_TEST_PGREP_FILE
}

test_missing_weights_are_fetched_in_the_background_while_no_engine_serves() {
    # The acceptance case: a node too slow for the worker's 10 min. The engine holds a socket that
    # answers nothing, the worker kills and restarts it, and none of that may touch the fetch.
    make_sandbox
    export METRICS_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock"
    export DOLPHIN_WEIGHTS_FETCH_RETRY_SECONDS=2
    load_entrypoint
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    WORKER_LOG_DIR="${SANDBOX}/logs"
    install_slow_fetcher_python 3
    # A second, older runtime the worker left on disk. Its interpreter must not be the one that
    # fetches: the engine runs from text-v, and the fetch has to share its huggingface_hub.
    mkdir -p "${DOLPHIN_HOME}/runtimes/text-old/bin"
    printf '#!/usr/bin/env bash\necho "wrong-runtime" >>"%s"\nexit 1\n' "${SANDBOX}/fetch_calls" \
        >"${DOLPHIN_HOME}/runtimes/text-old/bin/python"
    chmod +x "${DOLPHIN_HOME}/runtimes/text-old/bin/python"
    mkdir -p "${SANDBOX}/dp-abc"
    touch "${SANDBOX}/dp-abc/v.sock"
    engine_answers_health no
    mock_engine_command_line 1111
    has_fetch_slot() { weights_fetch_pid_for "${SINGLE_FILE_MODEL}" "${SERVE_REVISION}" >/dev/null && echo slot || echo none; }

    # Only a copy of the model under the root an older image used exists (the worker has moved its
    # cache directory before). The engine has begun nothing there — no snapshots/<sha>/ — so no fetch
    # may land 21 GiB in a root the engine never reads.
    mkdir -p "${SHARED_CACHE}/huggingface/hub/$(hf_cache_dir_name "${SINGLE_FILE_MODEL}")/refs"
    ensure_weights_fetch 0
    assert_eq "a copy the engine has not begun gets no fetch" "none" "$(has_fetch_slot)"
    rm -rf "${SHARED_CACHE}/huggingface"
    seed_single_file_snapshot

    # The cycle measured an engine answering /health: the weights it needs are on disk, whatever this
    # file's check says.
    ensure_weights_fetch 1
    assert_eq "a serving engine means no fetch" "none" "$(has_fetch_slot)"

    # DAH-2805: a download that fills the shared volume takes every filler on the node down.
    mock_df_free_gb 20
    ensure_weights_fetch 0 2>"${SANDBOX}/ensure.err"
    ensure_weights_fetch 0 2>>"${SANDBOX}/ensure.err"
    assert_eq "a full disk starts no fetch, and says so once per interval, not once per cycle" "1" \
        "$(grep -c "only 20 GB free; not fetching ${SINGLE_FILE_MODEL}@" "${SANDBOX}/ensure.err")"
    assert_eq "no fetch ran" "0" "$(fetch_call_count)"
    mock_df_free_gb 900

    # The worker's deadline passes and it kills the engine: a cycle with no serve process. The
    # model, the revision and the runtime were remembered off the command line while it ran.
    no_engine_process
    sleep 2
    assert_eq "with no engine process the remembered model is still the one to fetch, under set -e" \
        "${SINGLE_FILE_MODEL}" "$(set -euo pipefail; hf_offline_models)"
    ensure_weights_fetch 0
    wait_for_fetch_calls 1
    assert_eq "fetched in the gap, by the python of the runtime on the serve line, pinned to the serve revision, into the engine's cache root" \
        "model=${SINGLE_FILE_MODEL} revision=${SERVE_REVISION} offline=0 hf_home=${SHARED_CACHE}/dolphinpod-worker/cache" \
        "$(cat "${SANDBOX}/fetch_calls" 2>/dev/null)"
    local fetch_pid
    fetch_pid="$(weights_fetch_pid_for "${SINGLE_FILE_MODEL}" "${SERVE_REVISION}")"
    assert_eq "the fetch runs in the background" "yes" \
        "$([[ -n "${fetch_pid}" ]] && kill -0 "${fetch_pid}" 2>/dev/null && echo yes || echo no)"

    # The worker starts a new engine under a new pid. Same revision, so the fetch in flight is the fetch.
    mock_engine_command_line 2222
    ensure_weights_fetch 0
    ensure_weights_fetch 0
    assert_eq "one fetch per revision across engine restarts" "1" "$(fetch_call_count)"
    assert_eq "the fetch outlives the engine the worker killed" "yes" \
        "$(kill -0 "${fetch_pid}" 2>/dev/null && echo yes || echo no)"

    # The slow link delivers. The next engine the worker starts finds the file and serves.
    wait_until_gone "${fetch_pid}"
    ensure_weights_fetch 0 2>"${SANDBOX}/ensure.err"
    assert_eq "the fetched snapshot is complete" "yes" \
        "$(model_cache_is_complete && echo yes || echo no)"
    assert_eq "the fetch is reported finished, not failed" "1" \
        "$(grep -c 'background fetch of .* finished' "${SANDBOX}/ensure.err")"
    assert_eq "a complete snapshot starts no second fetch" "1" "$(fetch_call_count)"
    assert_eq "no fetch process is left behind" "" \
        "$(weights_fetch_pid_for "${SINGLE_FILE_MODEL}" "${SERVE_REVISION}")"

    # Driving the function here would still pass if nothing called it. The supervisor's 30 s cycle
    # is proven by test_a_throttled_node_reaches_serving_through_the_background_fetch on procps
    # hosts; on a Mac this line is the only guard of that wiring.
    assert_eq "the supervisor drives the fetch every cycle" "1" \
        "$(sed -n '/^supervise_running_workers_until_new_binary_published/,/^}/p' "${ENTRYPOINT}" \
            | grep -c 'ensure_weights_fetch')"
    # No deadline: a deadline on the fetch is the worker's 10 min under another name.
    assert_eq "the fetch runs under no timeout" "0" \
        "$(sed -n '/^start_weights_fetch/,/^}/p' "${ENTRYPOINT}" | grep -v '^ *#' | grep -c 'timeout')"
    unset DOLPHIN_TEST_PGREP_FILE METRICS_SOCKET_GLOB DOLPHIN_WEIGHTS_FETCH_RETRY_SECONDS
}

test_a_model_the_worker_no_longer_launches_gets_no_fetch() {
    # 10 Sep shape: the worker's update moves the model. The old model's half-downloaded snapshot
    # must not earn a fetch of its own — tens of GB on the very link this exists for — so the
    # remembered set follows the last engine seen, it does not accumulate.
    make_sandbox
    export METRICS_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock"
    export DOLPHIN_WEIGHTS_FETCH_RETRY_SECONDS=2
    load_entrypoint
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    WORKER_LOG_DIR="${SANDBOX}/logs"
    install_slow_fetcher_python 0
    export FETCH_EXIT=1
    seed_single_file_snapshot
    mkdir -p "${SANDBOX}/dp-abc"
    touch "${SANDBOX}/dp-abc/v.sock"
    engine_answers_health no
    mock_engine_command_line 1111

    ensure_weights_fetch 0
    wait_for_fetch_calls 1
    wait_until_gone "$(weights_fetch_pid_for "${SINGLE_FILE_MODEL}" "${SERVE_REVISION}")"
    # This cycle reaps the failed fetch and holds its slot; the sleep lets that hold expire, so
    # nothing but the remembered set can keep the old model from being fetched again below.
    ensure_weights_fetch 0
    sleep 3

    # The worker now serves another model; its snapshot is as fresh as hf_hub leaves it after the
    # first seconds (config, tokenizer, index, no weights).
    local other="unsloth/Qwen4-Next-NVFP4" other_revision="beefdeadbeefdeadbeefdeadbeefdeadbeefdead"
    local other_snapshot="${SHARED_CACHE}/dolphinpod-worker/cache/hub/$(hf_cache_dir_name "${other}")/snapshots/${other_revision}"
    mkdir -p "${other_snapshot}"
    printf '%s' '{"weight_map":{"a":"model.safetensors"}}' >"${other_snapshot}/model.safetensors.index.json"
    touch "${other_snapshot}/config.json" "${other_snapshot}/tokenizer.json"
    mock_engine_command_line 2222 "${other_revision}" "${other}"
    ensure_weights_fetch 0
    wait_for_fetch_calls 2
    assert_eq "the new model is fetched" \
        "model=${other} revision=${other_revision} offline=0 hf_home=${SHARED_CACHE}/dolphinpod-worker/cache" \
        "$(tail -1 "${SANDBOX}/fetch_calls")"

    # The worker kills that engine too. In the gap the remembered set is what decides, and it must
    # hold the last engine alone: with the old model still on it, its incomplete snapshot (whose
    # retry slot expired above) would be fetched again here.
    no_engine_process
    assert_eq "in the gap the model list is the last engine seen, alone" "${other}" "$(hf_offline_models)"
    ensure_weights_fetch 0
    sleep 1
    assert_eq "two fetches in all, one per model the worker launched; the old one is not fetched again" "2" \
        "$(fetch_call_count)"
    unset FETCH_EXIT DOLPHIN_TEST_PGREP_FILE METRICS_SOCKET_GLOB DOLPHIN_WEIGHTS_FETCH_RETRY_SECONDS
}

test_the_seed_wait_drives_the_fetch_and_docker_stop_ends_it() {
    # A cold split node: instance 0 is spawned, then the entrypoint sits in wait_for_cache_seed for
    # up to 90 min before the supervisor (and its fetch) runs. Instance 0 is exactly the engine that
    # cannot land the file on a slow node, so the wait itself has to drive the fetch.
    make_sandbox
    export METRICS_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock"
    load_entrypoint
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    WORKER_LOG_DIR="${SANDBOX}/logs"
    install_slow_fetcher_python 120
    seed_single_file_snapshot
    mkdir -p "${SANDBOX}/dp-abc"
    touch "${SANDBOX}/dp-abc/v.sock"
    engine_answers_health no
    mock_engine_command_line 1111

    SEED_WAIT_SECONDS=30
    local started elapsed
    started=$(date +%s)
    wait_for_cache_seed 2>/dev/null
    elapsed=$(( $(date +%s) - started ))
    assert_eq "the seed wait ran out (no engine ever answered)" "yes" \
        "$([[ ${elapsed} -ge 30 ]] && echo yes || echo no)"
    wait_for_fetch_calls 1
    assert_eq "the seed wait started the fetch once" "1" "$(fetch_call_count)"
    local fetch_pid
    fetch_pid="$(weights_fetch_pid_for "${SINGLE_FILE_MODEL}" "${SERVE_REVISION}")"
    assert_eq "the fetch is still running when the wait ends" "yes" \
        "$(kill -0 "${fetch_pid}" 2>/dev/null && echo yes || echo no)"

    # `docker stop` (the TERM trap) must take the fetch with it: the container is going away. In a
    # subshell because on_term exits; no worker, watchdog or sidecar is running here.
    ( WORKER_PIDS=(); WATCHDOG_PIDS=(); SIDECAR_PID=""; on_term )
    sleep 1
    assert_eq "docker stop ends the fetch" "no" \
        "$(kill -0 "${fetch_pid}" 2>/dev/null && echo yes || echo no)"
    unset DOLPHIN_TEST_PGREP_FILE METRICS_SOCKET_GLOB
}

test_a_failed_fetch_waits_before_it_is_retried() {
    # A Hub that answers 429 must not be asked again on the next 30 s cycle: the hammering itself
    # extends the ban (the DAH-2763 respawn backoff exists for the same reason).
    make_sandbox
    export METRICS_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock"
    export DOLPHIN_WEIGHTS_FETCH_RETRY_SECONDS=2
    load_entrypoint
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    WORKER_LOG_DIR="${SANDBOX}/logs"
    install_slow_fetcher_python 0
    export FETCH_EXIT=1
    seed_single_file_snapshot
    mkdir -p "${SANDBOX}/dp-abc"
    touch "${SANDBOX}/dp-abc/v.sock"
    engine_answers_health no
    mock_engine_command_line 1111

    ensure_weights_fetch 0
    wait_for_fetch_calls 1
    wait_until_gone "$(weights_fetch_pid_for "${SINGLE_FILE_MODEL}" "${SERVE_REVISION}")"
    ensure_weights_fetch 0 2>"${SANDBOX}/ensure.err"
    ensure_weights_fetch 0
    sleep 1
    assert_eq "a failed fetch is not retried on the next cycle" "1" "$(fetch_call_count)"
    assert_eq "the failure and the wait are in the container log" "1" \
        "$(grep -c 'background fetch of .* failed; next attempt in 2s' "${SANDBOX}/ensure.err")"

    # The retry interval passes.
    sleep 3
    ensure_weights_fetch 0
    wait_for_fetch_calls 2
    assert_eq "it is retried once the interval has passed" "2" "$(fetch_call_count)"

    # A fetch that exits 0 but leaves the snapshot incomplete by this file's measure (the library's
    # notion of complete is not ours — a repo without tokenizer.json) must wait the same interval:
    # forgotten at once, it would be one Hub API call per 30 s cycle.
    wait_until_gone "$(weights_fetch_pid_for "${SINGLE_FILE_MODEL}" "${SERVE_REVISION}")"
    ensure_weights_fetch 0
    sleep 3
    unset FETCH_EXIT
    export FETCH_LANDS_NOTHING=1
    ensure_weights_fetch 0
    wait_for_fetch_calls 3
    wait_until_gone "$(weights_fetch_pid_for "${SINGLE_FILE_MODEL}" "${SERVE_REVISION}")"
    ensure_weights_fetch 0 2>"${SANDBOX}/ensure.err"
    ensure_weights_fetch 0
    sleep 1
    assert_eq "a finished fetch that left the snapshot incomplete is not restarted on the next cycle" "3" \
        "$(fetch_call_count)"
    assert_eq "and it is reported finished" "1" "$(grep -c 'background fetch of .* finished' "${SANDBOX}/ensure.err")"
    unset FETCH_LANDS_NOTHING DOLPHIN_TEST_PGREP_FILE METRICS_SOCKET_GLOB DOLPHIN_WEIGHTS_FETCH_RETRY_SECONDS
}

test_a_throttled_node_reaches_serving_through_the_background_fetch() {
    # The acceptance case through the real entrypoint process: a worker whose engine cannot land
    # the file inside its deadline kills and restarts it for ever; the node serves only because the
    # entrypoint's own fetch, which no deadline touches, lands it. Needs procps (`pgrep -a` prints
    # the command line the entrypoint reads the revision off); macOS pgrep spells -a differently.
    make_sandbox
    if ! pgrep -af "test_entrypoint" 2>/dev/null | grep -qE '^[0-9]+ .*test_entrypoint'; then
        echo "SKIP a throttled node reaches serving: pgrep here does not print command lines (not procps)"
        return 0
    fi
    export DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    export METRICS_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock"
    export DOLPHIN_WORKER_SPAWN_STATE="${SANDBOX}/spawns.json"
    mkdir -p "${DOLPHIN_HOME}/runtimes/text-v/bin"
    mock_nvidia_smi
    load_entrypoint
    seed_single_file_snapshot
    # The throttled link: 40 s for a file the worker below gives its engine 15 s to land — the
    # 21 GiB at 20 MB/s against the worker's ten minutes, on a schedule a test can wait out.
    install_slow_fetcher_python 40
    local snapshot
    snapshot="$(single_file_repo_dir)/snapshots/${SERVE_REVISION}"

    # The engine: opens its socket at once (Aphrodite's shape, DAH-3341) and answers /health only
    # once the weights are on disk. It downloads nothing itself: in prod its own download is the
    # one that dies with it, so here only the entrypoint's fetch can land the file.
    cat >"${DOLPHIN_HOME}/runtimes/text-v/bin/aphrodite" <<EOF
#!/usr/bin/env bash
mkdir -p "${SANDBOX}/dp-1" && touch "${SANDBOX}/dp-1/v.sock"
while true; do
    [[ -f "${snapshot}/model.safetensors" && -f "${snapshot}/model_mtp.safetensors" ]] && touch "${SANDBOX}/engine_healthy"
    sleep 1
done
EOF
    chmod +x "${DOLPHIN_HOME}/runtimes/text-v/bin/aphrodite"
    # The worker: starts the engine from its runtime with the model, the revision and the socket on
    # the command line, kills it when it is not ready in 15 s, and starts over.
    cat >"${DOLPHIN_HOME}/dolphinpod-worker" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "start" ]] || exit 0
engine=""
trap 'kill "\${engine}" 2>/dev/null; exit 0' TERM
while true; do
    "${DOLPHIN_HOME}/runtimes/text-v/bin/aphrodite" serve ${SINGLE_FILE_MODEL} --revision ${SERVE_REVISION} --uds ${SANDBOX}/dp-1/v.sock &
    engine=\$!
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        sleep 1
        [[ -f "${SANDBOX}/engine_healthy" ]] && wait "\${engine}"
    done
    echo "engine \${engine} killed: not ready in 15s" >>"${SANDBOX}/worker.log"
    kill "\${engine}" 2>/dev/null
    wait "\${engine}" 2>/dev/null
done
EOF
    chmod +x "${DOLPHIN_HOME}/dolphinpod-worker"
    engine_answers_health no

    DOLPHIN_API_KEY="dp-test" DOLPHIN_WORKER_URL="file:///bin/true" DOLPHIN_WORKER_LOG_DIR="${SANDBOX}/logs" \
        bash "${ENTRYPOINT}" >"${SANDBOX}/entry.log" 2>&1 &
    local entry_pid=$! waited=0
    while ! engine_is_serving && (( waited < 150 )); do
        sleep 2
        waited=$((waited + 2))
    done
    local serving=no
    engine_is_serving && serving=yes
    kill -TERM "${entry_pid}" 2>/dev/null
    wait "${entry_pid}" 2>/dev/null

    assert_eq "the node reaches serving (after ${waited}s)" "yes" "${serving}"
    assert_eq "the worker killed engines meanwhile, and none of that touched the fetch" "yes" \
        "$([[ "$(grep -c killed "${SANDBOX}/worker.log" 2>/dev/null)" -ge 2 ]] && echo yes || echo no)"
    assert_eq "exactly one fetch, pinned to the revision on the serve command line" \
        "model=${SINGLE_FILE_MODEL} revision=${SERVE_REVISION} offline=0 hf_home=${SHARED_CACHE}/dolphinpod-worker/cache" \
        "$(cat "${SANDBOX}/fetch_calls" 2>/dev/null)"
    assert_eq "the fetch ran to its end; nothing killed it" "done" "$(cat "${SANDBOX}/fetch_done" 2>/dev/null)"
    assert_eq "the entrypoint never reported the fetch failed" "0" "$(grep -c 'background fetch of .* failed' "${SANDBOX}/entry.log")"
    unset METRICS_SOCKET_GLOB DOLPHIN_WORKER_SPAWN_STATE
}

test_hf_offline_arms_on_a_cache_the_worker_pinned_by_revision() {
    # With no refs/main, hf_cache_is_engine_ready skipped every copy and the switch could never arm
    # on these nodes: every engine start went back through the Hub API — the DAH-2743 per-IP rate
    # limit, on the very sites where the nodes share one address.
    make_sandbox
    load_entrypoint
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages"
    local pth_file="${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages/zz-dolphin-hf-offline.pth"
    install_stub_python
    touch "${SANDBOX}/topped_up"
    ENGINE_SOCKET_GLOB="${SANDBOX}/dp-*/v.sock"
    seed_single_file_snapshot model.safetensors model_mtp.safetensors
    mock_engine_command_line 1111

    sync_hf_offline_with_cache
    assert_eq "a complete single-file cache with no refs/main arms offline mode" "yes" \
        "$([[ -f "${pth_file}" ]] && echo yes || echo no)"
    # The library resolves the revision like the engine does — from the command line, not from a
    # ref it would not find.
    assert_eq "the library is asked about the serve revision" "yes" \
        "$(grep -q "^offline-revision=${SERVE_REVISION}\$" "${SANDBOX}/hf_calls" && echo yes || echo no)"
    unset DOLPHIN_TEST_PGREP_FILE
}

# ---------------------------------------------------------------- DAH-2824 download retry
test_binary_download_asks_curl_to_retry_within_time_bounds() {
    make_sandbox
    export DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}"
    load_entrypoint

    # Regression guard for the 429 rollout burst of 2026-09-01: the stub records the flags rather
    # than the transfer, because what failed then was curl never being asked to retry at all.
    cat >"${SANDBOX}/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${SANDBOX}/curl-args.log"
echo binary >"\${@: -1}"
EOF
    chmod +x "${SANDBOX}/bin/curl"

    download_worker_binary
    assert_eq "downloaded binary lands in place" "yes" \
        "$([[ -x "${DOLPHIN_HOME}/dolphinpod-worker" ]] && echo yes || echo no)"
    local flag
    for flag in --retry --retry-max-time --max-time; do
        assert_eq "download curl carries ${flag}" "yes" \
            "$(grep -qx -- "${flag}" "${SANDBOX}/curl-args.log" && echo yes || echo no)"
    done
}

# ---------------------------------------------------------------- DAH-2805 download temporaries
test_download_floor_blocks_a_spawn_only_when_the_cache_is_incomplete() {
    make_sandbox
    load_entrypoint

    mock_df_free_gb 20
    assert_eq "a full disk holds back a download" "yes" \
        "$(download_floor_blocks_spawn && echo yes || echo no)"

    mock_df_free_gb 900
    assert_eq "room to download does not hold anything back" "no" \
        "$(download_floor_blocks_spawn && echo yes || echo no)"

    # A node that already holds the weights starts no download at all, so the floor must not
    # keep it off the network's work over a disk it is not going to fill.
    mock_df_free_gb 20
    seed_hf_cache "model-00001-of-00003.safetensors" "model-00002-of-00003.safetensors" \
        "model-00003-of-00003.safetensors"
    assert_eq "a complete cache is never held back" "no" \
        "$(download_floor_blocks_spawn && echo yes || echo no)"

    # A stale half-copy under an old cache root must not park a node whose real cache is complete:
    # the offline switch demands every copy be complete, this decision must not.
    mkdir -p "${SHARED_CACHE}/dolphinpod-worker/cache/hub/$(hf_cache_dir_name "${MODEL}")/snapshots/dead"
    assert_eq "a stale half-copy elsewhere does not park the node" "no" \
        "$(download_floor_blocks_spawn && echo yes || echo no)"

    # A reading we cannot take must not park the filler: earning nothing is worse than one more
    # download attempt.
    rm -rf "${SHARED_CACHE}/dolphinpod-worker"
    mock_df_fails
    assert_eq "an unmeasurable disk does not hold anything back" "no" \
        "$(download_floor_blocks_spawn && echo yes || echo no)"
}

test_plan
test_render
test_prepare_instance_home
test_wait_for_cache_seed
test_per_engine_watchdog_in_split_mode
test_single_engine_watchdog
test_split_sidecar_and_watchdog_wiring
test_spawn_smoke
test_terminate_workers_is_bounded
test_model_cache_is_complete
test_only_the_snapshot_under_the_ref_counts
test_a_stale_copy_under_another_root_does_not_count
test_the_cache_check_follows_the_model_the_worker_launches
test_a_socket_that_answers_nothing_is_not_serving
test_enable_hf_offline
test_hf_offline_wiring
test_hf_offline_is_re_evaluated_later
test_hf_offline_self_heals_when_no_engine_serves
test_hf_offline_waits_for_the_library
test_hf_offline_needs_a_cache_the_library_can_read
test_hf_offline_top_up_respects_the_disk_floor
test_a_half_installed_runtime_never_arms
test_hf_offline_stays_off_when_the_top_up_fails
test_completeness_check_reads_the_serve_revision_and_the_index
test_missing_weights_are_fetched_in_the_background_while_no_engine_serves
test_a_failed_fetch_waits_before_it_is_retried
test_a_model_the_worker_no_longer_launches_gets_no_fetch
test_the_seed_wait_drives_the_fetch_and_docker_stop_ends_it
test_a_throttled_node_reaches_serving_through_the_background_fetch
test_hf_offline_arms_on_a_cache_the_worker_pinned_by_revision
test_worker_log_and_spawn_counters
test_backoff_counts_a_long_dead_download_as_failed
test_respawns_are_staggered
test_worker_logs_are_per_container_and_pruned
test_download_floor_blocks_a_spawn_only_when_the_cache_is_incomplete
test_binary_download_asks_curl_to_retry_within_time_bounds

if [[ ${FAILURES} -gt 0 ]]; then
    echo "${FAILURES} test(s) failed"
    exit 1
fi
echo "all tests passed"
