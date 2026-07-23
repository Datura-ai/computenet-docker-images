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
3. Supervises `dolphinpod-worker update && dolphinpod-worker start` in a restart loop.

The worker's own self-update exits expecting an external supervisor to restart it (systemd in
Dolphin's reference install); the loop plays that role, re-running `update` before every start
so the worker comes back on the freshly published binary. As a fallback, the loop polls the
download URL's etag every `DOLPHIN_UPDATE_CHECK_SECONDS` (default 3600) and gracefully restarts
the worker when a new binary appears — so long-lived containers pick up Dolphin rollouts within
about an hour even if the worker's self-update never fires (DAH-2457). `docker stop` still ends
the worker cleanly: SIGTERM is forwarded and the container exits.

## Environment variables

| Variable              | Required | Default                          | Notes |
|-----------------------|----------|----------------------------------|-------|
| `DOLPHIN_API_KEY`     | yes      | —                                | `dp-...` key from v2.dphn.ai. Inject as a secret. |
| `DOLPHIN_MODEL`       | no       | `nvidia/Qwen3.6-35B-A3B-NVFP4`   | Model to serve. |
| `DOLPHIN_WORKER_TYPE` | no       | `text-v`                         | Worker type. |
| `DOLPHIN_GPU_IDS`     | no       | (empty → `null`)                 | Comma-separated GPU indices, e.g. `0,1`. Empty → `null` → the worker uses all GPUs on the node. |
| `DOLPHIN_WORKER_URL`  | no       | `https://updates.dphn.ai/dolphinpod-worker-v2_linux_amd64` | Worker-binary download URL (stable, public). Override only if Dolphin moves it. |
| `DOLPHIN_UPDATE_CHECK_SECONDS` | no | `3600`                    | How often to poll `DOLPHIN_WORKER_URL` for a new binary while the worker runs. |
| `METRICS_TOKEN`       | no       | —                                | Bearer token for the metrics sidecar on `:9101`. Unset → the sidecar answers 503 to everything (fail closed). |

The worker authenticates with `DOLPHIN_API_KEY` alone (no per-node bootstrap needed — verified
live), so one key drives the whole fleet. `worker.json` is written `0600`; the worker refuses a
config with secrets that is readable beyond its owner.

## Architecture

**linux/amd64 only** — the `dolphinpod-worker` binary has no arm64 build, so the image is pinned to
`linux/amd64`. ARM GPU hosts (NVIDIA Grace, GH200/GB200) can't run it; every current Lium executor
is x86_64.

## GPU selection & eligibility

The worker **auto-scales to every GPU on the node** (`gpu_ids: null`), so this image does not
pick a GPU count. On a Lium executor the filler already gets all the node's free GPUs.

**Which nodes are eligible** — the 70 GB VRAM floor (summed across the node's GPUs; Dolphin's stated
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

## Metrics sidecar (DAH-2468)

`metrics_sidecar.py` (stdlib python, supervised by `entrypoint.sh` in its own
restart loop) proxies the vLLM engine's unix-socket `/metrics` onto `:9101` so
the platform's published-port machinery can expose per-machine token counters
to the lium-stats scraper. Verbatim Prometheus pass-through plus appended
`dolphin_sidecar_*` series (`dolphin_sidecar_proxy_ok` tells a dead engine
apart from a schema change). Auth: `Authorization: Bearer $METRICS_TOKEN`,
fail-closed. The engine being down does NOT fail the endpoint — it answers 200
with sidecar series only, which is exactly the scraper's liveness signal.

Tests (no GPU needed):

```bash
python3 tests/test_sidecar.py            # host run against the repo copy
tests/run_in_image.sh daturaai/dolphin:0.0.6   # same tests inside the image + docker-stop cleanliness
```

## Build

```bash
cd templates/dolphin
docker buildx bake                     # daturaai/dolphin:0.0.6
VERSION=0.0.6 docker buildx bake       # override the tag
```

## Run

```bash
docker run --rm --gpus all \
  -e DOLPHIN_API_KEY=dp-xxx \
  -e DOLPHIN_WORKER_URL=https://.../dolphinpod-worker \
  daturaai/dolphin:0.0.1
```
