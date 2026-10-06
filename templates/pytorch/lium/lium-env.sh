# Lium pod environment (interactive and login shells; /etc/environment covers the rest).
case ":${PATH}:" in *":/usr/local/cuda/bin:"*) ;; *) export PATH="/usr/local/cuda/bin:${PATH}" ;; esac
export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
export PIP_BREAK_SYSTEM_PACKAGES="${PIP_BREAK_SYSTEM_PACKAGES:-1}"
# /root is an encrypted FUSE volume on Lium rentals; /workspace is the fast path.
export HF_HOME="${HF_HOME:-/workspace/hf}"
