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

1. Plans how many worker instances the node should run (see **Worker split** below).
2. Renders one `worker.json` per instance from environment variables.
3. Ensures the `dolphinpod-worker` binary is present (downloads it if missing).
4. Supervises `dolphinpod-worker update && dolphinpod-worker start` for every instance, each
   restartable on its own.

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
| `DOLPHIN_WORKER_PER_GPU` | no    | `1`                              | `0` forces the single all-GPUs worker — the exact pre-split behavior. |
| `DOLPHIN_WORKERS_PER_BUNDLE` | no | `1`                             | Workers on the **same** bundle — the intra-card split below. `1` is off; `auto` derives the count from the bundle's VRAM; an explicit integer forces it. Anything else falls back to `1`. |
| `DOLPHIN_SPLIT_MIN_VRAM_MB` | no | `71680`                        | VRAM floor one worker's bundle must clear (the full model needs ~70 GB). Each worker gets the smallest card group above it. |
| `DOLPHIN_SPLIT_STAGGER_SECONDS` | no | `30`                      | Delay between initial worker spawns, once the shared cache is seeded. |
| `DOLPHIN_SEED_WAIT_SECONDS` | no | `5400`                         | How long the second instance waits for the first one's engine socket before starting anyway, so the runtime and the weights are downloaded once instead of N times. `0` = no wait, plain stagger. |
| `METRICS_TOKEN`       | no       | —                                | Bearer token for the metrics sidecar on `:9101`. Unset → the sidecar answers 503 to everything (fail closed). |
| `DOLPHIN_ENGINES_EXPECTED` | no  | (set by the entrypoint)          | How many engines this container runs. The sidecar publishes it next to `dolphin_engines_up`, and above 1 it tags every engine's series with `dolphin_engine`. |
| `DOLPHIN_WATCHDOG_ENABLED` | no  | `1`                              | `0` stops the entrypoint from starting any engine watchdog. |
| `DOLPHIN_WATCHDOG_GPU_SET` | no | (set per bundle by the entrypoint) | Cards this watchdog owns, e.g. `0` or `2,3`. Empty = the single-engine container, where every vLLM process belongs to the one engine. |
| `DOLPHIN_WATCHDOG_STALL_SECONDS` | no | `300`                  | How long the token counter may stand still, with requests in flight, before the engine is restarted. |
| `DOLPHIN_WATCHDOG_POLL_SECONDS` | no | `60`                    | How often the watchdog reads the engine's counters. |
| `DOLPHIN_WATCHDOG_GRACE_SECONDS` | no | `300`                  | Quiet period after a restart, while the engine reloads weights. |
| `DOLPHIN_WATCHDOG_ENGINE_CORE_SECONDS` | no | `20`             | How long the `VLLM::EngineCore` child gets to die with its parent before it is killed directly. |
| `DOLPHIN_WATCHDOG_STATE` | no | `/tmp/dolphin_watchdog_state.json` | Where one watchdog writes its state; the entrypoint names one file per bundle in split mode. Keep it OFF `DOLPHIN_HOME`: that is a cache volume shared by every filler container on the node, and one state file per node would mix the counters of every watchdog on it. |
| `DOLPHIN_WATCHDOG_STATE_DIR` | no | `/tmp` | Directory the entrypoint names those files in, one per bundle. |
| `DOLPHIN_WATCHDOG_STATE_GLOB` | no | `/tmp/dolphin_watchdog_state*.json` | Where the sidecar looks for those files, so it exports the series below for every bundle. It must match the names the entrypoint hands out. |

The worker authenticates with `DOLPHIN_API_KEY` alone (no per-node bootstrap needed — verified
live), so one key drives the whole fleet. `worker.json` is written `0600`; the worker refuses a
config with secrets that is readable beyond its owner.

## Architecture

**linux/amd64 only** — the `dolphinpod-worker` binary has no arm64 build, so the image is pinned to
`linux/amd64`. ARM GPU hosts (NVIDIA Grace, GH200/GB200) can't run it; every current Lium executor
is x86_64.

## Worker split (DAH-2465)

On a multi-GPU node the entrypoint runs **one worker per minimal VRAM bundle** instead of one
worker tensor-sharded over every card.

Every worker instance loads the **full** model, so sharding one worker across many cards spends
VRAM on duplicate weights that would otherwise be KV cache — and slots (the concurrent batch
Dolphin pays for) scale with KV cache. Measured on prod: an 8x RTX PRO 6000 single worker
reports 317 slots at ~13% VRAM per GPU, while a 1x worker on the same card reports 72 slots at
~70%. More workers recover the lost concurrency.

The plan gives each worker the smallest card group that clears the 70 GB floor:

| node | bundles | workers |
|---|---|---|
| 8x 96 GB (RTX PRO 6000) | one card each | 8 |
| 8x 48 GB (L40S) | pairs | 4 |
| 8x 32 GB (RTX 5090) | quads | 2 |
| 2x 48 GB | one bundle = whole node | 1 (all-GPUs worker) |
| 1 GPU, mixed VRAM below the floor, or `nvidia-smi` failure | — | 1 (all-GPUs worker) |

Escape hatches: `DOLPHIN_GPU_IDS` (explicit pinning) and `DOLPHIN_WORKER_PER_GPU=0` both force
the single all-GPUs worker, which is the exact pre-split behavior.

What running N instances in one container costs, and how each cost is paid:

| cost | how it is handled |
|---|---|
| configs collide | per-instance `HOME`, so each worker reads its own `worker.json` |
| N copies of the ~35 GB model + runtime | each instance's `HOME/.cache` is a **symlink** to the shared cache. The closed worker binary scrubs its child's environment, so `HF_HOME`/`XDG_CACHE_HOME` alone cannot be relied on — a path that resolves to one directory can. |
| siblings corrupt the shared binary | every write to `DOLPHIN_HOME` goes through `flock`, staged to a temp file and renamed atomically (DAH-2475) |
| cold start stampede | the siblings wait for the first instance's engine socket (`DOLPHIN_SEED_WAIT_SECONDS`, default 5400) instead of merely pausing: once it serves, the runtime and the weights are on disk, so 2..N start warm. Measured 2026-07-23 — with a plain 30 s stagger both workers downloaded the same ~12 GB side by side over a link the miner throttles. `DOLPHIN_SPLIT_STAGGER_SECONDS` (default 30) then spaces the warm starts. |
| metrics undercount | the sidecar scrapes **every** engine socket and tags each with its own `dolphin_engine` label (see below) |
| one wedge kills all | one watchdog per bundle, each scoped to its own cards, so a wedged engine is killed on its cards alone and the siblings keep serving (see below) |

## Intra-card split (DAH-2473)

The split above gives each worker its own cards. `DOLPHIN_WORKERS_PER_BUNDLE` goes one step
further and runs **several workers on the same bundle**, because on a big card the limit is not
the card but Dolphin's per-worker quota of 100 concurrent requests: prod KV-cache use is 6.1%
on H200, 0.7% on B300. Measured on a 1x H200 under live traffic, two workers moved 1.79x the
tokens of one — ~90% of a full worker each, ~$21k/month across the 70 prod H200.

`auto` derives the count per bundle, since a fleet constant would cripple smaller cards:
split only if the bundle is **one** card and each worker still gets weights plus real KV cache
out of the vendor's 0.85 usable — `floor(vram * 0.85 / (32256 + 25600 MB))`. That gives H200 2,
B200 2, B300 4, H100 80 GB 1, RTX PRO 6000 96 GB 1, and any multi-card bundle 1.

vLLM sizes `--gpu-memory-utilization 0.85` against the **whole** card, so worker 2 would die at
init. The engine is an ordinary pip console script inside `DOLPHIN_HOME`, so the entrypoint
copies it to `vllm.real` and writes a wrapper that divides that one flag by the worker count.
A cold node has no runtime to wrap yet and runs a single worker until the cache is warm.
Turning the split back off restores the vendor script — `DOLPHIN_HOME` outlives the container,
and a leftover wrapper would leave a lone worker silently claiming 1/N of the card.

The default is `1`, and it stays `1` until the watchdog is re-keyed off the engine socket
instead of the card set: two workers on one card produce two engines with identical card sets,
which is the ambiguous case the watchdog refuses to act on, so a wedge on a split card stays
wedged.

## GPU selection & eligibility

Within a bundle the worker auto-scales to the cards it was given; with a single bundle it takes
every GPU on the node (`gpu_ids: null`). On a Lium executor the filler already gets all the
node's free GPUs.

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
demand is not a fault, and idle time never arms the stall clock — the first request after a
quiet stretch gets the full window), and any engine the watchdog cannot prove is its own —
an ambiguous match kills nothing, because a wrong guess costs a healthy bundle.

### One watchdog per bundle

In split mode a container holds N engines, and killing every `vllm serve` in it would turn
one wedge into N. So the entrypoint starts **one watchdog per bundle**, each given its cards
in `DOLPHIN_WATCHDOG_GPU_SET`, and each acts on that bundle alone:

- it finds its engine by matching `CUDA_VISIBLE_DEVICES` in `/proc/<pid>/environ` against its
  own cards, then reads the socket off the `vllm serve --uds <socket>` command line — the same
  socket the sidecar scrapes. Both facts were measured on live engines.
- it polls **only that socket**, so a sibling's frozen counter is not its wedge and a
  sibling's healthy one cannot mask its own.
- it SIGKILLs **only that engine's** processes: its `vllm serve` and the `VLLM::EngineCore`
  children claimed either by the same cards or by the parent link.
- when two engines claim the same cards the match is ambiguous, and it then kills **nothing**
  and publishes `dolphin_watchdog_engine_found 0`. A wrong guess would cost a healthy bundle,
  so refusing is the only safe answer.

A single-instance container gets the unscoped watchdog and the original state path, so the
single-worker fleet keeps exactly the behavior it runs today.

Restarts reach the platform through the sidecar, which appends every watchdog's state to
`/metrics` (labelled `dolphin_watchdog_gpus="<cards>"` in split mode, unlabelled with one
engine):

| Series | Meaning |
|---|---|
| `dolphin_watchdog_up` | `0` when the watchdog stopped ticking — a dead watchdog must not look like a healthy one |
| `dolphin_watchdog_restarts_total` | Engine restarts since the container was created — the count survives the watchdog's own restart, and only a kill that actually removed the process is counted |
| `dolphin_watchdog_last_restart_timestamp` | Unix time of the last restart |
| `dolphin_watchdog_stall_seconds` | How long the token counter has been standing still with requests in flight (an idle queue holds it at zero) |
| `dolphin_watchdog_engine_found` | Split mode only: `0` when the watchdog cannot identify its engine, i.e. it is running and guarding nothing |

The series are absent entirely until a watchdog has written its state file even once, so
zeros never claim a watchdog that was never installed. Once the file exists the series stay,
and a watchdog that ran and died reports `dolphin_watchdog_up 0` with its last known
numbers — silence would read as health.

Tests (no GPU needed):

```bash
python3 tests/test_sidecar.py            # host run against the repo copy
python3 tests/test_watchdog.py           # same; the kill tests need /proc and SKIP on macOS
tests/run_in_image.sh daturaai/dolphin:0.0.11  # both suites inside the image + docker-stop cleanliness
```

## Build

```bash
cd templates/dolphin
docker buildx bake                     # daturaai/dolphin:0.0.11
VERSION=0.0.11 docker buildx bake      # override the tag
```

## Run

```bash
docker run --rm --gpus all \
  -e DOLPHIN_API_KEY=dp-xxx \
  -e DOLPHIN_WORKER_URL=https://.../dolphinpod-worker \
  daturaai/dolphin:0.0.1
```
