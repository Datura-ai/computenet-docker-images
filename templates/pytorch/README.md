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

## Exposed Ports

- 22/tcp (SSH)
