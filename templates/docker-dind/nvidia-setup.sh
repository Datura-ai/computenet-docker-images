#!/bin/bash
# Create directory structure
mkdir -p /var/lib/nvidia/dev

# Create symlinks from host devices to our local paths
for dev in /dev/nvidia*; do
  ln -sf $dev /var/lib/nvidia$dev
done