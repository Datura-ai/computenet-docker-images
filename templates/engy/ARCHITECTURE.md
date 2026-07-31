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

Because that is what the network does, and because it shrinks the blast radius of a bad minute.

Surveyed on 2026-07-30 from `GET /v1/network`: **635 workers under 62 miner keys**. The dominant
shape is many workers per key, one per card — **354 of 635 workers report exactly one visible GPU**,
and the largest keys run 74, 53 and 52 workers each. Several name their workers `<host>-8001`,
`<host>-8002`, one per engine port, which is exactly this file's layout. A single worker fronting
eight cards, which is what this image used to ship, is a shape almost nobody else runs.

The operational argument is the capacity probe. engy probes a WORKER, and a worker that fails a
probe is out until someone re-onboards it. With one worker per node a bad probe costs all eight
cards; with one worker per card it costs one, and the other seven keep earning through it.

It is NOT about the GIL. That was the working theory for a day and it is disproven — see "What the
GIL turned out not to explain" below.

## Why every miner declares exactly 8

`ENGY_MAX_RUNNING_REQUESTS` (default **8**) is both sglang's `--max-running-requests` and what one
miner declares to the gateway as `MAX_INFLIGHT`. **8 is a floor, not a tuning choice.**

The miner derives its gateway connection count from this number (`_leg_plan`): when `MAX_INFLIGHT`
is below the gateway's worker count it opens that many connections instead, one inflight each. The
gateway runs 8 workers, and a worker holding fewer than 8 connections is refused before it ever
serves anything — the portal says so in as many words: *"Qualification and sampling only target
workers with all 8 legs live, so it will receive no test traffic — and cannot be onboarded — until
every leg connects."*

Measured by running this image at 4 on a rented H100 (2026-07-30): the worker connected, opened four
connections, and was failed in three seconds with `offered 4 distinct clean legs, below the required
8`. Zero requests, ever. **Never set this below 8.** The entrypoint no longer lets anyone: a lower
override is logged and raised back to 8, because a knob whose wrong value silently earns nothing is
a trap, not a setting.

Above 8 buys nothing either. Same box, same day: declaring 8 drew a burst of 8 concurrent; declaring
**64 drew the same burst of 8**. The number we declare is an admission ticket, not a throttle — the
gateway sends what it wants to send. Prod, meanwhile, sat at 2 concurrent across all eight engines
over a 7-minute sample. 481 of the network's 635 workers declare 8; only 7 declare 64, and until
this change we were one of them.

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

Verified live on 2026-07-30: worker `04955ec4…` was restarted mid-`active` and came back as the SAME
worker — no new `pending`, no re-onboarding, the request history intact. A restart really is a
re-dial. (The portal's worker page shows the reconnect as a new "this leg connected" timestamp on
the same worker, with the event log unchanged.)

The same patch also scopes the miner's singleton lock to the worker. Upstream locks
`/tmp/engy_miner.singleton` node-wide, which is right for one miner per box and silently fatal for
one per card: the first miner takes the lock and every other prints "another instance is running"
and exits, leaving all but one GPU unmined with nothing in the log that looks like a failure.

## What the GIL turned out not to explain

Keep this section. It is the most expensive thing we learned, and the theory it kills is a plausible
one that will occur to the next reader within five minutes of seeing the payload sizes.

The mechanism is real. A TOPLOC proof ships the model's hidden states, so an 8192-token answer comes
back as ~157MB of JSON instead of ~30KB of text; `json.loads` plus the numpy conversion on one chunk
costs **1.33s on an L40S and 2.32s on the prod H200 box**, all of it holding the GIL, in the same
interpreter that answers the gateway's keepalive. It is the obvious suspect for the 2026-07-29
outage, when five connections closed at 13:43:47 UTC with `Close(1011, 'keepalive ping timeout')` and
engy marked the worker `capacity_http`.

It is not what happened. Three measurements, 2026-07-30:

- **Full-path replay on a real engine** (`_process` itself: chunked generation, parses, proof build,
  decode), eight concurrent 16384-token requests — the shape prod was in. Worst event-loop gap
  **3.4s** against the 60s budget. Our code cannot manufacture a 60-second silence.
- **Live probe during two real capacity bursts**, declaring 8 and then 64: worst lag **0.695s** and
  **0.935s**, zero disconnects, 570 requests at 100%.
- **Prod log forensics.** The engines wrote a log line every single second straight through the
  "silent" minute, so the host was alive and scheduling. Meanwhile the connections died in
  synchronized groups — 13:02 x7, 13:13 x7, 13:17 x5, 13:22 x3, 13:29 x3, 13:43 x5 UTC, each group
  inside the same second, 60 keepalive timeouts plus 10 bare TCP resets. That is a 40-minute network
  storm between the miner host and `api.engy.ai`, not a busy interpreter — a GIL stall cannot drop
  five independent sockets in the same second while the process keeps logging. The capacity probe
  was claimed at 12:47 and failed at 13:45, entirely inside the storm; its in-flight requests died
  with the connections. There have been zero disconnects in the 18 hours since, and the re-probe
  passed on the same configuration.

The lesson for the next outage: `Close(1011)` is emitted by OUR client when it sees no pong in time,
and that happens both when our loop is too busy to READ the pong and when the network never
delivered one. The log alone cannot tell those apart. The probe can, which is why it stays.

## How we tell OUR stall from the gateway going quiet

`loop_probe.py` settles it. Each miner runs a coroutine on its own event loop that expects to wake
every 250ms and records the overshoot: the loop's own delay is the measurement. The sidecar merges
the resulting files into `/metrics`. The decision rule:

- `engy_miner_loop_lag_seconds_max` near the 60s ping timeout, with
  `engy_miner_loop_lag_peak_inflight` above zero — it is us. Lower `TOPLOC_GEN_CHUNK`, which caps
  output tokens per serve call and so shrinks each parse.
- connections dropping while the lag stayed flat — it is not us. Take the timestamp to engy. This is
  what 2026-07-29 looked like.
- `engy_miner_loop_stall_samples_total{ge="60"}` is the one to alert on: past that threshold we are
  guaranteed to be dropping connections.

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

**Killing the one recorded pid is enough, and this was checked rather than assumed.** `launch_server`
is only the parent: on the prod 8-card node it holds 634MB while its `sglang::scheduler` child holds
123GB — the weights. Killing a parent does not normally kill that child, which would leave the card's
memory held forever and every restart OOM-ing. sglang closes this itself: `kill_itself_when_parent_died()`
sets `PR_SET_PDEATHSIG` to SIGKILL, and the scheduler calls it as the first line of its own setup
(`sglang/srt/managers/scheduler.py`), as does the detokenizer. The kernel reaps the children when the
parent dies, so we need no process group and no `setsid`. Re-check this if sglang is ever upgraded —
without it, in-place restart silently turns a wedged card into a dead one.

Two more things are lifted from that watchdog, both of which it learned the hard way:

- **A grace after every restart** (`ENGY_ENGINE_RESTART_GRACE_SECONDS`, 15 min). A reloading engine
  answers `/metrics` with requests still attributed to it long before it generates again, which
  reads exactly like a wedge. Without the grace the supervisor kills the engine it is waiting for,
  forever. The grace covers an engine that died on its own too, not just one we killed.
- **The counters go out on `/metrics`**, not only into the log: `engy_supervisor_engine_restarts_total`
  and `engy_supervisor_miner_restarts_total` per engine, `engy_supervisor_miner_running`, plus a
  heartbeat and the expected pass interval so staleness is judgeable. A container quietly restarting
  one engine an hour is otherwise indistinguishable from a healthy one, and on a miner's host nobody
  reads the log until something has already gone wrong. The supervisor writes them into `PROBE_DIR`,
  so they ride the same merge the miners' probe files already use — no new plumbing.

Three things are deliberately NOT treated as a wedge, also from dolphin's watchdog:

- an engine that never came up — a cold start legitimately produces nothing for tens of minutes, and
  killing it restarts the download;
- an idle queue — no demand is not a fault, and arming the stall clock while idle would spend the
  budget before the first request arrives;
- anything the supervisor cannot attribute to one engine. A wrong guess costs a healthy engine on top
  of the wedged one.

## Why a supervised background loop is killed with its child

The sidecar and the log trimmer are subshells that run a program in a loop. TERM to the subshell
leaves that program alive — and it still holds the log pipe open, so `refuse_to_start`'s wait for
the pipe to drain never returns. A container that was supposed to refuse loudly hangs instead, and
the platform sees it as running. `terminate_supervised_loop` signals the loop first and its current
child second (`pkill -P`). That order matters: bash defers a TERM taken while it waits on a
foreground child until that child exits, so the loop dies instead of running one more iteration.
Killing the child first leaves a window in which the loop starts a fresh pipe holder.

## Why an engine that never becomes ready is eventually restarted

The wedge detector cannot see it: with no miner attached the engine holds no requests, so the stall
clock never arms and it is excluded by the same rule that protects a cold start. Left alone it sits
idle for the life of the container. After `ENGY_ENGINE_READY_TIMEOUT_SECONDS` from its own start it
is restarted like any other fault — the cold-start exclusion is a grace, not a permanent pass.

## Why one dead card costs one card

The readiness loop used to refuse the whole container when any engine failed to come up. That was
right when a single miner fronted every engine, because losing one engine lost the only worker
anyway. With a miner per engine it throws away seven earning cards to punish one, so a card that
never becomes ready is now left to the supervisor and the rest start without it. Only a node where
NOTHING came up is refused, and `engy_supervisor_miner_running` says which cards are actually
mining.

Readiness is polled in rounds against one shared deadline rather than waited on engine by engine.
Sequentially, a card that never comes up holds the entire timeout before the next card is even
looked at — one sick GPU delayed seven healthy ones by 40 minutes. Cards also warm at different
speeds, and a fast one has no reason to wait for a slow one.

## Why the first engine starts alone

sglang JIT-compiles ~16k FP8 DeepGEMM kernels on a cold engine, 10-20 minutes, into
`DG_JIT_CACHE_DIR` — which sits on the shared volume precisely so that cost is paid once. Started
together, all N engines compile the same kernels at the same time into the same directory: N times
the CPU for one cache, and N writers racing over the same files. So engine 0 starts alone and the
rest follow once it can generate, finding the cache warm. Borrowed from `templates/dolphin`
(`wait_for_cache_seed` plus its stagger).

The wait is capped (`ENGY_CACHE_SEED_WAIT_SECONDS`, 25 min) and abandoned early if the seeding
engine dies: a dead seed will never warm anything, and holding the other cards for the rest of the
budget is pure lost mining.

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

- **Fork the miner** to move parsing and proof building into worker processes. Measured worst
  event-loop gap under the real prod shape is 3.4s against a 60s budget, so there is nothing here to
  fix; the fork would buy a permanent divergence from a file upstream changes weekly in exchange for
  headroom we already have. Revisit only if the probe starts reporting stalls.
- **Lower the declared concurrency.** Declaring 8 and declaring 64 drew the same burst of 8, so the
  number throttles nothing — and below 8 the worker cannot be onboarded at all.
- **Auto-update the vendored miner.** It is pinned (currently upstream v0.4.4 plus the worker-id
  patch) because it must match the gateway protocol exactly, and because every image bump costs a
  restart. Watch upstream and update deliberately, in batches, when acceptance drops or a needed fix
  lands.
- **Ship logs to Loki.** The value is real but almost all of it is in Dolphin, which is 175 of the
  ~200 fillers in prod. Doing it for engy alone would be building infrastructure for one node.
