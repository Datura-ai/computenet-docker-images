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

Two side processes get their own restart loops next to it, so neither can take the worker
down with it: the metrics sidecar and the engine watchdog (both below).

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
| `DOLPHIN_WATCHDOG_ENABLED` | no  | `1`                              | `0` stops the entrypoint from starting the engine watchdog. |
| `DOLPHIN_WATCHDOG_STALL_SECONDS` | no | `300`                  | How long the token counter may stand still, with requests in flight, before the engine is restarted. |
| `DOLPHIN_WATCHDOG_POLL_SECONDS` | no | `60`                    | How often the watchdog reads the engine's counters. |
| `DOLPHIN_WATCHDOG_GRACE_SECONDS` | no | `300`                  | Quiet period after a restart, while the engine reloads weights. |
| `DOLPHIN_WATCHDOG_ENGINE_CORE_SECONDS` | no | `20`             | How long the `VLLM::EngineCore` child gets to die with its parent before it is killed directly. |
| `DOLPHIN_WATCHDOG_STATE` | no | `${DOLPHIN_HOME}/watchdog_state.json` | Where the watchdog writes its state. The sidecar reads the same path to export the series below, so both processes must agree on it. |

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

## Engine watchdog

`watchdog.py` (stdlib python, its own restart loop in `entrypoint.sh`) restarts a vLLM
engine that has wedged inside a CUDA kernel. Under load the engine stops making progress
while everything that normally reads as health still looks fine: the container runs with
zero restarts, the worker stays connected, vLLM's API answers `/health` in milliseconds,
and the GPU reports 100% utilization at about a third of its normal power draw — full
occupancy with no memory traffic is a spinning kernel, not inference. Measured 2026-07-23:
twelve engines stuck between 1.6 and 23.5 hours, none of them visible to any existing
check.

The only honest signal is vLLM's own `generation_tokens_total`: it stops moving while
`num_requests_running` stays above zero. The watchdog polls that over the same unix socket
the sidecar proxies, and after `DOLPHIN_WATCHDOG_STALL_SECONDS` of no tokens with
requests in flight it kills `vllm serve` — SIGKILL, because a wedged process ignores
SIGTERM — then kills the
`VLLM::EngineCore` child, which outlived its parent in 12 of 12 production cases while
holding ~70 GB of VRAM that blocks the respawn. The worker brings the engine back from the
warm cache and tokens return 2-3 minutes after the kill; the container and its `filler_run`
row are untouched, so there is no cold start and no launch backoff.

Three cases are deliberately left alone: no socket at all (a cold start legitimately takes
30-60 minutes, and a restart would only send it back to the beginning), an empty queue (no
demand is not a fault, and idle time never arms the stall clock — the first request after
a quiet stretch gets the full window), and more than one engine in the container — the
counters belong to
whichever engine answered first, so there is no way to tell which one wedged, and the
watchdog refuses rather than take the healthy ones down with it.

Restarts reach the platform through the sidecar, which appends the watchdog's state to
`/metrics`:

| Series | Meaning |
|---|---|
| `dolphin_watchdog_up` | `0` when the watchdog stopped ticking — a dead watchdog must not look like a healthy one |
| `dolphin_watchdog_restarts_total` | Engine restarts since the container was created — the count survives the watchdog's own restart, and only a kill that actually removed the process is counted |
| `dolphin_watchdog_last_restart_timestamp` | Unix time of the last restart |
| `dolphin_watchdog_stall_seconds` | How long the token counter has been standing still with requests in flight (an idle queue holds it at zero) |

The series are absent entirely until a watchdog has written its state file even once, so
zeros never claim a watchdog that was never installed. Once the file exists the series stay,
and a watchdog that ran and died reports `dolphin_watchdog_up 0` with its last known
numbers — silence would read as health.

Tests (no GPU needed):

```bash
python3 tests/test_sidecar.py            # host run against the repo copy
python3 tests/test_watchdog.py           # same; the kill tests need /proc and SKIP on macOS
tests/run_in_image.sh daturaai/dolphin:0.0.9   # both suites inside the image + docker-stop cleanliness
```

## Build

```bash
cd templates/dolphin
docker buildx bake                     # daturaai/dolphin:0.0.9
VERSION=0.0.10 docker buildx bake      # override the tag
```

## Run

```bash
docker run --rm --gpus all \
  -e DOLPHIN_API_KEY=dp-xxx \
  -e DOLPHIN_WORKER_URL=https://.../dolphinpod-worker \
  daturaai/dolphin:0.0.1
```
