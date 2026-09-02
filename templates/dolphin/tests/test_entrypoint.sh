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
    cat >"${SANDBOX}/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${SANDBOX}/bin/curl"
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
    cat >"${SANDBOX}/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${SANDBOX}/bin/curl"
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
    ${1:-touch "${SANDBOX}/topped_up"}
    exit \${ONLINE_EXIT:-0}
fi
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

    # Armed and complete: the decision is made, so no interpreter runs on later cycles.
    local calls_before
    calls_before="$(wc -l <"${SANDBOX}/hf_calls")"
    sync_hf_offline_with_cache
    assert_eq "an armed switch costs no python start" "${calls_before}" "$(wc -l <"${SANDBOX}/hf_calls")"
}

test_hf_offline_stays_off_when_the_top_up_fails() {
    make_sandbox
    load_entrypoint
    DOLPHIN_HOME="${SANDBOX}/dolphinpod"
    mkdir -p "${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages"
    local pth_file="${DOLPHIN_HOME}/runtimes/text-v/lib/python3.12/site-packages/zz-dolphin-hf-offline.pth"
    install_stub_python "true"
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
test_enable_hf_offline
test_hf_offline_wiring
test_hf_offline_is_re_evaluated_later
test_hf_offline_self_heals_when_no_engine_serves
test_hf_offline_waits_for_the_library
test_hf_offline_stays_off_when_the_top_up_fails
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
