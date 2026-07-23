# Dolphin (dphn.ai) v2 inference worker.
#
# v2 is a single self-updating binary + worker.json config (the model runtime is pulled
# by the binary at start), so — unlike the deprecated v1 image — this image runs the
# worker DIRECTLY in the pod, with no nested Docker to bootstrap.
#
# (An earlier version of this comment claimed sysbox blocks nested GPU containers. Measured
# false on 2026-07-23: under `--runtime=sysbox-runc --gpus all`, an inner `docker run --gpus
# all ... nvidia-smi` works, and nesting costs dolphin nothing. Whatever stopped v1, it was
# not that. Running directly is simply the simpler shape, not a workaround.)
#
# CUDA 12.8 runtime base so Blackwell (NVFP4) drivers are available; the worker still pulls
# its own model runtime on top. Override BASE_IMAGE for older CUDA if needed.
ARG BASE_IMAGE=nvidia/cuda:12.8.0-runtime-ubuntu22.04
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive

# build-essential: the worker's vLLM runtime JIT-compiles Triton kernels at first forward pass
# (Qwen3.6's GDN linear-attention path needs a C toolchain); without gcc the engine dies with
# "Failed to find C compiler" right after the model loads into VRAM. Verified on H100/CUDA 13.
# python3 (FULL package, not python3-minimal): the metrics sidecar needs http.server, which
# the -minimal stdlib split may not ship.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    jq \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Expose all host GPUs to the worker (auto-scales when worker.json gpu_ids is null).
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

# Where the dolphinpod-worker binary and its self-updates live.
ENV DOLPHIN_HOME=/opt/dolphinpod

WORKDIR ${DOLPHIN_HOME}

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Metrics sidecar (DAH-2468): proxies vLLM's unix-socket /metrics onto :9101 so the
# platform's published-port machinery can expose per-machine token counters.
COPY metrics_sidecar.py ${DOLPHIN_HOME}/metrics_sidecar.py

# Engine watchdog: restarts a vLLM engine that wedged inside a CUDA kernel (token counters
# frozen while requests are in flight). Imports the sidecar's unix-socket client, so both
# files must live in the same directory.
COPY watchdog.py ${DOLPHIN_HOME}/watchdog.py

# entrypoint.sh renders worker.json from env, ensures the binary is present, then supervises
# `dolphinpod-worker update && dolphinpod-worker start` in a restart loop: when the worker exits
# for a self-update (or crashes) it is restarted onto the freshly fetched binary, and an etag
# poll on the download URL forces that restart if the worker's own self-update never fires.
# `docker stop` still ends the worker cleanly (SIGTERM is forwarded).
CMD ["/usr/local/bin/entrypoint.sh"]
