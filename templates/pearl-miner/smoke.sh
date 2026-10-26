#!/bin/sh
# Runs inside the image on a GPU host (E2E_GPU=1): the baked miner runs, the scripts parse, the sidecar parses.
set -e
peakminer --version | grep -q "peakminer ${PEARL_MINER_BAKED_VERSION}"
bash -n /usr/local/bin/entrypoint.sh
bash -n /usr/local/bin/update_miner.sh
bash -n /usr/local/bin/prefetch_engy.sh
hf download --help >/dev/null
python3 -c "import ast; ast.parse(open('/usr/local/bin/metrics_sidecar.py').read())"
echo "pearl-miner smoke: peakminer ${PEARL_MINER_BAKED_VERSION}, scripts parse"
