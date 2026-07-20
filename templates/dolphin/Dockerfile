# Dolphin (dphn.ai) v2 inference worker.
#
# v2 is a single self-updating binary + worker.json config (the model runtime is pulled
# by the binary at start), so — unlike the deprecated v1 image — this image runs the
# worker DIRECTLY in the pod. No nested Docker: the sysbox runtime used by Lium executors
# blocks the DinD GPU container that the v1 bootstrap needed, which is why v1 could not run.
#
# CUDA 12.8 runtime base so Blackwell (NVFP4) drivers are available; the worker still pulls
# its own model runtime on top. Override BASE_IMAGE for older CUDA if needed.
ARG BASE_IMAGE=nvidia/cuda:12.8.0-runtime-ubuntu22.04
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive

# build-essential: the worker's vLLM runtime JIT-compiles Triton kernels at first forward pass
# (Qwen3.6's GDN linear-attention path needs a C toolchain); without gcc the engine dies with
# "Failed to find C compiler" right after the model loads into VRAM. Verified on H100/CUDA 13.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Expose all host GPUs to the worker (auto-scales when worker.json gpu_ids is null).
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

# Where the dolphinpod-worker binary and its self-updates live.
ENV DOLPHIN_HOME=/opt/dolphinpod

WORKDIR ${DOLPHIN_HOME}

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# entrypoint.sh renders worker.json from env, ensures the binary is present, then supervises
# `dolphinpod-worker update && dolphinpod-worker start` in a restart loop: when the worker exits
# for a self-update (or crashes) it is restarted onto the freshly fetched binary, and an etag
# poll on the download URL forces that restart if the worker's own self-update never fires.
# `docker stop` still ends the worker cleanly (SIGTERM is forwarded).
CMD ["/usr/local/bin/entrypoint.sh"]
