# Empty Job image (DAH-2359).
#
# Backs the Miner Portal "Empty Job" default-job preset: a provider assigns it to a node to stop
# Lium's idle default jobs there (and forgo the unrented incentive) while the node stays rentable.
# The container does nothing and uses no GPU — the default-job launcher supplies `sleep infinity`,
# so the image only needs to be a tiny long-running-capable base.
ARG BASE_IMAGE=alpine:3.20
FROM ${BASE_IMAGE}

# Fallback command if the launcher does not override it; keeps the container alive.
CMD ["sleep", "infinity"]
