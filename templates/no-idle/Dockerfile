# No Idle Job filler image (DAH-2359).
#
# Backs the Miner Portal "No Idle Job" default-job preset: a provider assigns it to a node
# to stop Lium's idle default jobs there (and forfeit the unrented incentive). The container
# does nothing and uses no GPU — the default-job launcher supplies `sleep infinity` as the
# startup command, so the image only needs to be a tiny, long-running-capable base.
ARG BASE_IMAGE=alpine:3.20
FROM ${BASE_IMAGE}

# Fallback command if the launcher does not override it; keeps the container alive.
CMD ["sleep", "infinity"]
