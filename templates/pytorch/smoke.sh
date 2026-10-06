#!/bin/sh
# Run by scripts/build-smoke.sh inside the booted container. A DinD image is booted there with --privileged, so its
# nested dockerd must answer: pytorch-entrypoint.sh starts it beside /start.sh rather than before it.
set -e
# start.sh starts Jupyter because smoke.env sets JUPYTER_PASSWORD; /api answers without the token.
jupyter_answers() { python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8888/api", timeout=1)' 2>/dev/null; }
for _ in $(seq 1 60); do jupyter_answers && break; sleep 0.5; done
jupyter_answers || { echo "Jupyter does not answer on port 8888"; exit 1; }
echo "Jupyter answers"
# /root is the renter's volume: Docker copies what the image keeps there into it, so the Dockerfile's cleanup must hold.
for leftover in /root/.cache /root/.launchpadlib /root/.wget-hsts /root/.local/share/jupyter/nbextensions /root/.jupyter/nbconfig; do
    [ ! -e "$leftover" ] || { echo "image leaves $leftover in /root"; exit 1; }
done
echo "/root holds no build leftovers"
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
