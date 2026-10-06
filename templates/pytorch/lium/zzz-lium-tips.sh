# Short first-hour tips, printed after the Lium banner in interactive login shells.
case "$-" in
  *i*)
    if [ -r /etc/lium-image.json ]; then
      _lium_tips="$(python3 - <<'PY' 2>/dev/null
import json, os, glob
m = json.load(open("/etc/lium-image.json"))
print(f"image  : {m.get('tag') or 'lium1'}  |  torch {m.get('torch')} (CUDA {m.get('torch_cuda')})  |  nvcc {m.get('nvcc') or '-'}")
print(f"kernels: {' '.join(m.get('torch_arch_list', []))}  (sm_90 Hopper, sm_100 B200/B300, sm_120 RTX 5090 / RTX PRO 6000)")
optix = bool(glob.glob("/usr/lib/x86_64-linux-gnu/libnvoptix.so*"))
print(f"optix  : {'available' if optix else 'not provided by this host driver - Blender: use --cycles-device CUDA'}")
PY
)"
      printf '%s\n' "$_lium_tips"
      unset _lium_tips
    fi
    cat <<'EOF'
tips   : /workspace is the fast disk (/root is an encrypted FUSE mount) - HF_HOME=/workspace/hf is preset
         pip installs into the system python (PEP 668 handled); torch is pinned via /etc/pip/constraints.txt,
         bypass once with PIP_CONSTRAINT=/dev/null pip install ...   |  uv, ffmpeg, tesseract, rsync, nvcc included
         background jobs: nohup setsid CMD > log 2>&1 < /dev/null &   |  lium-gpu-check prints GPU/torch/arch status
EOF
    ;;
esac
