#!/usr/bin/env bash
# build-smoke.sh — every template's bake file resolves; every CHANGED template builds and boots.
#
#   scripts/build-smoke.sh                 # templates changed vs $BASE (default origin/master); scripts/** → ubuntu + pytorch
#   scripts/build-smoke.sh ubuntu pytorch  # named templates
#   E2E_GPU=1 scripts/build-smoke.sh …     # on a GPU host: run the built image with --gpus all and require torch.cuda
#
# For each template: `docker buildx bake --print` (the HCL resolves; every default target's Dockerfile exists), then ONE target is built with --load —
# the template's `smoke` group when it defines one, else the first target of `default` — and the image is booted
# with its own CMD: pod templates (they ship /start.sh) must answer python3; the `pytorch` template must `import torch`; on a GPU host
# nvidia-smi must list the GPU in every image and torch.cuda must be available where torch imports; templates/<name>/smoke.sh runs inside the container when present. Every step under `timeout`;
# artifacts/ gets timings.txt and summary.md (the CI job posts it). Exit 0 only when every step passed.
set -uo pipefail
cd "$(dirname "$0")/.."
BASE=${BASE:-origin/master}
A=artifacts; mkdir -p "$A"; : > "$A/timings.txt"
T_BAKE=${T_BAKE:-2m}; T_BUILD=${T_BUILD:-40m}; T_BOOT=${T_BOOT:-5m}
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

build_one() {  # <template>
  local t=$1 target; target=$(pick_target "$t") || { echo "no target in templates/$t"; return 1; }
  echo "building templates/$t target $target"
  # the bake files read ../../scripts (a context outside the template dir): newer buildx wants that allowed explicitly.
  # One platform: --load cannot import a multi-platform target (empty-job lists amd64 + arm64); executors and runners are amd64.
  ( cd "templates/$t" && BUILDX_BAKE_ENTITLEMENTS_FS=0 docker buildx bake --load --set "*.tags=lium-smoke/$t:latest" --set "*.platform=linux/amd64" "$target" ) 2>&1 | tail -40
  return "${PIPESTATUS[0]}"
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

export -f bake_print_all pick_target build_one boot_one
export A E2E_GPU
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
