#!/usr/bin/env bash
# build-smoke.sh — every template's bake file resolves; every CHANGED template builds and boots.
#
#   scripts/build-smoke.sh                 # templates changed vs $BASE (default origin/master); scripts/** → ubuntu + pytorch
#   scripts/build-smoke.sh ubuntu pytorch  # named templates
#   E2E_GPU=1 scripts/build-smoke.sh …     # on a GPU host: run the built image with --gpus all and require torch.cuda
#   scripts/build-smoke.sh --bases dolphin  # print the base image(s) the smoke target pulls; nothing is built
#
# For each template: `docker buildx bake --print` (the HCL resolves; every default target's Dockerfile exists), then ONE target is built with --load —
# the template's `smoke` group when it defines one, else the first target of `default` — and the image is booted
# with its own CMD (its base images are pulled first, each try under T_PULL, 3 tries, all of them within T_PULL_TOTAL,
# so a stalled registry ends with a message instead of eating the build budget): pod templates (they ship /start.sh) must answer python3; the `pytorch` template must `import torch`; on a GPU host
# nvidia-smi must list the GPU in every image and torch.cuda must be available where torch imports; templates/<name>/smoke.sh runs inside the container when present. Every step under `timeout`;
# artifacts/ gets timings.txt and summary.md (the CI job posts it). Exit 0 only when every step passed.
set -uo pipefail
cd "$(dirname "$0")/.."
BASE=${BASE:-origin/master}
A=artifacts; mkdir -p "$A"; : > "$A/timings.txt"
T_BAKE=${T_BAKE:-2m}; T_BUILD=${T_BUILD:-40m}; T_BOOT=${T_BOOT:-5m}; T_PULL=${T_PULL:-8m}; T_PULL_TOTAL=${T_PULL_TOTAL:-25m}   # one base-image pull attempt (3 attempts) / all pulls of a template
FAILED=""

step() {  # step <name> <timeout> <function-or-cmd...>  (functions below are exported, so timeout can run them)
  local name=$1 t=$2; shift 2; local t0=$SECONDS rc status
  echo "::group::$name"; timeout -k 30 "$t" bash -c '"$@"' _ "$@"; rc=$?; echo "::endgroup::"
  case $rc in 0) status=pass ;; 124|137) status="TIMEOUT(>$t)" ;; *) status="FAIL(rc=$rc)" ;; esac
  printf '%s\t%ds\t%s\n' "$name" "$((SECONDS - t0))" "$status" >> "$A/timings.txt"
  echo "smoke: $name $status in $((SECONDS - t0))s"; [ $rc -eq 0 ] || FAILED="${FAILED:+$FAILED }$name"; return $rc
}

changed_templates() {
  if [ $# -gt 0 ]; then printf '%s\n' "$@"; return; fi
  local files; files=$(git diff --name-only "$BASE"...HEAD 2>/dev/null || git diff --name-only HEAD~1)
  { printf '%s\n' "$files" | sed -n 's|^templates/\([^/]*\)/.*|\1|p'
    printf '%s\n' "$files" | grep -q '^scripts/' && printf 'ubuntu\npytorch\n'; } | sort -u
}

bake_print_all() {  # every bake file must resolve and every default target's Dockerfile must exist — a broken HCL or a
  local rc=0 d root=$PWD   # missing Dockerfile fails here, cheaply, even for templates the PR did not touch (--print alone does not stat files)
  for d in templates/*/; do
    [ -f "$d/docker-bake.hcl" ] || continue
    ( cd "$d" && docker buildx bake --print 2>"$root/$A/bake-$(basename "$d").err" | python3 -c '
import json, os, sys
try: targets = json.load(sys.stdin)["target"]
except ValueError: sys.exit("bake --print produced no JSON")
missing = [n for n, t in targets.items() if not os.path.isfile(os.path.join(t.get("context", "."), t.get("dockerfile", "Dockerfile")))]
sys.exit("missing Dockerfile for target(s): " + ", ".join(missing) if missing else 0)' ) \
      || { echo "bake --print or Dockerfile check failed: $d"; grep -m5 -i error "$root/$A/bake-$(basename "$d").err"; rc=1; }
  done
  return $rc
}

pick_target() {  # <template> → the target to build: group smoke's first (when the bake file defines one), else default's first
  local t=$1 json
  if json=$(docker buildx bake -f "templates/$t/docker-bake.hcl" --print smoke 2>/dev/null); then :
  else json=$(docker buildx bake -f "templates/$t/docker-bake.hcl" --print 2>/dev/null) || return 1; fi
  python3 - "$json" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); g = d.get("group", {})
for name in ("smoke", "default"):
    if name in g and g[name].get("targets"):
        print(g[name]["targets"][0]); sys.exit(0)
print(next(iter(d["target"])))
PY
}

base_images() {  # <template> <target> → the registry images the target's Dockerfile starts FROM, one per line
  # bake --print gives the dockerfile and the args; the Dockerfile's own `ARG X=default` lines fill what the bake
  # file leaves unset. `FROM <earlier stage>` and `FROM scratch` are not images and are skipped.
  local t=$1 target=$2 json
  json=$(cd "templates/$t" && docker buildx bake --print "$target" 2>/dev/null) || return 1
  python3 - "templates/$t" "$json" <<'PY'
import json, os, re, sys
tdir, d = sys.argv[1], json.loads(sys.argv[2])
seen = []
for tgt in d["target"].values():
    ctx = os.path.join(tdir, tgt.get("context", "."))
    df = os.path.join(ctx, tgt.get("dockerfile", "Dockerfile"))
    if not os.path.isfile(df):
        continue
    args = {}
    stages = set((tgt.get("contexts") or {}).keys())   # bake named contexts (`contexts = { base = "target:x" }`) are not registry images either
    for line in open(df):
        line = line.strip()
        m = re.match(r"ARG\s+([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if m:
            args.setdefault(m.group(1), m.group(2).strip().strip('"\''))
        m = re.match(r"FROM\s+(?:--platform=\S+\s+)?(\S+)(?:\s+[Aa][Ss]\s+(\S+))?", line)
        if not m:
            continue
        ref = m.group(1)
        merged = {**args, **{k: v for k, v in (tgt.get("args") or {}).items()}}
        ref = re.sub(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", lambda mm: merged.get(mm.group(1), ""), ref)
        if ref and ref != "scratch" and ref not in stages and ref not in seen:
            seen.append(ref)
        if m.group(2):   # after the check: `FROM redis AS redis` still pulls redis
            stages.add(m.group(2))
print("\n".join(seen))
PY
}

secs() { case $1 in *h) echo $(( ${1%h} * 3600 )) ;; *m) echo $(( ${1%m} * 60 )) ;; *s) echo "${1%s}" ;; *) echo "$1" ;; esac; }

pull_base_images() {  # <template> <target>: docker pull each base image, up to 3 tries of T_PULL each, all within T_PULL_TOTAL
  # 11 Sep 2026, run 34584117479 attempt 1: build-dolphin produced no output for the whole 40-minute budget (the log
  # was lost to `| tail -40`) — a stalled pull or a stalled apt mirror; attempt 2 built the same image in 181 s. The
  # pull half is retried here under its own timeout instead of consuming the build budget; layers already extracted
  # are kept between tries, the layer in flight is fetched again. An apt stall still times out, with its log kept.
  # T_PULL_TOTAL (default 25m, below T_BUILD) caps the pulls of one template together, so a template with several
  # FROM images (fast-stable-diffusion has two) still ends with a message rather than the step's TIMEOUT.
  local img rc tries start=$SECONDS left per_try total; total=$(secs "$T_PULL_TOTAL"); per_try=$(secs "$T_PULL")
  while read -r img; do
    [ -n "$img" ] || continue
    rc=1
    for tries in 1 2 3; do
      left=$(( total - (SECONDS - start) ))
      [ "$left" -gt 0 ] || { echo "base image $img: pull budget $T_PULL_TOTAL spent"; return 1; }
      [ "$left" -lt "$per_try" ] || left=$per_try
      echo "pull $img (try $tries, limit ${left}s)"
      if timeout -k 15 "$left" docker pull --quiet --platform linux/amd64 "$img"; then rc=0; break; fi
    done
    [ $rc -eq 0 ] || { echo "base image $img did not pull in 3 tries"; return 1; }
  done < <(base_images "$1" "$2")
}

build_one() {  # <template>
  local t=$1 target; target=$(pick_target "$t") || { echo "no target in templates/$t"; return 1; }
  echo "building templates/$t target $target"
  pull_base_images "$t" "$target" || return 1
  # the bake files read ../../scripts (a context outside the template dir): newer buildx wants that allowed explicitly.
  # One platform: --load cannot import a multi-platform target (empty-job lists amd64 + arm64); executors and runners are amd64.
  # The full plain-progress log goes to artifacts/build-<template>.log — a build the timeout kills still leaves it
  # (piping through `tail` printed nothing for the 40-minute stall above); the last 40 lines are echoed here.
  ( cd "templates/$t" && BUILDX_BAKE_ENTITLEMENTS_FS=0 docker buildx bake --progress=plain --load --set "*.tags=lium-smoke/$t:latest" --set "*.platform=linux/amd64" "$target" ) > "$A/build-$t.log" 2>&1
  local rc=$?
  tail -40 "$A/build-$t.log"
  return $rc
}

boot_one() {  # <template>: start the image with its own CMD, then look inside
  local t=$1 cid gpu_flags=""
  local img="lium-smoke/$t:latest"
  [ -n "${E2E_GPU:-}" ] && gpu_flags="--gpus all"
  # A template that needs environment to start at all declares it in templates/<t>/smoke.env —
  # the dolphin filler refuses to run without its API key, and refusing is correct behaviour.
  local env_flag=""
  [ -f "templates/$t/smoke.env" ] && env_flag="--env-file templates/$t/smoke.env"
  # no --rm: a container that dies inside the 5 s wait must still have its logs; the main loop removes `smoke-<template>`
  docker rm -f "smoke-$t" >/dev/null 2>&1 || true
  cid=$(docker run -d $gpu_flags $env_flag --name "smoke-$t" "$img") || return 1
  sleep 5
  docker ps -q --no-trunc | grep -q "$cid" || { echo "container exited within 5 s:"; docker logs "$cid" 2>&1 | tail -20; return 1; }
  local rc=0
  # a POD template ships the lium /start.sh (scripts/start.sh): python3 and /workspace are its contract with renters.
  # Infrastructure images (redis, docker-dind, verifier…) only have to boot and pass their own smoke.sh.
  if docker exec "$cid" sh -c 'test -e /start.sh'; then
    docker exec "$cid" sh -c 'command -v python3 >/dev/null && python3 --version' || { echo "pod template without python3"; rc=1; }
    docker exec "$cid" sh -c 'test -d /workspace' || echo "note: no /workspace in the image (start.sh creates it only for Jupyter; the docs point renters at /workspace)"
  else
    echo "infrastructure image (no /start.sh): boot check only"
  fi
  # GPU tier: the GPU must be visible in every image run with --gpus all; torch.cuda additionally where torch imports
  [ -n "${E2E_GPU:-}" ] && { docker exec "$cid" sh -c 'nvidia-smi -L' || { echo "nvidia-smi failed with --gpus all"; rc=1; }; }
  if docker exec "$cid" sh -c 'python3 -c "import torch" 2>/dev/null'; then
    docker exec "$cid" python3 -c 'import torch; print("torch", torch.__version__, "cuda build", torch.version.cuda)' || rc=1
    [ -n "${E2E_GPU:-}" ] && { docker exec "$cid" python3 -c 'import torch, sys; ok = torch.cuda.is_available(); print("cuda available", ok, torch.cuda.get_device_name(0) if ok else ""); sys.exit(0 if ok else 1)' || rc=1; }
  elif [ "$t" = pytorch ]; then echo "pytorch image without importable torch"; rc=1; fi
  if [ -f "templates/$t/smoke.sh" ]; then docker cp "templates/$t/smoke.sh" "$cid:/tmp/smoke.sh" && docker exec "$cid" sh /tmp/smoke.sh || { echo "templates/$t/smoke.sh failed"; rc=1; }; fi
  docker stop -t 5 "$cid" >/dev/null 2>&1 || true
  return $rc
}

summary() {
  { echo "**image smoke: $([ -z "$FAILED" ] && echo PASS || echo "FAIL ($FAILED)")**"; echo; echo "| step | result | time |"; echo "|---|---|---|"
    while IFS=$'\t' read -r n s st; do echo "| $n | $([ "$st" = pass ] && echo ✅ || echo ❌) $st | $s |"; done < "$A/timings.txt"; } > "$A/summary.md"
  cat "$A/summary.md"
}

export -f bake_print_all pick_target base_images secs pull_base_images build_one boot_one
export A E2E_GPU T_PULL T_PULL_TOTAL
if [ "${1:-}" = --bases ]; then  # --bases <template>: print the images the smoke target pulls (the CI self-test reads it)
  [ -n "${2:-}" ] || { echo "usage: build-smoke.sh --bases <template>"; exit 2; }
  target=$(pick_target "$2") || { echo "no target in templates/$2"; exit 1; }
  base_images "$2" "$target"; exit $?
fi
step bake-print-all "$T_BAKE" bake_print_all
TEMPLATES=$(changed_templates "$@")
if [ -z "$TEMPLATES" ]; then echo "no template changed vs $BASE — bake --print of every template is the whole check"; summary; [ -z "$FAILED" ]; exit $?; fi
for t in $TEMPLATES; do
  if [ ! -f "templates/$t/docker-bake.hcl" ]; then
    # a name typed on the command line (or in workflow_dispatch) must exist; a template the diff removed is skipped
    if [ $# -gt 0 ]; then echo "templates/$t has no docker-bake.hcl"; FAILED="${FAILED:+$FAILED }build-$t"; printf '%s\t0s\tFAIL(no bake file)\n' "build-$t" >> "$A/timings.txt"; else echo "templates/$t has no docker-bake.hcl — skipped"; fi
    continue
  fi
  step "build-$t" "$T_BUILD" build_one "$t" && step "boot-$t" "$T_BOOT" boot_one "$t"
  docker rm -f "smoke-$t" >/dev/null 2>&1 || true                    # also after a boot timeout, when boot_one never reached docker stop
  docker image rm -f "lium-smoke/$t:latest" >/dev/null 2>&1 || true   # runners have ~14 GB free; one image at a time
done
summary; [ -z "$FAILED" ]
