#!/usr/bin/env bash
# template_serve_probe.sh — does this image serve ComfyUI when started the way the Lium validator starts a template?
#
#     templates/better-comfyui/smoke/template_serve_probe.sh <image> [port=3000]
#
# The container is started exactly as the platform starts a template whose row has no startup command: the image's own
# CMD, no command override, no environment, `--gpus all` (needs the NVIDIA container toolkit on the host). The probe then
# waits up to PROBE_TIMEOUT_MIN minutes (default 20 — the first start syncs a 6.5 GB venv into /workspace) for
#   1. GET http://127.0.0.1:<port>/ → HTTP 200, and
#   2. GET /system_stats → JSON whose `devices` list a `cuda` device,
# and prints PASS (with the ComfyUI / torch versions and the GPU the server reports) or FAIL with the tail of the
# container log. A container that exits before serving is a FAIL at once. Exit 0 on PASS, 1 on FAIL, 2 on usage.
#
# Env: PROBE_TIMEOUT_MIN (20) · PROBE_PULL=0 to skip `docker pull` (a locally built tag) · PROBE_KEEP=1 to leave the
# container running after the verdict (it is removed otherwise) · PROBE_GPUS ("all", the value for --gpus).
set -uo pipefail

IMAGE=${1:-}
PORT=${2:-3000}
[ -n "$IMAGE" ] || { echo "usage: $0 <image> [port=3000]" >&2; exit 2; }
case "$PORT" in ''|*[!0-9]*) echo "port must be a number, got '$PORT'" >&2; exit 2;; esac

TIMEOUT_MIN=${PROBE_TIMEOUT_MIN:-20}
GPUS=${PROBE_GPUS:-all}
NAME="serve-probe-$$"
LOG_TAIL=40
STARTED=$SECONDS

for cmd in docker curl python3; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "FAIL: $cmd not on PATH" >&2; exit 1; }
done

cleanup() {
    if [ "${PROBE_KEEP:-0}" = 1 ]; then
        echo "container $NAME kept running (PROBE_KEEP=1): docker logs -f $NAME"
    else
        docker rm -f "$NAME" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1 (after $((SECONDS - STARTED)) s)"
    echo "--- docker logs --tail $LOG_TAIL $NAME ---"
    docker logs --tail "$LOG_TAIL" "$NAME" 2>&1 || true
    echo "--- end of log ---"
    exit 1
}

if [ "${PROBE_PULL:-1}" != 0 ]; then
    echo "pulling $IMAGE ..."
    docker pull "$IMAGE" >/dev/null || { echo "FAIL: docker pull $IMAGE"; exit 1; }
fi
echo "image CMD: $(docker image inspect --format '{{json .Config.Cmd}}' "$IMAGE")"

docker rm -f "$NAME" >/dev/null 2>&1 || true
# no command after the image and no -e: the image CMD is the start path under test
CID=$(docker run -d --gpus "$GPUS" -p "127.0.0.1:${PORT}:${PORT}" --name "$NAME" "$IMAGE") \
    || { echo "FAIL: docker run --gpus $GPUS $IMAGE"; exit 1; }
echo "started $NAME (${CID:0:12}); waiting up to $TIMEOUT_MIN min for http://127.0.0.1:$PORT ..."

deadline=$((SECONDS + TIMEOUT_MIN * 60))
http_ok=0
while [ $SECONDS -lt $deadline ]; do
    state=$(docker inspect --format '{{.State.Status}}' "$NAME" 2>/dev/null || echo gone)
    [ "$state" = running ] || fail "container is '$state' before serving on :$PORT — the start path exited"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PORT/" || true)
    if [ "$code" = 200 ]; then http_ok=1; break; fi
    sleep 5
done
[ $http_ok = 1 ] || fail "no HTTP 200 from :$PORT within $TIMEOUT_MIN min (last code '${code:-none}')"
echo "HTTP 200 on :$PORT after $((SECONDS - STARTED)) s"

stats=$(curl -s --max-time 10 "http://127.0.0.1:$PORT/system_stats") || fail "GET /system_stats did not answer"
verdict=$(printf '%s' "$stats" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit("system_stats is not JSON")
s = d.get("system", {})
gpus = [x for x in d.get("devices", []) if x.get("type") == "cuda"]
if not gpus:
    sys.exit("no cuda device in /system_stats: devices=%s" % [x.get("name") for x in d.get("devices", [])])
print("ComfyUI %s · python %s · torch %s · %s (%.1f GB)" % (
    s.get("comfyui_version"), s.get("python_version", "?").split()[0], s.get("pytorch_version"),
    gpus[0].get("name"), gpus[0].get("vram_total", 0) / 1e9))
' 2>&1) || fail "$verdict"
echo "PASS: $verdict ($((SECONDS - STARTED)) s total)"
