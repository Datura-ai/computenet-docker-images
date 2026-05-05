#!/bin/bash
# Wait for the inner dockerd to be reachable, then load the bundled hello-world image
# into its image store. After this, `docker run --rm hello-world` inside the container
# is registry-free.
#
# Why this exists (DAH-1959): the validator's DinD probe runs `docker pull hello-world`
# inside the inner dockerd to confirm sysbox works. Anonymous pulls from Docker Hub hit
# per-IP rate limits on miners that run several executors behind one NAT, and the probe
# wrongly flags those executors as sysbox=False, cutting their reward multiplier. Bundling
# the image into the dind base eliminates the registry round-trip entirely.
#
# Best-effort: if dockerd never comes up or `docker load` fails, we exit non-zero and the
# bundled image is simply absent. The validator's probe will then fall back to a registry
# pull (its previous behaviour), so a load failure is observable but not catastrophic and
# never blocks dockerd startup (this script runs in the background — see Dockerfile CMD).

set -u

PROBE_TAR="/opt/probe/hello-world.tar"
MAX_WAIT_S=90
LOG_PREFIX="load-probe:"

if [ ! -f "$PROBE_TAR" ]; then
    echo "$LOG_PREFIX $PROBE_TAR missing, nothing to load" >&2
    exit 1
fi

for _ in $(seq 1 "$MAX_WAIT_S"); do
    if docker info >/dev/null 2>&1; then
        if docker load -i "$PROBE_TAR" >/dev/null 2>&1; then
            echo "$LOG_PREFIX hello-world image bundled into inner dockerd"
            exit 0
        fi
        echo "$LOG_PREFIX docker load failed" >&2
        exit 2
    fi
    sleep 1
done

echo "$LOG_PREFIX inner dockerd not ready after ${MAX_WAIT_S}s" >&2
exit 3
