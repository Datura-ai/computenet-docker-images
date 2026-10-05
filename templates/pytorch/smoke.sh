#!/bin/sh
# Run by scripts/build-smoke.sh inside the booted container. A DinD image is booted there with --privileged, so its
# nested dockerd must answer: pytorch-entrypoint.sh starts it beside /start.sh rather than before it.
set -e
[ "$ENABLE_DIND" = true ] || exit 0
for _ in $(seq 1 60); do
    if docker info >/dev/null 2>&1; then
        echo "nested dockerd answers"
        # Without these rules an IPv6 network made inside the pod reaches the pod's other nested networks.
        ip6tables -S | grep -q DOCKER || { echo "nested dockerd wrote no IPv6 firewall rules"; exit 1; }
        echo "nested dockerd isolates IPv6 networks"
        exit 0
    fi
    sleep 0.5
done
docker info
