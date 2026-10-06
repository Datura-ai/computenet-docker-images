## Build Instructions

- To build with the default options, simply run `docker buildx bake`.
- To build a specific target, use `docker buildx bake <target>`.
- To specify the platform, use `docker buildx bake <target> --set <target>.platform=linux/amd64`.

Example:
```bash
docker buildx bake 240-py311-cuda1240-devel-ubuntu2204 --set 240-py311-cuda1240-devel-ubuntu2204.platform=linux/amd64
```

PyTorch 2.12 Docker-in-Docker image matrix:

| Python | CUDA | Ubuntu | Target |
| --- | --- | --- | --- |
| 3.12 | 12.6 | 24.04 | `2120-py312-cuda126-devel-ubuntu2404-dind` |
| 3.12 | 12.8 | 24.04 | `2120-py312-cuda128-devel-ubuntu2404-dind` |
| 3.12 | 13.0.2 | 24.04 | `2120-py312-cuda1302-devel-ubuntu2404-dind` |
| 3.12 | 13.2 | 24.04 | `2120-py312-cuda132-devel-ubuntu2404-dind` |

The PyTorch 2.12.0 DinD targets use `daturaai/dind:0.0.2` as their base so nested Docker runs under Sysbox. The `cuda12.6` and `cuda12.8` tags install PyTorch from the `cu126` wheel index, the `cuda13.0.2` tag installs PyTorch from the `cu130` wheel index, and the `cuda13.2` tag installs PyTorch from the `cu132` wheel index. There is no PyTorch 2.12.0 `cu128` wheel index.

Build all PyTorch 2.12 DinD CUDA images:
```bash
docker buildx bake cuda-dind
```

Build one target:
```bash
docker buildx bake 2120-py312-cuda132-devel-ubuntu2404-dind --set 2120-py312-cuda132-devel-ubuntu2404-dind.platform=linux/amd64
```

The DinD-enabled image is published only with the explicit `-dind` tag. It uses the Datura DinD base image, installs Python/PyTorch/Jupyter, and keeps common developer tools such as `tmux`, `vim`, `nano`, `htop`, `jq`, `rsync`, `lsof`, `net-tools`, `iproute2`, `tree`, `zip`, and `unzip`. It then starts `dockerd` before the standard Computenet startup script. Running nested Docker requires Sysbox on the host:

```bash
docker run -d --rm --runtime=sysbox-runc --name pytorch-dind-test \
  daturaai/pytorch:2.12.0-py3.12-cuda13.2-devel-ubuntu24.04-dind

docker exec pytorch-dind-test docker run --rm hello-world
```

Security note: treat any shell, SSH, or Jupyter access to this image as access to the nested Docker daemon. This image is intended for trusted single-tenant workloads. Do not expose it to untrusted users or multi-tenant notebook workloads.

The nested daemon registers the NVIDIA runtime, but does not make it the default runtime for every child container. Use Docker's GPU flags or the explicit NVIDIA runtime for child containers that need GPU access.

## `-lium1` variants (group `lium`)

| Target | Tag | torch | nvcc |
| --- | --- | --- | --- |
| `2120-py312-cuda1302-devel-ubuntu2404-dind-lium1` | `daturaai/pytorch:2.12.0-py3.12-cuda13.0.2-devel-ubuntu24.04-dind-lium1` | 2.12.0+cu130 | 13.0 |
| `2110-py312-cuda128-devel-ubuntu2404-dind-lium1` | `daturaai/pytorch:2.11.0-py3.12-cuda12.8-devel-ubuntu24.04-dind-lium1` | 2.11.0+cu128 | 12.8 |

These are the DinD images above plus what a rental is missing on day one. Each is built in two stages: an untagged intermediate from the regular `Dockerfile` (the same arguments as the matching `-dind` target; the 12.8 slot switches to the cu128 wheel index because cu126 wheels have no `sm_100`/`sm_120` kernels and there is no 2.12.x cu128 wheel), then `Dockerfile.lium`, which runs `lium/install.sh` once on top:

- a CUDA toolkit matching the wheels (`nvcc`, runtime/driver/NVRTC headers, cuBLAS/cuSPARSE/cuSOLVER/cuRAND/cuFFT dev packages, NVTX, profiler API) from NVIDIA's apt repo, `/usr/local/cuda`, `CUDA_HOME`; static archives other than cudart's are removed;
- `ffmpeg`, `tesseract-ocr`, `git-lfs`, `cmake`, `ninja-build`, `nvtop`, the headless-render libraries Blender needs; `uv`, `huggingface_hub[cli]`, `hf_transfer`;
- `/etc/pip.conf` with `break-system-packages = true` (PEP 668 on Ubuntu 24.04) and `constraint = /etc/pip/constraints.txt`, which pins torch/torchvision to the image's build so an unrelated `pip install` cannot swap torch for a wheel built against another CUDA (`PIP_CONSTRAINT=/dev/null pip install …` bypasses it once);
- `/etc/environment` + `/etc/profile.d/lium-env.sh` so SSH sessions (which do not inherit Docker `ENV`) see `PATH` with `/usr/local/cuda/bin`, `CUDA_HOME`, `PIP_BREAK_SYSTEM_PACKAGES=1`, `HF_HOME=/workspace/hf`;
- a short MOTD after the banner (`/etc/profile.d/zzz-lium-tips.sh`) and `lium-gpu-check [--json]`, which reports GPU/driver/torch arch list, whether torch has kernels for this GPU (runs a matmul), nvcc, tools, NVENC, OptiX availability and the `/workspace` vs `/root` filesystems; `/etc/lium-image.json` records what was built.

`libnvoptix.so.1` is deliberately not shipped: it is a driver library that must match the host kernel module and nvidia-container-toolkit mounts it when the host has it (`NVIDIA_DRIVER_CAPABILITIES=all`). Hosts running headless server drivers do not have it; `lium-gpu-check` and the MOTD say so. Note for Blender users: the first OptiX render on a pod JIT-compiles the Cycles kernels for the GPU (measured ~5–6 min at 0 % GPU on H100 and RTX 5090 with Blender 4.2), which looks like a CPU fallback but is not; the CUDA device uses precompiled kernels and starts rendering immediately, and the OptiX cache in `~/.cache/cycles` makes later runs instant.

```bash
docker buildx bake --print lium
docker buildx bake lium
docker run --rm --gpus all daturaai/pytorch:2.12.0-py3.12-cuda13.0.2-devel-ubuntu24.04-dind-lium1 lium-gpu-check
```

The `lium` group is not part of `default`; the tags are opt-in until the backend's `DOCKER_IMAGES` list adopts them.

## Exposed Ports

- 22/tcp (SSH)
