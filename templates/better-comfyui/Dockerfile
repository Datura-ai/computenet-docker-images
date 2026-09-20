# Stage 1: Base Image
# CUDA 12.8 base + cu128 wheels: torch 2.7.0/cu128 carries sm_100 and sm_120 kernels, so the image runs on Blackwell
# (B200, B300, RTX 5090) as well as on Turing/Ampere/Ada (sm_75–sm_89), where the cu124 build ran before (DAH-3704).
# The host driver must be >= 570, or one of the 470/535/550/560/565 branches the base image lists for CUDA forward
# compatibility (its NVIDIA_REQUIRE_CUDA is `cuda>=12.8 …`; the cu126 base accepted >= 560 or 470/535/550).
ARG BASE_IMAGE=daturaai/pytorch:2.7.0-py3.12-cuda12.8.0-devel-ubuntu22.04
FROM ${BASE_IMAGE} AS base

ARG PYTHON_VERSION1=3.12

# Install fpart (which includes fpsync)
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y fpart && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Stage 2: ComfyUI Installation
FROM base AS comfyui-install

# ARGs are per stage: declared here, where they are used (a `--build-arg TORCH=…` reaches this RUN only through this
# line — the earlier declaration in the base stage never did, and the venv's torch came from ComfyUI's requirements.txt).
# torch, torchvision and torchaudio pinned together from the cu128 index so requirements.txt finds them satisfied and
# never pulls a PyPI (cu126) torch over them.
ARG TORCH="torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0 --index-url https://download.pytorch.org/whl/cu128"
# xformers built against that torch; an unpinned `pip install xformers` resolves to a release that needs a newer torch
# and replaces the cu128 one.
ARG XFORMERS="xformers==0.0.30 --index-url https://download.pytorch.org/whl/cu128"

# Create virtual environment
RUN mkdir -p /workspace/venvs && python -m venv /workspace/venvs/better-comfyui

# Set environment variables for the virtual environment
ENV VIRTUAL_ENV="/workspace/venvs/better-comfyui"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Activate the virtual environment and install packages. Every pip call runs with --no-cache-dir: the wheel cache
# (several GB for torch/xformers/insightface) would otherwise stay in this layer and in every image built on it.
RUN $VIRTUAL_ENV/bin/pip install --no-cache-dir --upgrade pip setuptools wheel && \
    if [ -n "${TORCH}" ]; then \
        $VIRTUAL_ENV/bin/pip install --no-cache-dir ${TORCH}; \
    fi && \
    git clone https://github.com/comfyanonymous/ComfyUI.git /ComfyUI && \
    $VIRTUAL_ENV/bin/pip install --no-cache-dir -r /ComfyUI/requirements.txt && \
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git /ComfyUI/custom_nodes/ComfyUI-Manager && \
    $VIRTUAL_ENV/bin/pip install --no-cache-dir -r /ComfyUI/custom_nodes/ComfyUI-Manager/requirements.txt && \
    if [ -n "${XFORMERS}" ]; then \
        $VIRTUAL_ENV/bin/pip install --no-cache-dir ${XFORMERS}; \
    fi && \
    $VIRTUAL_ENV/bin/pip install --no-cache-dir accelerate wheel comfy-cli insightface && \
    $VIRTUAL_ENV/bin/pip install --no-cache-dir ipykernel ipywidgets && \
    $VIRTUAL_ENV/bin/python -m ipykernel install --name "python3" --display-name "Python 3 (Workspace Venv)"

# The build fails here if any of the installs above resolved a different torch over the cu128 one.
RUN $VIRTUAL_ENV/bin/python -c 'import sys, torch; v = torch.version.cuda or "cpu"; sys.exit(0 if v.startswith("12.8") else "venv torch %s is a CUDA %s build, not cu128" % (torch.__version__, v))'

# Stage 3: Model Setup
FROM comfyui-install AS model-setup

# Create model and cache directories
RUN mkdir -p /root/.cache/huggingface /comfy-models

ARG INCLUDE_MODELS=false

# Download each model in a separate layer
RUN if [ "${INCLUDE_MODELS}" = "true" ]; then \
    wget -q --show-progress https://huggingface.co/Comfy-Org/stable-diffusion-v1-5-archive/resolve/main/v1-5-pruned-emaonly.safetensors -O /comfy-models/v1-5-pruned-emaonly.safetensors; \
    fi

RUN if [ "${INCLUDE_MODELS}" = "true" ]; then \
    wget -q --show-progress https://huggingface.co/stabilityai/stable-diffusion-2-1/resolve/main/v2-1_768-ema-pruned.safetensors -O /comfy-models/v2-1_768-ema-pruned.safetensors; \
    fi

RUN if [ "${INCLUDE_MODELS}" = "true" ]; then \
    wget -q --show-progress https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors -O /comfy-models/sd_xl_base_1.0.safetensors; \
    fi

RUN if [ "${INCLUDE_MODELS}" = "true" ]; then \
    wget -q --show-progress https://huggingface.co/stabilityai/stable-diffusion-xl-refiner-1.0/resolve/main/sd_xl_refiner_1.0.safetensors -O /comfy-models/sd_xl_refiner_1.0.safetensors; \
    fi

# Verify models were downloaded
RUN if [ "${INCLUDE_MODELS}" = "true" ]; then \
    ls -lh /comfy-models; \
    fi

# Stage 4: Final Image
FROM comfyui-install AS final

# Move virtual environment from /workspace/venv to /venv
RUN mv /workspace/venvs/better-comfyui /venv

# Copy models if they were included
COPY --from=model-setup /comfy-models /comfy-models

# Set environment variables for runtime
ENV VIRTUAL_ENV="/workspace/venvs/better-comfyui"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Copy the README.md
COPY README.md /usr/share/nginx/html/README.md

# NGINX Proxy
COPY --from=proxy nginx.conf /etc/nginx/nginx.conf
COPY --from=proxy readme.html /usr/share/nginx/html/readme.html

# Copy all necessary scripts
COPY pre_start.sh /pre_start.sh
COPY --from=scripts start.sh /
RUN chmod +x /start.sh
RUN chmod +x /pre_start.sh
COPY comfyui_extras.ipynb /comfyui_extras.ipynb

# Add the new install-flux.sh script
COPY install-flux.sh /install-flux.sh
RUN chmod +x /install-flux.sh

# The validator starts a template with the image CMD when the template row has no startup command, so this is the
# pod's start path: /start.sh → /pre_start.sh → ComfyUI on :3000 in the foreground. `tail -f /dev/null` (210db17)
# left every pod SSH-only with ComfyUI never started (DAH-3704).
CMD ["/start.sh"]

