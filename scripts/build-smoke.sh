#!/usr/bin/env bash
# build-smoke.sh — every template's bake file resolves; every CHANGED template builds and boots.
#
#   scripts/build-smoke.sh                 # templates changed vs $BASE (default origin/master); scripts/** → ubuntu + pytorch
#   scripts/build-smoke.sh ubuntu pytorch  # named templates
#   E2E_GPU=1 scripts/build-smoke.sh …     # on a GPU host: run the built image with --gpus all and require torch.cuda
#
# For each template: `docker buildx bake --print` (HCL + Dockerfile resolve), then ONE target is built with --load —
# the template's `smoke` group when it defines one, else the first target of `default` — and the image is booted
# with its own CMD: python3 answers, /workspace exists, `import torch` (pytorch templates), nvidia-smi + torch.cuda
# on a GPU host, and templates/<name>/smoke.sh runs inside the container when present. Every step under `timeout`;
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
  echo "smoke: $name $status in $((SECONDS - t0))s"; [ $rc -eq 0 ] || FAILED="$FAILED $name"; return $rc
}

changed_templates() {
  if [ $# -gt 0 ]; then printf '%s\n' "$@"; return; fi
  local files; files=$(git diff --name-only "$BASE"...HEAD 2>/dev/null || git diff --name-only HEAD~1)
  { printf '%s\n' "$files" | sed -n 's|^templates/\([^/]*\)/.*|\1|p'
    printf '%s\n' "$files" | grep -q '^scripts/' && printf 'ubuntu\npytorch\n'; } | sort -u
}

bake_print_all() {  # every bake file must resolve — a broken HCL or a missing Dockerfile fails here, cheaply
  local rc=0 d
  for d in templates/*/; do
    [ -f "$d/docker-bake.hcl" ] || continue
    docker buildx bake -f "$d/docker-bake.hcl" --print >/dev/null 2>"$A/bake-$(basename "$d").err" || { echo "bake --print failed: $d"; head -5 "$A/bake-$(basename "$d").err"; rc=1; }
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
  # the bake files read ../../scripts (a context outside the template dir): newer buildx wants that allowed explicitly
  ( cd "templates/$t" && BUILDX_BAKE_ENTITLEMENTS_FS=0 docker buildx bake --load --set "*.tags=lium-smoke/$t:latest" "$target" ) 2>&1 | tail -40
  return "${PIPESTATUS[0]}"
}

boot_one() {  # <template>: start the image with its own CMD, then look inside
  local t=$1 cid gpu_flags=""
  local img="lium-smoke/$t:latest"
  [ -n "${E2E_GPU:-}" ] && gpu_flags="--gpus all"
  cid=$(docker run -d --rm $gpu_flags --name "smoke-$t-$$" "$img") || return 1
  sleep 5
  docker ps -q --no-trunc | grep -q "$cid" || { echo "container exited within 5 s:"; docker logs "$cid" 2>&1 | tail -20; return 1; }
  local rc=0
  docker exec "$cid" sh -c 'command -v python3 >/dev/null && python3 --version' || { echo "no python3"; rc=1; }
  docker exec "$cid" sh -c 'test -d /workspace' || { echo "no /workspace"; rc=1; }
  if docker exec "$cid" sh -c 'python3 -c "import torch" 2>/dev/null'; then
    docker exec "$cid" python3 -c 'import torch; print("torch", torch.__version__, "cuda build", torch.version.cuda)' || rc=1
    if [ -n "${E2E_GPU:-}" ]; then
      docker exec "$cid" sh -c 'nvidia-smi -L' || { echo "nvidia-smi failed with --gpus all"; rc=1; }
      docker exec "$cid" python3 -c 'import torch, sys; ok = torch.cuda.is_available(); print("cuda available", ok, torch.cuda.get_device_name(0) if ok else ""); sys.exit(0 if ok else 1)' || rc=1
    fi
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
  [ -f "templates/$t/docker-bake.hcl" ] || { echo "templates/$t has no docker-bake.hcl — skipped"; continue; }
  step "build-$t" "$T_BUILD" build_one "$t" && step "boot-$t" "$T_BOOT" boot_one "$t"
  docker image rm -f "lium-smoke/$t:latest" >/dev/null 2>&1 || true   # runners have ~14 GB free; one image at a time
done
summary; [ -z "$FAILED" ]
