#!/bin/sh
# Stub dolphinpod-worker for entrypoint integration tests: "update" succeeds,
# "start" sleeps forever and dies on TERM like the real worker.
case "$1" in
    update) exit 0 ;;
    start) exec sleep 3600 ;;
    *) exit 0 ;;
esac
