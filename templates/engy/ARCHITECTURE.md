# engy filler — why it is built this way

This image runs a Bittensor SN53 (engy) inference miner on a Lium filler node. Every decision below
was paid for on a real box; the measurements are kept so nobody has to re-learn them. Read this
before changing `entrypoint.sh`.

The one sentence that explains most of the design: **engy expects a long-lived, stable miner, and a
Lium filler is preemptible.** A customer rental, a Dolphin preemption or an image roll can stop this
container at any minute, and everything below is about making that cheap instead of ruinous.

## The shape

```
container
├── sglang engine  :8000  (GPU 0, --tp-size 1)  ┐
├── sglang engine  :8001  (GPU 1)               ├─  one engy_miner drives all of them
│   …one engine per card…                       ┘
├── metrics sidecar :9101   /metrics + /logs, bearer token
└── entrypoint.sh (PID 1)
```

## Why one engine per GPU, not one tensor-parallel engine

Measured on 2xH100, 2026-07-27: per-card engines served **564 tok/s** against **329 tok/s** for a
single `--tp-size 2` engine over the same cards. 1.72x, at better p99 TTFT. Tensor parallelism buys
nothing here because the model fits on one card, and it costs the interconnect on every token.

## What one request actually costs us

engy's protocol requires a TOPLOC proof with every answer, built from the model's hidden states. So
an 8192-token answer comes back as **~157MB of JSON** instead of ~30KB of text.

Measured on a live L40S: `json.loads` on one 78MB chunk takes **1.11s** and the numpy conversion
another **0.22s**, so about **1.33s per chunk**. With `TOPLOC_GEN_CHUNK` at its default 4096 an
8192-token answer is two chunks, roughly **2.7s per request** — and every bit of it holds the GIL.

That matters because the miner is a single Python process. The same interpreter owns the gateway
websockets and must answer their keepalive pings: the client is opened with `ping_interval=15,
ping_timeout=60` (`vendor/engy_miner.py`), so if the event loop goes unserviced for more than a
minute it tears its own leg down.

A bench with no GPU and no gateway (synthesised replies of the same shape, an asyncio ticker that
should wake every 100ms) puts a number on it. At **14.3 GIL-seconds** of concurrent parsing:

| how the parsing runs            | worst gap in the loop | wall  |
|---------------------------------|-----------------------|-------|
| threads (what ships today)      | 13.7s                 | 17.8s |
| the same work in 16 small docs  | 0.9s                  | 13.2s |
| processes                       | 0.3s                  | 3.2s  |

The gap tracks GIL-seconds almost 1:1. On 2026-07-29 at **13:43:47 UTC** five legs closed with
`Close(code=1011, reason='keepalive ping timeout')` during a burst of roughly 30 concurrent
requests, the in-flight requests died with them, and engy marked the worker `capacity_http`. It
stayed unqualified for a day.

## Why that is still a hypothesis, and what settles it

`Close(1011, 'keepalive ping timeout')` is emitted by OUR websocket client when it does not see a
pong in time. That happens both when our loop is too busy to READ the pong and when the gateway
never SENT one — the same line in the log either way, and nobody captured the miner's CPU at
13:43:47. So the mechanism above is measured; its role in that particular outage is not.

`loop_probe.py` settles it. Each miner runs a coroutine on its own event loop that expects to wake
every 250ms and records the overshoot: the loop's own delay IS the measurement. The files are
merged into `/metrics` by the sidecar, so nothing here needs a port of its own. Reading it:

- `engy_miner_loop_lag_seconds_max` near the 60s ping timeout, with
  `engy_miner_loop_lag_peak_inflight` above zero — it is us. Lower `TOPLOC_GEN_CHUNK` (smaller JSON
  per parse) or the declared concurrency.
- a leg dropping while the lag stayed flat — it is not us. Take the timestamp to engy.
- `engy_miner_loop_stall_samples_total{ge="60"}` is the one to alert on: past that threshold we are
  guaranteed to be dropping legs.

The in-flight count is read BEFORE each wait as well as after, and the larger is kept. Reading it
only on waking undercounts the exact case that matters: the miner drops a job from `_JOBS` on the
event loop, so a stall that ends with its requests complete would report an idle queue and read as
somebody else's fault. Caught by the test, not by review.

The probe is off unless `ENGY_PROBE_DIR` is set, and it costs four wakeups a second and a 1KB file
every 10s.

## Why the whole container's output is captured, and stamped

On a miner's host the container's stdout goes to a docker pipe we have no access to, and we never get
host access. That output is the only record of why a routed request failed. It is tee'd to
`$ENGY_HOME/logs/miner.log` and served by the sidecar at `/logs?tail=N`, behind the same bearer token
and the same already-published port as `/metrics`.

Details that are load-bearing, each one learned by breaking it:

- The redirect happens **before the first validation**, because a container that refuses to start is
  exactly the one whose reason is otherwise unreachable.
- `stdbuf -oL` in front of `ts`: `ts` block-buffers into a pipe and bash does not wait for a process
  substitution on exit, so an early `exit` used to drop the refusal entirely.
- The trim is a **head-trim in place** (`cat >`), never a rename: renaming leaves `tee` appending to
  an unlinked file, and the log looks alive while being dead.
- Timestamps exist because the miner prints without them and the log is read against engy's
  per-second dashboard.

## Why the sidecar merges engine bodies instead of concatenating them

Prometheus rejects a second `# HELP` for a metric name. Concatenating N engines' bodies repeats every
HELP/TYPE once per engine and interleaves families, so on **any multi-GPU node the whole scrape was
invalid** — not one series. Measured on the 8-card prod node: 499 HELP lines for 65 families.

`merge_engine_bodies` regroups samples so each family's comments and all of its samples stay
contiguous, and every sample carries `engy_engine="<port>"`. The label is namespaced because sglang
labels its own samples and a bare `engine` key could collide. The miners' probe files go through the
same merge, which is why two miners cannot produce a second HELP line between them.

The fan-out shares **one** deadline across all engines rather than a per-target timeout: 8 slow
engines at 5s each is 40s sequentially, long past any scraper's patience, and the tail engines would
silently vanish — the exact undercount the fan-out exists to prevent.

## What we deliberately did not do

- **Fork the miner** to move parsing and proof building into worker processes. It fixes the GIL at the
  cost of permanent divergence from a file upstream changes weekly. Revisit once the probe says the
  loop actually stalls in production.
- **Auto-update the vendored miner.** It is pinned (currently upstream v0.4.4) because it must match
  the gateway protocol exactly, and because every image bump costs a restart. Watch upstream and
  update deliberately, in batches, when acceptance drops or a needed fix lands.
- **Ship logs to Loki.** The value is real but almost all of it is in Dolphin, which is 175 of the
  ~200 fillers in prod. Doing it for engy alone would be building infrastructure for one node.
