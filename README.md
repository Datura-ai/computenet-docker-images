# Computenet Docker Images

This repository contains the Dockerfiles for the Computenet pods.
Images are available on [Docker Hub](https://hub.docker.com/orgs/daturaai/repositories).

`daturaai/lium-validator` (the provider preflight check run by `lium mine`) is not built here. Its
Dockerfile is `neurons/validators/Dockerfile.preflight` in [lium-io](https://github.com/Datura-ai/lium-io);
no workflow in any repository builds or pushes it yet — every Docker Hub tag so far was pushed by hand.
(lium-io's `validator_cd_staging.yml` publishes the full validator to `ghcr.io/datura-ai/lium-validator`,
a different image.)

## Checks

`scripts/build-smoke.sh [template …]` resolves every template's bake file (`docker buildx bake --print`) and builds and boots the templates a change touches; the CI job `build-smoke` runs it on every PR. `E2E_GPU=1 scripts/build-smoke.sh pytorch` on a GPU host also requires `nvidia-smi` and `torch.cuda` inside the container.
