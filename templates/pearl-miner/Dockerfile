# Lium PEARL (PRL) pool miner — pool-independent wrapper around the PeakMiner binary.
# The binary is standalone (glibc only, no CUDA toolkit at build time); libcuda is injected by the
# NVIDIA container runtime at run time.
#
# PeakMiner replaced the pearlhash-hosted binary in DAH-2688: Pearl's V3 salted-seed hard fork
# (block 98,900, 2026-08-11) made every older miner submit shares that the network rejects outright,
# and the pearlhash binary that survives it is datacenter-only. PeakMiner covers consumer and
# datacenter cards from one build, speaks plain Stratum V1 (so the pool is a flag), and serves its
# own stats — which is what finally makes rejected work visible to us.
#
# The baked build is the floor every filler starts on: the updater's release lookup is an anonymous
# GitHub API call, limited per public IP, so a farm behind one address can stay on the baked build.
# 2.16.4 added B300 (sm_103) kernels for Pearl; 2.17.0 is a Pearl hashrate release for every card.
FROM ubuntu:24.04

ARG PEAKMINER_VERSION=2.17.1
ARG PEAKMINER_URL=https://github.com/peakminer/peakminer/releases/download/v${PEAKMINER_VERSION}/peakminer-${PEAKMINER_VERSION}-linux-x86_64
ARG PEAKMINER_SHA256=abdc8f915c149e5ca265a40dbafa59b92159a1d40478ced199e4e384060cbe3f

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
COPY update_miner.sh /usr/local/bin/update_miner.sh
COPY metrics_sidecar.py /usr/local/bin/metrics_sidecar.py
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/update_miner.sh

# The baked-in version is what the entrypoint's updater compares against at start.
ENV PEARL_MINER_BAKED_VERSION=${PEAKMINER_VERSION} \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    PEARL_POOL_HOST=prl.kryptex.network \
    PEARL_POOL_PORT=7048

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
