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
| `DOLPHIN_GPU_IDS`     | no       | (empty → `null`)                 | Comma-separated GPU indices, e.g. `0,1`. Empty → `null` → the worker uses all GPUs on the node. |
| `DOLPHIN_WORKER_URL`  | no*      | —                                | URL to fetch the worker binary when it is not baked into the image. |

\* Required until an official published binary URL / image exists — see below.

## GPU selection & eligibility

The worker **auto-scales to every GPU on the node** (`gpu_ids: null`), so this image does not
pick a GPU count. On a Lium executor the filler already gets all the node's free GPUs.

**Which nodes are eligible** — the 70 GB VRAM floor and the A100 exclusion (A100 clears the VRAM
floor but cannot boot NVFP4) — is decided by the **scheduler**, not this image: see the DPHN
strategy gate in `lium-io-backend` ([PR #748](https://github.com/Datura-ai/lium-io-backend/pull/748)).

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
