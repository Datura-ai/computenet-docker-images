#!/bin/bash
# Lium extras for the PyTorch DinD templates. Runs once at image build time
# (see Dockerfile.lium). Arguments:
#   $1  CUDA toolkit apt suffix matching the torch wheels, e.g. "13-0" or "12-8"
#       (empty = do not install a toolkit)
#   $2  the image tag being built (recorded in /etc/lium-image.json and the MOTD)
set -euo pipefail

CUDA_PKG_VERSION="${1:-}"
IMAGE_TAG="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------- #
# 1. apt: CUDA toolkit (nvcc + headers + dev libs) and media / OCR / GUI-less  #
#    render dependencies. The toolkit comes from NVIDIA's ubuntu2404 repo so    #
#    nvcc matches the CUDA major.minor of the torch wheels; torch keeps loading  #
#    its own bundled runtime libraries (pip nvidia-*), nothing here shadows them.#
# ---------------------------------------------------------------------------- #
apt-get update --yes
apt-get install --yes --no-install-recommends \
    ffmpeg \
    tesseract-ocr tesseract-ocr-eng \
    git-lfs \
    cmake ninja-build pkg-config \
    pciutils \
    nvtop \
    libglu1-mesa libegl1 libxi6 libxrender1 libxkbcommon0 libsm6 libxxf86vm1 libxfixes3

if [[ -n "${CUDA_PKG_VERSION}" ]]; then
    . /etc/os-release
    KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${VERSION_ID//./}/x86_64/cuda-keyring_1.1-1_all.deb"
    curl -fsSL "${KEYRING_URL}" -o /tmp/cuda-keyring.deb
    dpkg -i /tmp/cuda-keyring.deb
    rm -f /tmp/cuda-keyring.deb
    apt-get update --yes
    # Enough to build torch extensions (flash-attn, apex, xformers, custom kernels):
    # compiler + runtime/driver headers + the math libraries' headers, NVTX and
    # the profiler API. No samples, no nsight, no npp/nvjpeg/cufile.
    apt-get install --yes --no-install-recommends \
        "cuda-compiler-${CUDA_PKG_VERSION}" \
        "cuda-cudart-dev-${CUDA_PKG_VERSION}" \
        "cuda-driver-dev-${CUDA_PKG_VERSION}" \
        "cuda-nvrtc-dev-${CUDA_PKG_VERSION}" \
        "cuda-nvtx-${CUDA_PKG_VERSION}" \
        "cuda-profiler-api-${CUDA_PKG_VERSION}" \
        "cuda-nvml-dev-${CUDA_PKG_VERSION}" \
        "libcublas-dev-${CUDA_PKG_VERSION}" \
        "libcusparse-dev-${CUDA_PKG_VERSION}" \
        "libcusolver-dev-${CUDA_PKG_VERSION}" \
        "libcurand-dev-${CUDA_PKG_VERSION}" \
        "libcufft-dev-${CUDA_PKG_VERSION}"
    CUDA_DIR="/usr/local/cuda-${CUDA_PKG_VERSION//-/.}"
    [[ -d "${CUDA_DIR}" ]]
    ln -sfn "${CUDA_DIR}" /usr/local/cuda
    # Static archives of the math libraries are ~1.5 GB and nothing in a pod links
    # them; keep cudart's (nvcc defaults to -cudart static), the device runtime and
    # culibos (cudart_static depends on it). lib64 is a symlink, hence the trailing /.
    find "${CUDA_DIR}/lib64/" -maxdepth 1 -name '*.a' \
        ! -name 'libcudart_static.a' ! -name 'libcudadevrt.a' ! -name 'libculibos.a' -delete
    du -sh "${CUDA_DIR}"
    "${CUDA_DIR}/bin/nvcc" --version
fi

apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------- #
# 2. pip: build helpers and the HF CLI, then pin torch so a later                #
#    `pip install <package>` cannot silently replace the image's torch with a    #
#    wheel built for another CUDA (B-29). Override for one command with          #
#    `PIP_CONSTRAINT=/dev/null pip install ...`.                                 #
# ---------------------------------------------------------------------------- #
pip install --no-cache-dir --break-system-packages \
    uv \
    "huggingface_hub[cli]" hf_transfer \
    ninja packaging wheel setuptools

TORCH_VERSION="$(python -c 'import torch; print(torch.__version__)')"
TORCHVISION_VERSION="$(python -c 'import torchvision; print(torchvision.__version__)' 2>/dev/null || true)"
TORCH_CUDA="$(python -c 'import torch; print(torch.version.cuda or "")')"
# Compile-time arch flags; torch.cuda.get_arch_list() returns [] without a GPU, and
# there is none inside a build.
TORCH_ARCHES="$(python -c 'import torch; print(torch._C._cuda_getArchFlags() or "")')"

install -d -m 0755 /etc/pip
{
    echo "# Pins torch to the build shipped in this image (CUDA ${TORCH_CUDA})."
    echo "# Loaded through /etc/pip.conf; bypass once with PIP_CONSTRAINT=/dev/null pip install ..."
    echo "torch==${TORCH_VERSION}"
    if [[ -n "${TORCHVISION_VERSION}" ]]; then echo "torchvision==${TORCHVISION_VERSION}"; fi
} > /etc/pip/constraints.txt
install -m 0644 "${HERE}/pip.conf" /etc/pip.conf

# ---------------------------------------------------------------------------- #
# 3. Environment for every kind of session. Docker ENV only reaches processes   #
#    the entrypoint starts; an SSH login gets its environment from pam_env       #
#    (/etc/environment) and, for interactive shells, /etc/profile.d.            #
# ---------------------------------------------------------------------------- #
cat > /etc/environment <<'EOF'
PATH="/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
CUDA_HOME="/usr/local/cuda"
PIP_BREAK_SYSTEM_PACKAGES="1"
HF_HOME="/workspace/hf"
EOF
install -m 0644 "${HERE}/lium-env.sh" /etc/profile.d/lium-env.sh
install -m 0644 "${HERE}/zzz-lium-tips.sh" /etc/profile.d/zzz-lium-tips.sh
install -m 0755 "${HERE}/lium-gpu-check" /usr/local/bin/lium-gpu-check

# ---------------------------------------------------------------------------- #
# 4. Image manifest for tooling (lium-gpu-check, the MOTD, the CLI's template   #
#    arch column).                                                              #
# ---------------------------------------------------------------------------- #
python - "${IMAGE_TAG}" "${TORCH_VERSION}" "${TORCH_CUDA}" "${TORCH_ARCHES}" "${CUDA_PKG_VERSION}" <<'PY'
import json, subprocess, sys, datetime
tag, torch_v, torch_cuda, arches, cuda_pkg = sys.argv[1:6]
nvcc = ""
try:
    out = subprocess.run(["/usr/local/cuda/bin/nvcc", "--version"], capture_output=True, text=True).stdout
    nvcc = next((l.split("release ")[1].split(",")[0] for l in out.splitlines() if "release" in l), "")
except Exception:
    pass
json.dump({
    "variant": "lium1",
    "tag": tag,
    "torch": torch_v,
    "torch_cuda": torch_cuda,
    "torch_arch_list": arches.split(),
    "nvcc": nvcc,
    "cuda_toolkit_pkg": cuda_pkg,
    "built": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, open("/etc/lium-image.json", "w"), indent=1)
PY
cat /etc/lium-image.json
