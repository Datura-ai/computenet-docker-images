#!/usr/bin/env bash
set -ex

apt-get update
apt-get install -y unison

# FIXME move unison home dir out of profile

mkdir -p /etc/unison/
chown root:root /etc/unison/

# FIXME Find and test Trash and other dirs
# FIXME Test Browser only
cat >/etc/unison/kasm-profile.prf <<EOL
root = /home/kasm-user/
root = /kasm_profile_sync/
prefer = /home/kasm-user/


# Desktop Trash Directories
ignore = Name .Trash*
ignore = Path .local/share/Trash

# Chromium Cache directory
ignore = Path .cache/chromium

# Chrome Downloads in progress
ignore = Name *.crdownload

# Other
ignore = Name .Xauthority
ignore = Path .config/pulse
ignore = Path .unison

diff = diff -y -W 79 --suppress-common-lines
log = true
logfile = /var/log/unison/unison.log
auto = true
batch = true
EOL

mkdir -p /var/log/unison/
chown -R root:root /var/log/unison/
