# engy — Bittensor SN53 inference worker (DAH-2495)

Runs an engy miner as a Lium-owned filler on idle nodes. Backend side: `FillerRunStrategy.ENGY`
(lium-io-backend #821).

## Shape

Two kinds of process, unlike Dolphin's single self-updating binary:

```
gateway (wss://api.engy.ai/gw)
        │  outbound websocket, no inbound port
   engy_miner.py  ──►  sglang engine :8000  (GPU 0)
                  ──►  sglang engine :8001  (GPU 1)
                  ──►  …                    (one per card)
```

**One engine per card, one miner per container.** Measured on 2xH100 (2026-07-27):

| shape | tok/s | TTFT p99 | failed |
|---|---|---|---|
| 1 engine, `--tp-size 2` | 329 | 15.3s | 0 |
| 2 engines, `--tp-size 1` | **564** | **8.7s** | 0 |

1.72x, and latency improves rather than degrades. The miner stays single because engy's acceptance
gate is per `(miner, model)`: a second miner needs its own registered SN53 hotkey, and one bad
worker zeroes the whole key for that day.

## Environment

| var | required | default | note |
|---|---|---|---|
| `MINER_KEY` | **yes** | — | gateway key from provider.engy.ai, bound to a registered SN53 hotkey |
| `GW` | no | `wss://api.engy.ai/gw` | gateway websocket |
| `MODEL` | no | `qwen3.6-35b-a3b` | the gateway's model id |
| `ENGY_MAX_RUNNING_REQUESTS` | no | `8` | per engine; the sum is declared to the gateway as `MAX_INFLIGHT` |
| `ENGY_WORKER_NAME` | no | hostname | must be unique per machine when several share one key |
| `METRICS_TOKEN` | no | — | when set, the sidecar is started on `:9101` |
| `ENGY_LOG_MAX_BYTES` | no | `268435456` | the on-disk log is head-trimmed back to half this size |

`ENGY_HOME` (default `/opt/engy`) is the shared cache volume: the ~35GB FP8 checkpoint is pulled
there once so a re-created container starts warm.

## Reading a container's log

The container's stdout goes to a docker pipe on the miner's host, and we never have host access, so
everything the entrypoint, the engines and the miner print is also written to
`$ENGY_HOME/logs/miner.log`. With `METRICS_TOKEN` set the sidecar serves it:

```
GET :9101/logs?tail=<bytes>    Authorization: Bearer $METRICS_TOKEN
```

`tail` defaults to 256KB and is capped at 8MB; the response always starts at a whole line. Same
token and port as `/metrics`.

Every line is stamped with the capture time (`ts` from moreutils), because the miner prints
without one and the log is read against engy's per-second dashboard:

```
2026-07-29T05:13:13+0000 [engy] 8 GPU(s) -> 8 engine(s), 8 running requests each
```

## Why this base image

Both pins were paid for on a live box, not guessed:

- **`-devel`, not `-runtime`** — sglang's DeepGEMM JIT-compiles FP8 kernels with `nvcc` during
  CUDA-graph capture, so the toolkit must be present at RUN time. A `-runtime` image dies with
  `NVCC compilation failed` seconds after the weights load.
- **ubuntu24.04 (gcc 13), not 22.04** — sglang 0.5.12's kernel sources fail to compile under gcc 12
  with a template-deduction error in `activation.cuh`. Same nvcc, same box; only the host compiler
  differs.

## Stop behaviour

SIGTERM is a **drop, not a drain**. The miner is killed first, which closes the gateway websocket
and stops routing within ~1 min; whatever is in flight is lost. That is deliberate: a customer
rental must not wait, the platform allows 30s, and a full drain of 262k-context requests can exceed
it. The loss is bounded by `MAX_INFLIGHT` against a 1%-of-day error budget.

## Restart behaviour

A dead engine **ends the container** rather than restarting in place: a re-created container mints a
new `worker_id` and re-enters probe qualification, which cost a full day on the pilot, so the
platform's own relaunch path owns that decision. A miner that merely dropped its websocket keeps the
same `worker_id` and is restarted in place.

## Vendored code

`vendor/engy_miner.py` and `vendor/sitecustomize.py` come from
[hanlinai/engy](https://github.com/hanlinai/engy) at **v0.4.4**. Upstream publishes no package and
the miner must match the gateway protocol exactly, so it is pinned here rather than fetched at boot.
Re-vendor by copying `miner/` from a newer tag and re-running the tests.

## Build

```bash
docker buildx bake --set default.args.VERSION=0.0.1
```
