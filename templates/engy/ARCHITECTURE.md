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
├── sglang engine  :8000  (GPU 0, --tp-size 1)  ←  engy_miner  worker <name>-g0
├── sglang engine  :8001  (GPU 1)               ←  engy_miner  worker <name>-g1
│   …one engine and one miner per card…
├── metrics sidecar :9101   /metrics + /logs, bearer token
└── supervisor (this script, PID 1)
```

## Why one engine per GPU, not one tensor-parallel engine

Measured on 2xH100, 2026-07-27: per-card engines served **564 tok/s** against **329 tok/s** for a
single `--tp-size 2` engine over the same cards. 1.72x, at better p99 TTFT. Tensor parallelism buys
nothing here because the model fits on one card, and it costs the interconnect on every token.

## Why one miner per engine

The image originally ran ONE miner driving every engine. That miner is a single Python process, and
it is the bottleneck, not the GPUs.

engy's protocol requires a TOPLOC proof with every answer, built from the model's hidden states. So
an 8192-token answer comes back as **~157MB of JSON** instead of ~30KB of text. Measured on a live
L40S: `json.loads` on one 78MB chunk takes **1.11s**, the numpy conversion another **0.22s** — about
**2.7s per request**, all of it holding the GIL. The same interpreter owns the gateway websockets and
must answer their keepalive pings.

On 2026-07-29 the capacity probe burst ~30 concurrent requests at one worker. 30 x 2.7s = ~81s of
serialised work against a 60s ping timeout. At **13:43:47 UTC** five legs closed with
`Close(code=1011, reason='keepalive ping timeout')`, the in-flight requests died with them, and engy
marked the worker `capacity_http`. It stayed unqualified for a day.

The GIL is per PROCESS. One miner per engine turns one serialised queue into N independent ones, so a
burst against any single worker only has to fit that worker's own budget. This is why the fix is more
miners rather than forking the miner to move parsing into a process pool: the fork costs a permanent
divergence from a file upstream edits weekly, and buys throughput nothing is asking for.

## Why the concurrency we declare is small

`ENGY_MAX_RUNNING_REQUESTS` (default **4**) is both sglang's `--max-running-requests` and what one
miner declares to the gateway as `MAX_INFLIGHT`. It used to be 8, and the whole node declared
8 x cards = 64.

Two facts decide the number. The gateway drives the **whole node** at about **4 concurrent** — 809
requests over 4h with `sglang:num_queue_reqs` sitting at zero on every engine — so per worker the
real demand is well under one. And the capacity probe's burst scales with what we declare, which is
the only thing that has ever knocked us offline.

So 4 per worker is already ~8x real demand, and it keeps a burst inside ~5-11s of GIL against the 60s
timeout. Declaring more buys share we are not being offered and risks the one failure that costs a
day. **Raise it when `sglang:num_queue_reqs` stops being zero, not before** — that counter is the
honest signal that the gateway wants more than we accept.

## Why worker ids are derived, not random

`engy_miner.py` mints `WORKER_ID = uuid4().hex` per PROCESS, and engy's control plane keys a worker
on that id. So every restart registered a **brand-new worker**, which enters `pending` at the back of
an onboarding queue that takes hours, and any qualification progress is thrown away.

Measured on prod: the same `ENGY_WORKER_NAME` `lium-1c36fd23…` came back as worker `a103ec01…` before
a restart and `0b7d4fe0…` after. A stable `ENGY_WORKER_NAME` does not help — the id is what counts,
despite the upstream comment claiming a repeat HELLO with the same (key, name) supersedes.

This is the single most expensive property of running engy on preemptible nodes, because we restart
often and for reasons that have nothing to do with engy. So the entrypoint derives the id from the
worker name (`sha256(name)[:32]`) and the vendored miner honours `ENGY_WORKER_ID`
(one-line LIUM PATCH, DAH-2531). A restart is then a re-dial, not a new worker.

Unverified, and worth asking engy directly: whether their control plane is happy with a stable id, or
whether it relies on the per-process uuid to tell a re-dial from a new process.

The same patch also scopes the miner's singleton lock to the worker. Upstream locks
`/tmp/engy_miner.singleton` node-wide, which is right for one miner per box and silently fatal for
one per card: the first miner takes the lock and every other prints "another instance is running"
and exits, leaving all but one GPU unmined with nothing in the log that looks like a failure.

## How we tell OUR stall from the gateway going quiet

Everything above about the GIL is a mechanism, not a verdict. It is measured — one 78MB reply costs
1.33s of GIL on a live L40S, and a bench of 14 GIL-seconds of concurrent parsing leaves an asyncio
loop unserviced for 13.7s, close to 1:1 — but the mechanism does not prove it caused any particular
outage. `Close(1011, 'keepalive ping timeout')` is emitted by OUR websocket client when it does not
see a pong in time, and that happens both when our loop is too busy to READ the pong and when the
gateway never SENT one. The log cannot tell those apart.

`loop_probe.py` settles it. Each miner runs a coroutine on its own event loop that expects to wake
every 250ms and records the overshoot: the loop's own delay is the measurement. The sidecar merges
the resulting files into `/metrics`. The decision rule:

- `engy_miner_loop_lag_seconds_max` near the 60s ping timeout, with
  `engy_miner_loop_lag_peak_inflight` above zero — it is us. Lower `TOPLOC_GEN_CHUNK` (smaller JSON
  per parse) or the declared concurrency.
- a leg dropping while the lag stayed flat — it is not us. Take it to engy with the timestamp.
- `engy_miner_loop_stall_samples_total{ge="60"}` is the one to alert on: past that threshold we are
  guaranteed to be dropping legs.

The in-flight count is read BEFORE each wait as well as after, and the larger is kept. Reading it
only on waking undercounts the exact case that matters: the miner drops a job from `_JOBS` on the
event loop, so a stall that ends with its requests complete would report an idle queue and read as
somebody else's fault. Caught by the test, not by review.

Each miner's file is keyed on its worker NAME, never on the worker id: upstream mints that id per
PROCESS, so a miner restarted inside a living container would write a second file while the first
stayed (the directory is only cleared at container start). Both carry the same `engy_worker` label,
Prometheus keeps one sample per label set, and which one it keeps is undefined — the dead miner's
frozen lag could win and the stall counter could appear to go backwards, breaking this diagnosis in
the one case (a flapping miner) it exists for.

The probe is off unless `ENGY_PROBE_DIR` is set, and it costs four wakeups a second and a 1KB file
every 10s.

## Why several workers under one MINER_KEY is fine, and what it costs

Supported by design: `MINER.md` says several machines share one key and each registers under its own
`ENGY_WORKER_NAME`. We already ran 10 workers on one key across 10 nodes.

The cost is that engy scores per **hotkey**, not per worker — the epoch API aggregates every worker's
requests into one acceptance number. One misbehaving worker drags the whole key's day down. That risk
already existed across nodes; running N workers inside one container does not add a new kind, only
more of the same.

## Why a wedged engine is restarted in place, not by ending the container

An engine can wedge inside a CUDA kernel: requests in flight, process alive, `/health` answering,
GPU at 100% utilisation drawing a third of its normal power. `templates/dolphin` measured twelve of
these on vLLM lasting 1.6 to 23.5 hours, invisible to every other check. The only honest signal is
the engine's own token counter going flat while requests are still running.

The old shape ended the whole container on any unhealthy engine and let the platform recreate it.
That is the wrong tool: recreation costs a cold start, and with per-process worker ids it also cost
every other card's qualification. The supervisor now kills the wedged engine (SIGKILL — a process
stuck in a kernel ignores TERM) along with its own miner, and starts both again on the next pass.
One dead card costs one card.

Three things are deliberately NOT treated as a wedge, all borrowed from dolphin's watchdog:

- an engine that never came up — a cold start legitimately produces nothing for tens of minutes, and
  killing it restarts the download;
- an idle queue — no demand is not a fault, and arming the stall clock while idle would spend the
  budget before the first request arrives;
- anything the supervisor cannot attribute to one engine. A wrong guess costs a healthy engine on top
  of the wedged one.

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
- `refuse_to_start` kills every child and waits for the pipe to drain, because closing our end is what
  lets it reach EOF.
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
labels its own samples and a bare `engine` key could collide.

The fan-out is concurrent under **one** shared deadline, not a per-target timeout and not a loop.
A per-target timeout makes 8 slow engines 40s sequentially, long past any scraper's patience; a
shared deadline walked in a loop is no better, because the first slow engine spends the whole budget
and every later one is skipped without a connection attempt. Both leave the tail engines silently
missing, which is the undercount the budget exists to prevent. Each future is also waited on against
the absolute deadline, so a body dripped one byte per read window — which satisfies every socket
timeout — cannot hold the scrape open.

`/metrics` answers 503 only when NOTHING answered: no engine and no miner probe. Prometheus discards
the whole body on a non-2xx, so gating the 503 on engines alone threw the loop-lag series away in
exactly the case they are most worth reading — every engine down, miners still reporting why.
`engy_sidecar_engines_reachable 0` carries the engine alert on its own.

## What we deliberately did not do

- **Fork the miner** to move parsing and proof building into worker processes. It fixes the GIL at the
  cost of permanent divergence from a file upstream changes weekly, and buys concurrency nothing is
  asking for. Revisit if `sglang:num_queue_reqs` stops being zero.
- **Auto-update the vendored miner.** It is pinned (currently upstream v0.4.4 plus the worker-id
  patch) because it must match the gateway protocol exactly, and because every image bump costs a
  restart. Watch upstream and update deliberately, in batches, when acceptance drops or a needed fix
  lands.
- **Ship logs to Loki.** The value is real but almost all of it is in Dolphin, which is 175 of the
  ~200 fillers in prod. Doing it for engy alone would be building infrastructure for one node.
