#!/bin/sh
# Run by scripts/build-smoke.sh inside the booted container. A DinD image is booted there with --privileged, so its
# nested dockerd must answer: pytorch-entrypoint.sh starts it beside /start.sh rather than before it.
set -e
[ "$ENABLE_DIND" = true ] || exit 0
for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && { echo "nested dockerd answers"; exit 0; }
    sleep 0.5
done
docker info
