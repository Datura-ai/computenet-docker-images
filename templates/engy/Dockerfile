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
# python3-dev: Triton JIT-compiles kernels against Python.h at first forward pass. Without the
# headers it does not fail loudly — it prints "Triton is not supported on current platform, roll
# back to CPU" and the engine limps along on the CPU path. Caught by running the container, not by
# building it.
# moreutils: for `ts`, which stamps every captured line. The miner prints without a timestamp, and
# reading our log against engy's per-request dashboard is guesswork without one.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    jq \
    libnuma1 \
    moreutils \
    python3 \
    python3-dev \
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

# DeepGEMM JIT-compiles ~16k FP8 kernels on a cold engine — measured 10-20 min before the engine
# serves its first token. Park that cache on the SHARED volume so only the first container on a node
# ever pays it: a re-created container (which already costs engy a new worker_id and re-qualification)
# must not also wait 20 minutes to come back.
ENV DG_JIT_CACHE_DIR=${ENGY_HOME}/deepgemm-cache

WORKDIR ${ENGY_HOME}

# Vendored from github.com/hanlinai/engy (miner/) — a byte-identical copy, refreshed from the
# default branch on every boot by the entrypoint. NEVER patch this file: Lium's modifications
# live in engy_launch.py and are applied from outside, so a refresh cannot drop them.
# This copy is the fallback for when GitHub is unreachable. Originally vendored at v0.4.4.
# PYTHONPATH points at this dir so sitecustomize.py can trim the hidden states sglang returns.
COPY vendor/engy_miner.py vendor/sitecustomize.py ${ENGY_MINER_DIR}/

# Code lives OUTSIDE ENGY_HOME on purpose: ENGY_HOME is the cache-volume root, and anything the
# image puts there is shadowed the moment a volume is mounted over it (found by running it — the
# sidecar silently vanished). ENGY_HOME holds data only.
# loop_probe.py rides in ENGY_MINER_DIR so the miner can `import loop_probe` off its own sys.path[0].
COPY metrics_sidecar.py loop_probe.py engy_launch.py ${ENGY_MINER_DIR}/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
