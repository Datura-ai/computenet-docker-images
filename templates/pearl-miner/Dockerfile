# Lium PEARL (PRL) pool miner — pool-independent wrapper around the PeakMiner binary.
# The binary is standalone (glibc only, no CUDA toolkit at build time); libcuda is injected by the
# NVIDIA container runtime at run time.
#
# PeakMiner replaced the pearlhash-hosted binary in DAH-2688: Pearl's V3 salted-seed hard fork
# (block 98,900, 2026-08-11) made every older miner submit shares that the network rejects outright,
# and the pearlhash binary that survives it is datacenter-only. PeakMiner covers consumer and
# datacenter cards from one build, speaks plain Stratum V1 (so the pool is a flag), and serves its
# own stats — which is what finally makes rejected work visible to us.
FROM ubuntu:24.04

ARG PEAKMINER_VERSION=2.10.0
ARG PEAKMINER_URL=https://github.com/peakminer/peakminer/releases/download/v${PEAKMINER_VERSION}/peakminer-${PEAKMINER_VERSION}-linux-x86_64
ARG PEAKMINER_SHA256=25293f43691bdac1f1a209135c335b442991776640ff5552f495bc370d2c430d

# python3: only for the metrics sidecar, which is stdlib-only on purpose — the miner binary itself
# needs nothing but glibc. NOT python3-minimal: it ships a cut-down stdlib without hmac or
# http.server, and the sidecar dies at import with ModuleNotFoundError (verified on the box).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tini python3 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "${PEAKMINER_URL}" -o /usr/local/bin/peakminer \
    && echo "${PEAKMINER_SHA256}  /usr/local/bin/peakminer" | sha256sum -c - \
    && chmod +x /usr/local/bin/peakminer

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY metrics_sidecar.py /usr/local/bin/metrics_sidecar.py
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    PEARL_POOL_HOST=prl.kryptex.network \
    PEARL_POOL_PORT=7048

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
