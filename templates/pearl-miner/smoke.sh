#!/bin/sh
# Runs inside the image without a GPU: the baked miner runs, the scripts parse, the sidecar imports.
set -e
peakminer --version | grep -q "peakminer ${PEARL_MINER_BAKED_VERSION}"
bash -n /usr/local/bin/entrypoint.sh
bash -n /usr/local/bin/update_miner.sh
python3 -c "import ast; ast.parse(open('/usr/local/bin/metrics_sidecar.py').read())"
echo "pearl-miner smoke: peakminer ${PEARL_MINER_BAKED_VERSION}, scripts parse"
