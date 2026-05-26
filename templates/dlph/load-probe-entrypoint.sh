#!/bin/bash
# Replicates cruizba/ubuntu-dind's /usr/local/bin/entrypoint.sh and injects
# load-probe.sh between dockerd-ready and the user-supplied CMD. We replace
# cruizba's entrypoint (rather than wrap it) because start-docker.sh from the
# base image ignores its arguments — chaining via `exec start-docker.sh ...`
# causes the args (and therefore the user CMD) to be silently dropped.
#
# Why ENTRYPOINT and not CMD: the lium validator overrides CMD when it spawns
# the DinD container (see DockerCommand.run_dind in neurons/validators), so
# any setup we put in CMD is silently dropped. ENTRYPOINT cannot be overridden
# without an explicit --entrypoint flag, and the validator does not pass one.
#
# Order of operations matches cruizba's original:
#   1. start-docker.sh     -> brings dockerd up, returns once API is ready
#   2. load-probe.sh       -> docker load -i /opt/probe/hello-world.tar (DAH-1959)
#                             best-effort; failure falls back to registry pull
#   3. exec "$@"           -> the user-supplied CMD (or default CMD if none)

start-docker.sh

# DAH-1959: bundle hello-world into the inner dockerd's image store before any
# user CMD runs, so the validator's `docker run --rm hello-world` probe finds
# it locally and never round-trips Docker Hub. `|| true` keeps this best-effort.
/usr/local/bin/load-probe.sh || true

exec "$@"
