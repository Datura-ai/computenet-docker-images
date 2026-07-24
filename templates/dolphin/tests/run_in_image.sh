#!/usr/bin/env bash
# In-image verification for daturaai/dolphin: run the sidecar and watchdog
# contract tests with the image's python3 + shipped copies (catches stdlib
# gaps a host run would hide), then prove the entrypoint starts both and that
# `docker stop` returns promptly with exit code 0 (no SIGKILL after the grace).
#
# The watchdog's kill tests are skipped on a macOS host for want of /proc, so
# this is the only place they actually run — do not skip it.
set -euo pipefail
IMAGE="${1:-daturaai/dolphin:0.0.11}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== [1/4] sidecar tests inside ${IMAGE} =="
docker run --rm --entrypoint python3 \
    -v "${HERE}:/tests:ro" \
    -e SIDECAR_PATH=/opt/dolphinpod/metrics_sidecar.py \
    "${IMAGE}" /tests/test_sidecar.py

echo "== [2/4] watchdog tests inside ${IMAGE} (they kill real processes, hence a container) =="
docker run --rm --entrypoint python3 \
    -v "${HERE}:/tests:ro" \
    -e SIDECAR_PATH=/opt/dolphinpod/metrics_sidecar.py \
    -e WATCHDOG_PATH=/opt/dolphinpod/watchdog.py \
    -e PYTHONPATH=/opt/dolphinpod \
    "${IMAGE}" /tests/test_watchdog.py

echo "== [3/4] entrypoint integration: sidecar + watchdog up, clean docker stop =="
CT="dolphin-sidecar-test-$$"
docker rm -f "${CT}" >/dev/null 2>&1 || true
# DOLPHIN_WORKER_PER_GPU=0 pins the single-worker mode: on a multi-GPU host the entrypoint
# would otherwise split, and split mode labels its watchdog series per bundle ([4/4] covers
# that shape) — here the point is that the unlabelled single-engine contract is unchanged.
docker run -d --name "${CT}" \
    -e DOLPHIN_API_KEY=dp-dummy-key \
    -e DOLPHIN_WORKER_URL=http://127.0.0.1:1/unreachable \
    -e METRICS_TOKEN=stub-token \
    -e DOLPHIN_WORKER_PER_GPU=0 \
    -v "${HERE}/stub_worker.sh:/opt/dolphinpod/dolphinpod-worker:ro" \
    "${IMAGE}" >/dev/null
sleep 3
docker exec "${CT}" curl -sf -H "Authorization: Bearer stub-token" \
    http://127.0.0.1:9101/metrics | grep -q "dolphin_sidecar_up 1" \
    || { echo "FAIL: sidecar not serving inside entrypoint"; docker logs "${CT}"; docker rm -f "${CT}"; exit 1; }
# the watchdog only reaches the scraper through the sidecar, so one grep covers both:
# the entrypoint started it AND its state file is being read
docker exec "${CT}" curl -sf -H "Authorization: Bearer stub-token" \
    http://127.0.0.1:9101/metrics | grep -q "dolphin_watchdog_up 1" \
    || { echo "FAIL: watchdog not running or its state not exported"; docker logs "${CT}"; docker rm -f "${CT}"; exit 1; }
[ "$(docker exec "${CT}" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9101/metrics)" = "401" ] \
    || { echo "FAIL: unauthenticated request not rejected"; docker rm -f "${CT}"; exit 1; }
START=$(date +%s)
docker stop -t 10 "${CT}" >/dev/null
STOP_SECONDS=$(( $(date +%s) - START ))
EXIT_CODE=$(docker inspect -f '{{.State.ExitCode}}' "${CT}")
docker rm "${CT}" >/dev/null
echo "docker stop took ${STOP_SECONDS}s, exit code ${EXIT_CODE}"
[ "${EXIT_CODE}" = "0" ] || { echo "FAIL: non-zero exit on docker stop"; exit 1; }
[ "${STOP_SECONDS}" -le 9 ] || { echo "FAIL: stop hit the kill grace (trap broken)"; exit 1; }
echo "OK: entrypoint integration clean"

echo "== [4/4] split mode: two workers, engine count exported, a watchdog per bundle =="
# A fake nvidia-smi makes the split deterministic without needing real GPUs, so this runs
# identically on a laptop and on a filler node.
SPLIT_CT="dolphin-split-test-$$"
docker rm -f "${SPLIT_CT}" >/dev/null 2>&1 || true
FAKE_SMI="$(mktemp)"
cat >"${FAKE_SMI}" <<'EOF'
#!/usr/bin/env bash
printf '0, 97887\n1, 97887\n'
EOF
chmod +x "${FAKE_SMI}"
docker run -d --name "${SPLIT_CT}" \
    -e DOLPHIN_API_KEY=dp-dummy-key \
    -e DOLPHIN_WORKER_URL=http://127.0.0.1:1/unreachable \
    -e METRICS_TOKEN=stub-token \
    -e DOLPHIN_SPLIT_STAGGER_SECONDS=0 \
    -v "${FAKE_SMI}:/usr/bin/nvidia-smi:ro" \
    -v "${HERE}/stub_worker.sh:/opt/dolphinpod/dolphinpod-worker:ro" \
    "${IMAGE}" >/dev/null
sleep 5
SPLIT_BODY="$(docker exec "${SPLIT_CT}" curl -sf -H "Authorization: Bearer stub-token" \
    http://127.0.0.1:9101/metrics || true)"
echo "${SPLIT_BODY}" | grep -q "dolphin_engines_expected 2" \
    || { echo "FAIL: sidecar was not told to expect 2 engines"; docker logs "${SPLIT_CT}"; docker rm -f "${SPLIT_CT}"; rm -f "${FAKE_SMI}"; exit 1; }
# One watchdog per bundle, each labelled with the cards it owns: an unlabelled series here
# would mean a single container-wide watchdog, whose kill takes down every bundle at once.
for GPU_LABEL in 0 1; do
    echo "${SPLIT_BODY}" | grep -q "dolphin_watchdog_up{dolphin_watchdog_gpus=\"${GPU_LABEL}\"} 1" \
        || { echo "FAIL: no watchdog for GPU ${GPU_LABEL}"; echo "${SPLIT_BODY}" | grep watchdog; docker rm -f "${SPLIT_CT}"; rm -f "${FAKE_SMI}"; exit 1; }
    # The stub worker starts no engine, so each watchdog must say so rather than look armed.
    echo "${SPLIT_BODY}" | grep -q "dolphin_watchdog_engine_found{dolphin_watchdog_gpus=\"${GPU_LABEL}\"} 0" \
        || { echo "FAIL: watchdog for GPU ${GPU_LABEL} claims an engine it cannot have"; echo "${SPLIT_BODY}" | grep watchdog; docker rm -f "${SPLIT_CT}"; rm -f "${FAKE_SMI}"; exit 1; }
done
docker logs "${SPLIT_CT}" 2>&1 | grep -q "spawning 2 worker(s)" \
    || { echo "FAIL: entrypoint did not spawn 2 workers"; docker logs "${SPLIT_CT}"; docker rm -f "${SPLIT_CT}"; rm -f "${FAKE_SMI}"; exit 1; }
SPLIT_START=$(date +%s)
docker stop -t 10 "${SPLIT_CT}" >/dev/null
SPLIT_STOP_SECONDS=$(( $(date +%s) - SPLIT_START ))
SPLIT_EXIT=$(docker inspect -f '{{.State.ExitCode}}' "${SPLIT_CT}")
docker rm "${SPLIT_CT}" >/dev/null
rm -f "${FAKE_SMI}"
echo "split-mode docker stop took ${SPLIT_STOP_SECONDS}s, exit code ${SPLIT_EXIT}"
[ "${SPLIT_EXIT}" = "0" ] || { echo "FAIL: non-zero exit on docker stop in split mode"; exit 1; }
[ "${SPLIT_STOP_SECONDS}" -le 9 ] || { echo "FAIL: split-mode stop hit the kill grace"; exit 1; }
echo "OK: split mode clean"
