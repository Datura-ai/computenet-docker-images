#!/bin/bash
set -e

mkdir -p /var/lib/nvidia/dev
shopt -s nullglob

for dev in /dev/nvidia*; do
    ln -sf "${dev}" "/var/lib/nvidia${dev}"
done
