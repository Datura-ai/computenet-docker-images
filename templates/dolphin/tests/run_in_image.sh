#!/usr/bin/env bash
# In-image verification for daturaai/dolphin: run the sidecar and watchdog
# contract tests with the image's python3 + shipped copies (catches stdlib
# gaps a host run would hide), then prove the entrypoint starts both and that
# `docker stop` returns promptly with exit code 0 (no SIGKILL after the grace).
#
# The watchdog's kill tests are skipped on a macOS host for want of /proc, so
# this is the only place they actually run — do not skip it.
set -euo pipefail
IMAGE="${1:-daturaai/dolphin:0.0.10}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== [1/3] sidecar tests inside ${IMAGE} =="
docker run --rm --entrypoint python3 \
    -v "${HERE}:/tests:ro" \
    -e SIDECAR_PATH=/opt/dolphinpod/metrics_sidecar.py \
    "${IMAGE}" /tests/test_sidecar.py

echo "== [2/3] watchdog tests inside ${IMAGE} (they kill real processes, hence a container) =="
docker run --rm --entrypoint python3 \
    -v "${HERE}:/tests:ro" \
    -e SIDECAR_PATH=/opt/dolphinpod/metrics_sidecar.py \
    -e WATCHDOG_PATH=/opt/dolphinpod/watchdog.py \
    "${IMAGE}" /tests/test_watchdog.py

echo "== [3/3] entrypoint integration: sidecar + watchdog up, clean docker stop =="
CT="dolphin-sidecar-test-$$"
docker rm -f "${CT}" >/dev/null 2>&1 || true
docker run -d --name "${CT}" \
    -e DOLPHIN_API_KEY=dp-dummy-key \
    -e DOLPHIN_WORKER_URL=http://127.0.0.1:1/unreachable \
    -e METRICS_TOKEN=stub-token \
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
