# DAH-2620: the customer-facing multi-node cluster image.
#
# Build and push as `daturaai/lium-cluster:<tag>`. That name is load-bearing: the backend refuses a
# cluster rental whose image does not start with it (CLUSTER_TEMPLATE_IMAGE_PREFIX), because only
# this entrypoint reads the injected config and raises wg0.
#
# A renter who takes a group of IB nodes gets this image on every pod. The validator injects one
# env var per pod — LIUM_WIREGUARD_CONF_B64, the node's wg-quick config — and the entrypoint below
# raises wg0 from it and points NCCL at the overlay. The renter runs `torchrun --nnodes=N ...` and
# the InfiniBand transport engages on its own; nothing here has to be configured by hand.
#
# daturaai/pytorch is the fleet's recommended image: PyTorch (so torchrun is present), CUDA,
# nvidia-smi and an inner Docker daemon. The renter runs their own torchrun on top.
# The CUDA 13.0.2 tag, not cuda12.8: that tag installs cu126 wheels with no kernel past sm_90, so torch
# fails "no kernel image is available" on B200/B300. cu130 carries sm_100 and sm_120.
ARG BASE_IMAGE=daturaai/pytorch:2.12.0-py3.12-cuda13.0.2-devel-ubuntu24.04-dind

# Ubuntu 24.04 ships rdma-core 50, whose libirdma reports an RDMA write with immediate as a plain
# receive; NCCL then fails every collective on Intel irdma. The fix landed in rdma-core 52.
FROM ubuntu:24.04 AS rdma-core
ARG RDMA_CORE_VERSION=65.0
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl cmake ninja-build pkg-config gcc libc6-dev \
        libnl-3-dev libnl-route-3-dev libudev-dev python3 \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://github.com/linux-rdma/rdma-core/releases/download/v${RDMA_CORE_VERSION}/rdma-core-${RDMA_CORE_VERSION}.tar.gz" \
        | tar -xz -C /tmp \
    && cmake -S "/tmp/rdma-core-${RDMA_CORE_VERSION}" -B /tmp/build -GNinja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu -DCMAKE_INSTALL_SYSCONFDIR=/etc \
        -DNO_PYVERBS=1 -DNO_MAN_PAGES=1 -DENABLE_STATIC=0 \
    && ninja -C /tmp/build \
    && DESTDIR=/out ninja -C /tmp/build install

FROM ${BASE_IMAGE}

# wireguard-tools brings wg + wg-quick, iproute2 the `ip` this entrypoint needs.
#
# The RDMA userspace is NOT in the base, despite the devices being forwarded: without libibverbs and
# the provider plugins NCCL logs "Failed to open libibverbs.so[.1]" and quietly falls back to its
# socket transport, so the job would crawl over the overlay while every device check still passes.
# ibverbs-utils is the diagnosis the renter reaches for first (ibv_devinfo), and perftest is how
# anyone confirms the fabric end to end (ib_write_bw).
RUN apt-get update && apt-get install -y --no-install-recommends \
        wireguard-tools \
        iproute2 \
        libibverbs1 \
        librdmacm1 \
        ibverbs-providers \
        ibverbs-utils \
        perftest \
    && rm -rf /var/lib/apt/lists/*

# Overlays the apt rdma-core above: libibverbs loads only providers built with it, so every one comes along.
COPY --from=rdma-core /out/usr/lib/x86_64-linux-gnu/ /usr/lib/x86_64-linux-gnu/
COPY --from=rdma-core /out/usr/bin/ /usr/bin/
COPY --from=rdma-core /out/etc/libibverbs.d/ /etc/libibverbs.d/
RUN ldconfig

COPY entrypoint.sh /usr/local/bin/lium-cluster-entrypoint
COPY lium-rdma-runc.py /usr/local/bin/lium-rdma-runc
COPY lium-fabric-env.py /usr/local/bin/lium-fabric-env
RUN chmod +x /usr/local/bin/lium-cluster-entrypoint /usr/local/bin/lium-rdma-runc \
    /usr/local/bin/lium-fabric-env

# The base image starts the inner Docker daemon only when asked. A cluster pod always wants it: the
# renter's job usually runs in their own image, and that is where the fabric has to reach.
ENV ENABLE_DIND=true

ENTRYPOINT ["/usr/local/bin/lium-cluster-entrypoint"]
# The base image's own start script, which our entrypoint execs into after raising the overlay.
CMD ["/start.sh"]
