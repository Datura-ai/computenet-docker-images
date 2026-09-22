## Build Options

To build with default options, run `docker buildx bake`, to build a specific target, run `docker buildx bake <target>`.

Targets: `full-version` (`daturaai/better-comfyui:full`, four SD checkpoints baked in), `light-version` (`:light`, no checkpoints — the one CI builds), `dev` (`:dev`).

Base: `daturaai/pytorch:2.7.0-py3.12-cuda12.8.0-devel-ubuntu22.04`. The `comfyui-install` stage installs torch 2.7.0 / torchvision 0.22.0 / torchaudio 2.7.0 and xformers 0.0.30 from the cu128 index into the venv, so the image runs on Blackwell GPUs (B200, B300, RTX 5090 — sm_100/sm_120) as well as on Turing, Ampere and Ada. The host driver must be 570 or newer, or one of the 470/535/550/560/565 branches the base image lists for CUDA forward compatibility (`NVIDIA_REQUIRE_CUDA=cuda>=12.8 …`; the cu126 base accepted 560+ or 470/535/550).

## Start path

The image CMD is `/start.sh` (`scripts/start.sh`), which runs `/pre_start.sh` in the foreground: on the first start the venv is copied from `/venv` to `/workspace/venvs/better-comfyui` (~6.5 GB, a few minutes) and `/ComfyUI` to `/workspace/ComfyUI`, then ComfyUI starts on port 3000 (`--listen --port 3000 --enable-cors-header`, plus whatever `CUSTOM_ARGS` holds). The server log is `/workspace/comfyui.log`. If the server exits, the pod stays up for SSH. `NO_SYNC=true` skips the sync and the server — and everything `/start.sh` runs after `pre_start.sh` (its SSH setup, Jupyter, `post_start.sh`): the container just sleeps.

## Ports

- 3000/tcp (ComfyUI)
- 22/tcp (SSH)
- 8888/tcp (Jupyter Lab, only when `JUPYTER_PASSWORD` is set)
- 3001/tcp (nginx in front of 3000, only when `REQUIRE_NGINIX=true`)

## Checks

- `bash templates/better-comfyui/tests/test_pre_start.sh` — on Linux (needs rsync and coreutils `timeout`): the first-time-sync spinner is stopped without ending `pre_start.sh` (the archived image died here), no bare `wait` under `set -e`, a failing command hands back to `/start.sh` with the pod still up, `CUSTOM_ARGS` handling.
- `templates/better-comfyui/smoke/template_serve_probe.sh <image> [port=3000]` — on a GPU host with the NVIDIA container toolkit: starts the image the way the platform does (image CMD, no startup command, `--gpus all`), waits up to `PROBE_TIMEOUT_MIN` (20) minutes for HTTP 200 on the port and a `cuda` device in `GET /system_stats`, prints `PASS: ComfyUI <version> · python … · torch … · <GPU>` or `FAIL: <why>` with the container log tail. There is no GPU runner in CI, so this probe is the gate before a tag is published or a template row points at it.
