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

1. Plans how many workers to run: **one worker per GPU** when the node has 2+ GPUs and every
   card individually clears the model's VRAM floor (`DOLPHIN_SPLIT_MIN_VRAM_MB`, default 70 GB);
   otherwise a single worker over all GPUs (DAH-2465, see below).
2. Renders one `worker.json` per worker from environment variables (per-worker `HOME` isolates
   the configs; model/runtime caches stay shared so weights live once on the volume).
3. Ensures the `dolphinpod-worker` binary is present (downloads it if missing).
4. Supervises all workers in a restart loop: a dead worker is restarted individually through
   `update` (serialized with `flock` so respawns never race on the binary).

The worker's own self-update exits expecting an external supervisor to restart it (systemd in
Dolphin's reference install); the loop plays that role, re-running `update` before every start
so the worker comes back on the freshly published binary. As a fallback, the loop polls the
download URL's etag every `DOLPHIN_UPDATE_CHECK_SECONDS` (default 3600) and gracefully restarts
all workers when a new binary appears — so long-lived containers pick up Dolphin rollouts within
about an hour even if the worker's self-update never fires (DAH-2457). `docker stop` still ends
the workers cleanly: SIGTERM is forwarded and the container exits.

## Environment variables

| Variable              | Required | Default                          | Notes |
|-----------------------|----------|----------------------------------|-------|
| `DOLPHIN_API_KEY`     | yes      | —                                | `dp-...` key from v2.dphn.ai. Inject as a secret. |
| `DOLPHIN_MODEL`       | no       | `nvidia/Qwen3.6-35B-A3B-NVFP4`   | Model to serve. |
| `DOLPHIN_WORKER_TYPE` | no       | `text-v`                         | Worker type. |
| `DOLPHIN_GPU_IDS`     | no       | (empty → auto)                   | Comma-separated GPU indices, e.g. `0,1`. When set, exactly ONE worker runs pinned to these GPUs (disables the per-GPU split). Empty → auto: split per GPU when eligible, else one worker over all GPUs. |
| `DOLPHIN_WORKER_URL`  | no       | `https://updates.dphn.ai/dolphinpod-worker-v2_linux_amd64` | Worker-binary download URL (stable, public). Override only if Dolphin moves it. |
| `DOLPHIN_UPDATE_CHECK_SECONDS` | no | `3600`                    | How often to poll `DOLPHIN_WORKER_URL` for a new binary while the worker runs. |
| `DOLPHIN_WORKER_PER_GPU` | no    | `1`                              | `1` → spawn one worker per GPU on eligible multi-GPU nodes. Anything else → always a single worker over all GPUs (pre-0.0.4 behavior). |
| `DOLPHIN_SPLIT_MIN_VRAM_MB` | no | `71680`                          | Per-GPU VRAM floor (MB) for the split: every card must individually fit the model (70 GB, dphn.ai docs), otherwise the node keeps the single all-GPUs worker. |
| `DOLPHIN_SPLIT_STAGGER_SECONDS` | no | `30`                        | Delay between initial worker spawns so the first instance warms the shared model cache. |

The worker authenticates with `DOLPHIN_API_KEY` alone (no per-node bootstrap needed — verified
live), so one key drives the whole fleet. `worker.json` is written `0600`; the worker refuses a
config with secrets that is readable beyond its owner.

## Architecture

**linux/amd64 only** — the `dolphinpod-worker` binary has no arm64 build, so the image is pinned to
`linux/amd64`. ARM GPU hosts (NVIDIA Grace, GH200/GB200) can't run it; every current Lium executor
is x86_64.

## GPU selection & eligibility

Left alone, a single worker **auto-scales to every GPU on the node** (`gpu_ids: null`) by
tensor-sharding the model — and wastes most of the VRAM on big multi-GPU boxes: measured on prod,
an 8x RTX PRO 6000 single worker reports 317 slots at ~13% VRAM per GPU, while a 1x worker
reports 72 slots at ~70% VRAM (DAH-2465). Since 0.0.4 the entrypoint therefore spawns **one
worker per GPU** whenever the node has 2+ GPUs and each card individually clears
`DOLPHIN_SPLIT_MIN_VRAM_MB`; nodes whose cards can't fit the model alone (L40S, RTX 5090, ...)
keep the single all-GPUs worker.

**Which nodes are eligible at all** — the 70 GB VRAM floor (summed across the node's GPUs; Dolphin's stated
requirement, dphn.ai docs) and the A100 exclusion (Ampere, can't boot NVFP4) — is decided by
the **scheduler**, not this image: see the DPHN strategy gate in `lium-io-backend`
([PR #748](https://github.com/Datura-ai/lium-io-backend/pull/748)).

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
docker buildx bake                     # daturaai/dolphin:0.0.3
VERSION=0.0.4 docker buildx bake       # override the tag
```

## Run

```bash
docker run --rm --gpus all \
  -e DOLPHIN_API_KEY=dp-xxx \
  -e DOLPHIN_WORKER_URL=https://.../dolphinpod-worker \
  daturaai/dolphin:0.0.1
```
