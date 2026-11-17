#!/usr/bin/env bash
# GPU count tests (DAH-6567). No framework, run it:
#
#     bash tests/test_gpu_count.sh
#
# The entrypoint runs for real against a stub `nvidia-smi` that prints canned output, and a stub
# `peakminer` that exits at once, so the count the sidecar would get is read from the startup log.
set -uo pipefail

ENTRYPOINT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/entrypoint.sh"
failures=0

# $2 = what `nvidia-smi -L` prints, $3 = what `nvidia-smi --query-gpu=uuid ...` prints,
# $4 = the expected GPU count ("none" = the container must refuse to start).
check_count() {
    local label="$1" list="$2" query="$3" expected="$4" stub_dir got status=""
    stub_dir="$(mktemp -d)"
    printf '%s\n' "${list}" > "${stub_dir}/list.txt"
    printf '%s\n' "${query}" > "${stub_dir}/query.txt"
    cat > "${stub_dir}/nvidia-smi" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "-L" ]]; then cat "${stub_dir}/list.txt"; else cat "${stub_dir}/query.txt"; fi
STUB
    printf '#!/usr/bin/env bash\nexit 0\n' > "${stub_dir}/peakminer"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${stub_dir}/sshd"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${stub_dir}/ssh-keygen"
    chmod +x "${stub_dir}/nvidia-smi" "${stub_dir}/peakminer" "${stub_dir}/sshd" "${stub_dir}/ssh-keygen"
    PATH="${stub_dir}:${PATH}" PEARL_POOL_HOST=pool.test PEARL_POOL_PORT=1 PEARL_POOL_WALLET=prl1test \
        PEARL_POOL_WORKER=w PEARL_LOG_DIR="${stub_dir}/logs" LIUM_RUN_DIR="${stub_dir}/run" \
        PEARL_MINER_RESTART_DELAY_SECONDS=0 PEARL_MINER_MAX_RESTARTS=0 PEARL_MINER_AUTO_UPDATE=0 \
        PEARL_MINER_DIR="${stub_dir}/install" bash "${ENTRYPOINT}" > "${stub_dir}/out" 2>&1
    got="$(sed -n 's/^\[pearl\] GPU count: //p' "${stub_dir}/out")"
    if [[ "${expected}" == "none" ]]; then
        grep -q "no NVIDIA GPUs visible" "${stub_dir}/out" && status=pass
    else
        [[ "${got}" == "${expected}" ]] && grep -q "GPU count: ${expected}" "${stub_dir}/logs/peakminer.log" \
            && status=pass
    fi
    if [[ "${status}" == "pass" ]]; then
        echo "  ok: ${label} (count '${got}')"
    else
        echo "  FAIL: ${label}: expected ${expected}, got '${got}'"
        sed 's/^/    | /' "${stub_dir}/out"
        failures=$((failures + 1))
    fi
    rm -rf "${stub_dir}"
}

eight_list=""
eight_query=""
for i in 0 1 2 3 4 5 6 7; do
    eight_list+="GPU ${i}: NVIDIA GeForce RTX 5070 Ti (UUID: GPU-0000000${i}-aaaa-bbbb-cccc-dddddddddddd)"$'\n'
    eight_query+="GPU-0000000${i}-aaaa-bbbb-cccc-dddddddddddd"$'\n'
done
nvml_error="Failed to initialize NVML: Unknown Error"

check_count "8 GPUs" "${eight_list%$'\n'}" "${eight_query%$'\n'}" 8
check_count "1 GPU" "GPU 0: NVIDIA L4 (UUID: GPU-11111111-aaaa-bbbb-cccc-dddddddddddd)" \
    "GPU-11111111-aaaa-bbbb-cccc-dddddddddddd" 1
check_count "an NVML error is no GPU, not one" "${nvml_error}" "${nvml_error}" none
check_count "the UUID query fails, -L still lists 8" "${eight_list%$'\n'}" "${nvml_error}" 8

echo
if (( failures )); then
    echo "${failures} failure(s)"
    exit 1
fi
echo "all checks passed"
