# Dolphin (dphn.ai) v2 inference worker

Runs a [Dolphin v2](https://v2.dphn.ai) inference worker so idle Lium GPUs earn revenue.
v2 is datagen mode: it serves an LLM (currently `nvidia/Qwen3.6-35B-A3B-NVFP4`) and is paid
per million input/output tokens.

## Why this replaces the v1 image

v1 (`daturaai/dlph`) bootstrapped a **nested Docker GPU container**, which the sysbox runtime
on Lium executors blocks — so it could never connect. v2 is a single self-updating binary plus
a `worker.json` config, so this image runs the worker **directly in the pod**: no nested Docker.

## How it runs

`entrypoint.sh`:

1. Renders `~/.config/dolphinpod/worker.json` from environment variables.
2. Ensures the `dolphinpod-worker` binary is present (downloads it if missing).
3. Runs `dolphinpod-worker update && dolphinpod-worker start` in the foreground.

`update` self-updates the binary each boot (the network kicks stale binaries); `start` keeps
the process attached so the container stays alive and `docker stop` ends it cleanly.

## Environment variables

| Variable              | Required | Default                          | Notes |
|-----------------------|----------|----------------------------------|-------|
| `DOLPHIN_API_KEY`     | yes      | —                                | `dp-...` key from v2.dphn.ai. Inject as a secret. |
| `DOLPHIN_MODEL`       | no       | `nvidia/Qwen3.6-35B-A3B-NVFP4`   | Model to serve. |
| `DOLPHIN_WORKER_TYPE` | no       | `text-v`                         | Worker type. |
| `DOLPHIN_GPU_IDS`     | no       | (auto-select)                    | Comma-separated GPU indices, e.g. `0,1`. Empty → auto-select a valid slice (see Hardware). |
| `DOLPHIN_MIN_VRAM_MB` | no       | `71680` (70 GiB)                 | Total VRAM floor the selected GPUs must reach. |
| `DOLPHIN_UNSUPPORTED_GPUS` | no  | `A100`                           | Comma-separated GPU-name substrings that cannot boot NVFP4; the worker refuses to start on them. |
| `DOLPHIN_WORKER_URL`  | no*      | —                                | URL to fetch the worker binary when it is not baked into the image. |

\* Required until an official published binary URL / image exists — see below.

## Hardware

Running the full model needs **70 GB of VRAM** on an NVFP4-capable GPU. When `DOLPHIN_GPU_IDS`
is not set, the entrypoint auto-selects the **smallest accepted GPU count** whose combined VRAM
reaches the floor:

- Accepted counts: **1, 2, 4, 8, 16**. Odd counts (3, 5, …) are rejected by the network; 8+ is
  not fully efficient (only used when smaller counts cannot reach the floor).
- Examples: `1× H100 80 GB`, `2× A6000/L40 48 GB`, `4× RTX 3090/4090 24 GB`, `1× RTX 6000 PRO / B200`.
- If the box cannot reach the floor with an accepted count, the worker refuses to start.

**Architecture gate.** VRAM size alone is not enough — the GPU must support NVFP4. **A100
(Ampere) cannot boot NVFP4** even though its 80 GB clears the floor, so the worker refuses to
start on it (skip, not crash-loop). This is enforced independently of `DOLPHIN_GPU_IDS` and is
configurable via `DOLPHIN_UNSUPPORTED_GPUS`. (Note: the dphn.ai docs list A100 as compatible,
but the Dolphin team confirmed it will not boot NVFP4 yet.)

> `2× RTX 5090` (2×32 = 64 GB) is below the stated 70 GB floor — with the default
> `DOLPHIN_MIN_VRAM_MB` that box bumps to 4×. Lower `DOLPHIN_MIN_VRAM_MB` if GLRP confirms the
> real NVFP4 footprint fits in 64 GB.

## Payouts

Manual weekly for the first ~2 weeks; then self-serve on v2.dphn.ai. Track earnings on the
v2.dphn.ai dashboard.

## Status / external dependency

> **Draft.** The Dolphin team (GLRP) has not yet shipped an official public binary URL or
> Docker image, and per-account bootstrap install links expire. Until then the binary URL is
> supplied at runtime via `DOLPHIN_WORKER_URL`, and public templates should **not** be
> published (the config format may still change). Tracked in DAH-1958; strategy wiring in
> DAH-2302.

## Build

```bash
cd templates/dolphin
docker buildx bake                     # daturaai/dolphin:0.0.1
VERSION=0.0.2 docker buildx bake       # daturaai/dolphin:0.0.2
```

## Run

```bash
docker run --rm --gpus all \
  -e DOLPHIN_API_KEY=dp-xxx \
  -e DOLPHIN_WORKER_URL=https://.../dolphinpod-worker \
  daturaai/dolphin:0.0.1
```
