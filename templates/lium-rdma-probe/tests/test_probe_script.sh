#!/usr/bin/env bash
# The probe script only ever runs inside the image, so a syntax error surfaces as a failed
# measurement in a validator cycle and nowhere else. It cost one staging cycle: an apostrophe
# inside a `${var:?message}` opened a quote and bash died with "unexpected EOF".
set -euo pipefail

script="$(dirname "$0")/../lium-roce-probe.sh"

bash -n "$script"
echo "PASS: the probe script parses"

# A `${var:?...}` message is shell-parsed, so an apostrophe in it breaks the whole file.
if grep -n "{[a-z_]*:?[^}]*'" "$script"; then
    echo "FAIL: an apostrophe inside a \${var:?message} opens a quote" >&2
    exit 1
fi
echo "PASS: no apostrophe inside a parameter-expansion message"
