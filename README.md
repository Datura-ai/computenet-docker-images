# Computenet Docker Images

This repository contains the Dockerfiles for the Computenet pods.
Images are available on [Docker Hub](https://hub.docker.com/orgs/daturaai/repositories).

## Layout

- `templates/<name>/` — one directory per image: a `docker-bake.hcl` (every template but `kasm-desktop`), the Dockerfile(s) and a README where the image needs one. Tags are `daturaai/<image>:<tag>`; only `ubuntu`, `pytorch`, `redis` and `empty-job` take the org from a `PUBLISHER` variable, the others hard-code it or use `IMAGE_NAME`. Each bake file has a `default` group or target that `docker buildx bake` and `build-smoke.sh` resolve; `ubuntu` and `pytorch` also define a `group "smoke"` naming the one target CI builds when the template changes (otherwise the first `default` target).
- `scripts/` — files copied into the pod images: `start.sh` (the pod entrypoint), `computenet.txt` (the login banner), `proxy/` (the nginx config and landing page the web-UI images ship — 13 Dockerfiles `COPY --from=proxy`, e.g. vscode, bittensor, the stable-diffusion variants); plus `build-smoke.sh` (below).

## Building and publishing

No workflow in this repository pushes to Docker Hub — CI only builds (see Checks). An image is published by hand from its template directory:

```bash
cd templates/<name>
docker buildx bake --print            # the resolved targets and tags
docker buildx bake <target> --push    # or `docker buildx bake --push` for every default target
```

The bake files read `../../scripts`, a context outside the template directory; buildx 0.20+ stops `--push`/`--load` at an entitlement prompt for it (and fails without a TTY), so prefix the command with `BUILDX_BAKE_ENTITLEMENTS_FS=0` as `build-smoke.sh` does, or pass `--allow fs.read=../../scripts`.

`daturaai/lium-validator` (the provider preflight check run by `lium mine`) is not built here. Its
Dockerfile is `neurons/validators/Dockerfile.preflight` in [lium-io](https://github.com/Datura-ai/lium-io);
no workflow in any repository builds or pushes it yet — every Docker Hub tag so far was pushed by hand.
(lium-io's `validator_cd_staging.yml` publishes the full validator to `ghcr.io/datura-ai/lium-validator`,
a different image.)

## Checks

`scripts/build-smoke.sh [template …]` resolves every template's bake file (`docker buildx bake --print`, and each default target's Dockerfile must exist) and builds and boots the templates a change touches; the CI job `build-smoke` runs it on every PR. `E2E_GPU=1 scripts/build-smoke.sh pytorch` on a GPU host also requires `nvidia-smi` and `torch.cuda` inside the container. Linux only: the script needs GNU `timeout` and `python3`.

The other two workflows: `pytorch-install-chain` runs `templates/pytorch/tests/test-install-chain.sh` when the pytorch Dockerfile or its tests change (the install RUN chain must fail when a file it copies is missing), and `CodeQL` scans on every PR, push to `master`, merge-group run and weekly.
