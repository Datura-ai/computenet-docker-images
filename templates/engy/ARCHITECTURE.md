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
│   …one engine and one miner per card, or ENGY_ENGINES_PER_GPU of them sharing each card…
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

## Why more than one engine per card (`ENGY_ENGINES_PER_GPU`, DAH-2601)

The card is not what limits this workload. Prod sat at **2 concurrent requests across all eight
engines** over a 7-minute sample, and declaring 64 inflight drew the same burst of 8 as declaring 8:
the gateway sends what it decides to send. So the lever is not throughput per card, it is how much
of the gateway's routing we are in front of — and the gateway routes to **workers**.

A second engine on the same card is a second worker under the same hotkey, on hardware we are
already paying for. The model needs ~48GB to serve and the class we run engy on is 143GB (H200) or
180GB (B200), so two fit with KV cache to spare.

Three things follow from engines sharing a card:

- **The static pool is split, but NOT by dividing the fraction.** sglang's `--mem-fraction-static`
  is not a share of the card: its budget is
  `free_after_weights - free_before_weights * (1 - fraction)` (`model_runner_kv_cache_mixin.py`), so
  the reserve is a fraction of what THAT engine found free at its own start. Giving each engine
  `0.85/N` starves the later ones — measured on an H200 (2026-08-06): engine 0 took its 0.42, engine 1
  computed a negative pool and died with *"Not enough memory. Please try to increase
  --mem-fraction-static"*. Solving for an equal share gives `fraction = s / (1 - slot * s)` with
  `s = 0.85/N`: 0.425 then 0.7391 for two engines on an H200, ~61GB each. At N=1 it is the plain 0.85
  this image has always used.
- **Engines sharing a card start in slot order.** Each one measures the memory it finds free, so slot
  s+1 must not start until slot s has loaded — otherwise both plan against the same empty card. The
  wait is capped and never fatal (`wait_for_slot_to_load`).
- **The knob is clamped by the hardware, not trusted.** It arrives from platform config, each engine
  holds its own 35GB copy of the checkpoint, and a value the card cannot hold buys a crash-loop of
  35GB loads rather than a clean failure. `size_engines_to_the_card` reads the smallest card and caps
  the count at 48GB per engine **of the 0.85 the engines actually get** — so an H200 tops out at 2
  and a B200 at 3. Sizing the count on the whole card while allocating 0.85 of it would let a card
  pass the clamp and still hand each engine less than one needs. A card whose size `nvidia-smi` will
  not report is taken at the operator's word: an unreadable card must not silently halve a healthy
  node.
- **The worker name says which card.** `-g<card>` while one engine owns a card, `-g<card>e<slot>`
  once they share one — the name is the only handle on a worker in the engy dashboard, the probe
  filenames and the `engy_worker` metric label, so an engine-only index would make "which card went
  quiet" unanswerable from any metric.
- **Engine index stopped being card index.** Engine *i* runs on card *i / N*
  (`assign_engines_to_ports_and_cards`), which
  keeps engines sharing a card adjacent and leaves engine 0 on card 0, where the kernel-cache seed
  runs. Everything else in the supervisor was already keyed on the engine.

What it costs: acceptance is scored per **hotkey**, so twice the workers is twice the surface for one
bad capacity probe to drag the key's day. Each worker also needs its own 8 clean gateway legs. Both
are why this ships defaulting to 1 and is turned up per environment.

Watch the KV cache when you turn it up: the engine's slot count does NOT split with the pool, so at
2 engines on an H200 each one still holds 26 concurrent requests (3 per leg x 8 legs, plus our own
two) out of ~25GB of KV instead of ~87GB. Preemption and prefill recompute would show up as
tokens/GPU-h below the baseline rather than as an error.

Verified live on a rented H200 (2026-08-06, `ENGY_ENGINES_PER_GPU=2`): two engines at 62886 MiB and
60384 MiB — 86% of the card — two workers `…-g0e0` and `…-g0e1`, each dialing **8 of 8 gateway legs**
and serving. So the shape onboards; what it earns is the open question.

Unmeasured, and the reason to roll it out on one node first: whether the gateway's routing actually
follows worker count. If it routes by hotkey and splits the same work over more workers, two engines
per card is the same tokens at twice the acceptance surface — a loss. The baseline to beat is
118,540 tokens/GPU-h.

## Why a leg needs three inflight, not one

`ENGY_REQUESTS_PER_GATEWAY_LEG` (default **3**) is the knob. The total a miner declares as
`MAX_INFLIGHT` is derived from it — per-leg times the gateway's live leg count, so 24 against
today's 8 — and is never configured directly.

**Per leg is the unit that matters because that is the unit the miner uses.** `_leg_plan` splits the
declaration evenly across the legs, so a total only ever reaches the gateway as a per-leg number;
configuring the total means configuring the per-leg value by accident, and getting it wrong the day
engy changes its leg count. Below one per leg it is worse than wrong: `_leg_plan` opens `declared`
legs instead of one per worker, and a worker short of a leg is refused before it serves anything.
The portal says so in as many words: *"Qualification and sampling only target workers with all 8
legs live, so it will receive no test traffic — and cannot be onboarded — until every leg
connects."* Measured by running this image at a total of 4 on a rented H100 (2026-07-30): the worker
connected, opened four connections, and was failed in three seconds with `offered 4 distinct clean
legs, below the required 8`. Zero requests, ever.

**Three is measured, not chosen.** Clean A/B on one rented H100x8 (2026-08-12) — same image `0.0.7`,
same box, same hour, warm weights, nothing but this number different:

| per leg | declared | onboarded | failures |
|---|---|---|---|
| 2 | 16 | **6 of 8** | `served only 7 concurrent legs`, `offered 7 distinct clean legs`, one each, both on attempt 1 |
| 3 | 24 | **8 of 8** | none, across 16 worker-starts |

Prod runs 2 per leg and sits at exactly 6 active + 2 failed with that same pair of reasons, so the
control reproduced prod's split on the first try. The two failure strings are two stages of one
shortfall — `offered 7 distinct clean legs` is the dial stage, `served only 7 concurrent legs` the
serve stage — and at 3 per leg neither appears. Why a third slot is enough: the prober needs all 8
legs serving *concurrently*, and each probe prompt is ~12.9k tokens against a
`--chunked-prefill-size` of 8192, so sglang admits one sequence per prefill pass (`#new-seq: 1`) and
the legs enter the running batch serially over ~1.2s. At 2 per leg anything else holding a leg
during that ramp leaves seven; the third slot is the margin that ramp needs.

**The total tracks the live leg count, never a constant.** The gateway runs 8 legs today, and 8 is
what the entrypoint assumes when `GW/meta` cannot be read — but pinning 24 would silently become 2
per leg the day engy runs 12, which is the configuration that loses two cards out of eight. Sizing
against the live count is also why the container asks the gateway BEFORE it launches an engine: an
engine's slot count is fixed at launch, and it is sized from the settled declaration.

The declaration is an admission ticket, not a throttle: same box, same day, declaring 8 drew a burst
of 8 concurrent and declaring **64 drew the same burst of 8**. Raising it does not pull more
traffic — it only decides whether onboarding passes.

## Why the engine holds more than it declares

sglang's `--max-running-requests` is NOT the declaration. It is the declaration plus
`ENGINE_SLOTS_FOR_OUR_OWN_PROBES` (**2**), so the default shape is a worker that advertises 24 and
an engine that holds 26.

The two used to be the same number, and that is a bug with a name. The miner splits `MAX_INFLIGHT`
into one inflight per gateway leg, so at 8 the engine had exactly one slot per leg and no spare.
The prober requires all 8 legs to serve **concurrently**; anything else holding a slot at that
moment — our own `/health_generate`, a leg that had not drained — leaves 7, and the worker is failed
with `served only 7 CONCURRENT legs` while every HTTP response in the log is a 200.

Measured as a clean A/B on one rented H100 (2026-08-10, same box, same image 0.0.7): declared 8 ->
failed after 790 requests, all of them successful; declared 16 -> `active`. Raising the declaration
was never the fix, it just happened to buy the engine a spare slot. Prod paid for that confusion
twice — DAH-2603 rolled 16 back to 8 on 2026-08-06 reading the symptom backwards, and prod
onboarding failed from that day until DAH-2601 rolled it forward again on 2026-08-11.

**Additive, not a multiplier.** The gateway never sends more than the declaration — declaring 8 drew
a burst of 8, declaring 64 drew the same 8 — so the only slots it cannot fill are the ones this
container takes: `engine_is_generating`'s `/health_generate` in the supervisor loop, and a leg that
has not drained. That is a constant two, and it must stay constant: doubling the declaration instead
would silently take a 16-worker gateway to 32 concurrent sequences on one card's KV pool, which is
the preemption-and-prefill-recompute cost this file warns about under the split. Spare slots cost
nothing while they sit idle; a missing one costs the entire worker.

## Why worker ids are random again

`engy_miner.py` mints `WORKER_ID = uuid4().hex` per PROCESS, and engy's control plane keys a worker
on that id. So every restart registers a **brand-new worker**, which enters `pending` and has to be
onboarded again; a stable `ENGY_WORKER_NAME` does not change that — the id is what counts, despite
the upstream comment claiming a repeat HELLO with the same (key, name) supersedes.

DAH-2531 therefore pinned the id: the entrypoint derived it from the worker name
(`sha256(name)[:32]`) and the vendored miner honoured `ENGY_WORKER_ID`, which made a restart a
re-dial. Verified live on 2026-07-30 — worker `04955ec4…` was restarted mid-`active` and came back as
the same worker, request history intact.

**Reverted on 2026-08-04, because a pinned id also pins the CAPACITY.** engy records a worker's
declared max inflight at the record it creates on first onboarding and never refreshes it on
reconnect. With a pinned id the node reconnected into its record from 2026-08-03 forever, so raising
the declared inflight was a silent no-op: the container booted with the new number, the miner
sent it on every hello, and the dashboard kept showing the old one — which is also the number the
gateway routes against. Onboarding is quick now, so re-onboarding on restart is the cheaper half of
the trade, and it is the only way a config change ever lands.

The lock below is unaffected: it is keyed on the worker NAME, which is still stable per card.

`engy_launch.py` also scopes the miner's singleton lock to the worker. Upstream locks
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
That is the wrong tool: recreation costs a cold start, and since worker ids are per-process it also
costs every other card's onboarding. The supervisor now kills the wedged engine (SIGKILL — a process
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

## Why the boot refresh judges the download in silence

`why_staged_miner_is_unusable` returns its reason as text, and empty means "take it". By the time it
runs, `PYTHONPATH` already points at our own directory, so starting any interpreter loads
`sitecustomize.py` — which prints `[engy] hidden-states trim armed` on **stdout**. That banner landed
in the reason string, so every valid refresh was discarded with a nonsense excuse and the feature was
dead in the image while looking healthy. Verified on the live prod container: with the entrypoint's
own `PYTHONPATH`, `py_compile` of a one-line file captures the banner; with it cleared, nothing.

So the validation runs as `PYTHONPATH= python3 -m py_compile … >/dev/null 2>&1`: it must not load our
hooks, and no future chatter on either stream can be mistaken for a verdict. Anything added to this
function has to keep that property — write reasons, never let a child write anything.

## Why the sidecar reports WHICH engines answered, not just how many

The token counters in one scrape are a SUM over the engines that answered, so two scrapes are only
comparable when that set is the same. A count almost says this and gets one case wrong: engine 3
leaving while engine 5 returns keeps the count at 8, and engine 5's whole lifetime counter re-enters
the sum and is booked as one interval's work. That is the same class of overcount that inflated
dolphin's fleet totals ~2.8x.

`engy_sidecar_engines_reachable_mask` is one bit per configured engine, so the set is exact rather
than summarised. lium-stats compares it between consecutive scrapes and books 0 when it moves. It is
NULL on images without the gauge, where the count comparison is still used.

## Why each miner announces one card

The HELLO frame's hardware summary comes from `nvidia-smi`, which lists the whole node and ignores
CUDA_VISIBLE_DEVICES, so all eight miners announced the node's eight cards each. The entrypoint sets
`HW_GPUS` — upstream's own override — and `engy_launch.py` corrects `HW["gpu_count"]` beside it,
because overriding only the string leaves the frame contradicting itself. It costs nothing in routing
or scoring (legs and per-worker acceptance decide those); it is about not appearing to claim hardware
we are not backing that worker with.

## Why a refusal kills as well as terminates

`refuse_to_start` cannot return until the log pipe drains, because the reason has to reach disk — and
anything still holding that pipe keeps it open. The late refusal ("no engine became ready") runs with
engines alive, and an engine wedged in a driver call never acts on TERM. So after a grace period
every engine and miner is killed outright. Without that, the container that was supposed to refuse
loudly hangs forever and the platform sees it as running: the exact failure this whole path exists to
avoid.

## What we deliberately did not do

- **Fork the miner** to move parsing and proof building into worker processes. Measured worst
  event-loop gap under the real prod shape is 3.4s against a 60s budget, so there is nothing here to
  fix; the fork would buy a permanent divergence from a file upstream changes weekly in exchange for
  headroom we already have. Revisit only if the probe starts reporting stalls.
- **Lower the declared concurrency.** Declaring 8 and declaring 64 drew the same burst of 8, so the
  number throttles nothing — and below 8 the worker cannot be onboarded at all.
- **Pin the vendored miner to a release tag.** Upstream's tags lag their own default branch badly —
  the newest release was v0.4.1 while the tags read v0.4.4 — so a tag is not "current". The image
  refreshes from the branch on every boot and keeps its own copy when anything about the download
  looks wrong. `ENGY_MINER_AUTO_UPDATE=0` pins it.
- **Ship logs to Loki.** The value is real but almost all of it is in Dolphin, which is 175 of the
  ~200 fillers in prod. Doing it for engy alone would be building infrastructure for one node.
