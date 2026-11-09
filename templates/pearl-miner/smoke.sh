#!/bin/sh
# Runs inside the image on a GPU host (E2E_GPU=1): the baked miner runs, the scripts parse, the sidecar parses.
set -e
peakminer --version | grep -q "peakminer ${PEARL_MINER_BAKED_VERSION}"
# the WildRig build (DAH-6084) carries its pinned binary and the OpenCL ICD entry it finds NVIDIA cards through
if [ "${PEARL_MINER}" = wildrig ]; then
    test -x /usr/local/bin/wildrig-multi
    test -f /etc/OpenCL/vendors/nvidia.icd
fi
bash -n /usr/local/bin/entrypoint.sh
bash -n /usr/local/bin/update_miner.sh
python3 -c "import ast; ast.parse(open('/usr/local/bin/metrics_sidecar.py').read())"
echo "pearl-miner smoke: ${PEARL_MINER} build, peakminer ${PEARL_MINER_BAKED_VERSION}, scripts parse"
