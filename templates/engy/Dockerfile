# engy (Bittensor SN53) inference worker.
#
# Two processes, unlike Dolphin's single binary: one `sglang serve` per GPU holding the model, and
# one `engy_miner.py` dialing OUT to the gateway websocket and driving all of them. No inbound port.
#
# -devel base, not -runtime: sglang's DeepGEMM JIT-compiles FP8 kernels with nvcc during CUDA-graph
# capture, so the container needs the CUDA toolkit AND a host compiler at RUN time, not just build
# time. Verified the hard way on a 2xH100 box: a -runtime image dies with
# "NVCC compilation failed" the moment the engine warms up.
#
# ubuntu24.04 (gcc 13), not 22.04: sglang 0.5.12's JIT kernel sources fail to compile under gcc 12
# with a template deduction error in activation.cuh. Same box, same nvcc — only the host compiler
# differs.
ARG BASE_IMAGE=nvidia/cuda:13.0.0-devel-ubuntu24.04
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive

# libnuma1: without it sgl_kernel fails to load behind a misleading "kernel not found".
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    jq \
    libnuma1 \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Pins, all of them paid for once already on the pilot box:
#   sglang       — the version vendor/sitecustomize.py is verified against
#   kernels 0.13 — 0.15+ breaks transformers 5.6.0's kernel map
#   jinja2 >=3.1 — apply_chat_template refuses older; distro python ships 3.0.3 on some bases
ARG SGLANG_VERSION=0.5.12.post1
ARG KERNELS_VERSION=0.13.0
RUN pip install --no-cache-dir --break-system-packages \
    "sglang[all]==${SGLANG_VERSION}" \
    "kernels==${KERNELS_VERSION}" \
    "jinja2>=3.1.0" \
    toploc transformers numpy requests websockets hf_transfer huggingface_hub

ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=/usr/local/cuda/bin:${PATH}

# Shared cache volume: the ~35GB FP8 checkpoint lives here so a re-created container starts warm.
# Same role DOLPHIN_HOME plays for Dolphin.
ENV ENGY_HOME=/opt/engy
ENV ENGY_MINER_DIR=/opt/engy-miner

WORKDIR ${ENGY_HOME}

# Vendored from github.com/hanlinai/engy @ v0.4.4 (miner/). Upstream publishes no package, and the
# miner must match the gateway protocol exactly — so it is pinned here rather than fetched at boot.
# PYTHONPATH points at this dir so sitecustomize.py can trim the hidden states sglang returns.
COPY vendor/engy_miner.py vendor/sitecustomize.py ${ENGY_MINER_DIR}/

COPY metrics_sidecar.py ${ENGY_HOME}/metrics_sidecar.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
