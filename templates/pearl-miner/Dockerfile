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
# 2.16.4 made Pearl faster on B300; 2.17.0 is a Pearl hashrate release for every
# card; 2.17.1 makes the CMP HX unlock opt-in (--cmp-unlock), which this image does not pass.
FROM ubuntu:24.04

ARG PEAKMINER_VERSION=2.17.1
ARG PEAKMINER_URL=https://github.com/peakminer/peakminer/releases/download/v${PEAKMINER_VERSION}/peakminer-${PEAKMINER_VERSION}-linux-x86_64
ARG PEAKMINER_SHA256=abdc8f915c149e5ca265a40dbafa59b92159a1d40478ced199e4e384060cbe3f
# DAH-6084: `peakminer` (the default, the filler fleet's image) or `wildrig` (WildRig Multi, the benchmark image, bake target
# `wildrig`). WildRig is pinned by the sha256 of the official release tarball and never self-updates: a benchmark compares
# one exact build. Bump both lines together, from https://github.com/andru-kun/wildrig-multi/releases.
ARG PEARL_MINER=peakminer
ARG WILDRIG_VERSION=0.52.1
ARG WILDRIG_SHA256=33587b9968b1d631b1574db8ea9c5cc50ef966e653fec4bcbb3001a6ad9dfdc0

# python3: only for the metrics sidecar, which is stdlib-only on purpose — the miner binary itself
# needs nothing but glibc. NOT python3-minimal: it ships a cut-down stdlib without hmac or
# http.server, and the sidecar dies at import with ModuleNotFoundError (verified on the box).
# openssh-server: the validator's SSH bootstrap installs it at every filler start (~25 s) unless an
# sshd is already running; entrypoint.sh starts this one. The package's postinst generates host keys,
# so they are deleted in the same RUN — no layer may carry them, every container makes its own.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tini python3 openssh-server \
    && rm -f /etc/ssh/ssh_host_* \
    && rm -rf /var/lib/apt/lists/*

# The same hardening the validator's SSH bootstrap applies (it skips a config that already carries
# the `# lium-hardened` marker), baked so there is no window where sshd runs with password login on.
RUN sed -i -E 's/^[[:space:]]*(PasswordAuthentication|ChallengeResponseAuthentication|KbdInteractiveAuthentication)[[:space:]]+.*/# lium-disabled &/I' /etc/ssh/sshd_config \
    && printf '\n# lium-hardened\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nChallengeResponseAuthentication no\n' >> /etc/ssh/sshd_config

RUN curl -fsSL "${PEAKMINER_URL}" -o /usr/local/bin/peakminer \
    && echo "${PEAKMINER_SHA256}  /usr/local/bin/peakminer" | sha256sum -c - \
    && chmod +x /usr/local/bin/peakminer

# WildRig drives NVIDIA cards through OpenCL: the runtime's `compute` capability injects libnvidia-opencl, but not the ICD
# entry the loader looks it up by, so both are added here. The build fails on a checksum mismatch or an unknown miner.
RUN case "${PEARL_MINER}" in \
      peakminer) ;; \
      wildrig) \
        apt-get update \
        && apt-get install -y --no-install-recommends ocl-icd-libopencl1 \
        && rm -rf /var/lib/apt/lists/* \
        && mkdir -p /etc/OpenCL/vendors \
        && echo "libnvidia-opencl.so.1" > /etc/OpenCL/vendors/nvidia.icd \
        && curl -fsSL "https://github.com/andru-kun/wildrig-multi/releases/download/${WILDRIG_VERSION}/wildrig-multi-linux-${WILDRIG_VERSION}.tar.gz" -o /tmp/wildrig.tar.gz \
        && echo "${WILDRIG_SHA256}  /tmp/wildrig.tar.gz" | sha256sum -c - \
        && tar -xzf /tmp/wildrig.tar.gz --no-same-owner -C /usr/local/bin wildrig-multi \
        && chmod 755 /usr/local/bin/wildrig-multi \
        && rm /tmp/wildrig.tar.gz ;; \
      *) echo "unknown PEARL_MINER '${PEARL_MINER}' (peakminer or wildrig)" >&2; exit 1 ;; \
    esac

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY update_miner.sh /usr/local/bin/update_miner.sh
COPY metrics_sidecar.py /usr/local/bin/metrics_sidecar.py
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/update_miner.sh

# The baked-in version is what the entrypoint's updater compares against at start.
ENV PEARL_MINER_BAKED_VERSION=${PEAKMINER_VERSION} \
    PEARL_MINER=${PEARL_MINER} \
    PEARL_WILDRIG_VERSION=${WILDRIG_VERSION} \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    PEARL_POOL_HOST=prl.kryptex.network \
    PEARL_POOL_PORT=7048

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
