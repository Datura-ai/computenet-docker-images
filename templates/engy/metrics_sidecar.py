"""Expose the engy container's token counters and miner log on :9101 for the platform.

Same contract as the Dolphin sidecar (bearer token, fail-closed, port 9101), different plumbing:
sglang serves Prometheus metrics over HTTP rather than a unix socket, and an engy container runs ONE
ENGINE PER GPU. So this fans out to every engine and stamps each series with the engine's port — the
node total is a sum in the query, and a single wedged card stays visible on its own.

  ENGY_METRICS_TARGETS=http://127.0.0.1:8000,http://127.0.0.1:8001 METRICS_TOKEN=… python3 metrics_sidecar.py

Two routes, both behind the same bearer token:
  /metrics        every engine's Prometheus exposition, stamped with the engine port
  /logs?tail=N    the tail of the miner's log, because on a miner's host the container's stdout goes
                  to a docker pipe we cannot reach, and that log is the only record of WHY a routed
                  request failed

Without METRICS_TOKEN it refuses to start: an unauthenticated port on a miner's host would publish
our token throughput, and now our logs, to whoever scans it.
"""

import http.server
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

PORT: int = int(os.environ.get("METRICS_PORT", "9101"))
TOKEN: str = os.environ.get("METRICS_TOKEN", "")
TARGETS: list[str] = [t.strip() for t in os.environ.get("ENGY_METRICS_TARGETS", "").split(",") if t.strip()]
FETCH_TIMEOUT_SECONDS: float = 5.0
# The miner's log, tee'd to disk by the entrypoint. Served on /logs so a failure can be read without
# SSH into the container and without host access to `docker logs`, which we never have on a miner box.
LOG_FILE: str = os.environ.get("ENGY_LOG_FILE", "/opt/engy/logs/miner.log")
LOG_TAIL_DEFAULT_BYTES: int = 262144
LOG_TAIL_MAX_BYTES: int = 8388608

# A Prometheus sample line: name, optional {labels}, then the value. HELP/TYPE lines and blanks pass
# through untouched — rewriting them would break the exposition format.
SAMPLE_LINE = re.compile(r"^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)(?P<labels>\{.*\})?(?P<rest>\s+.+)$")


def _log(message: str) -> None:
    print(f"[engy-metrics] {message}", file=sys.stderr, flush=True)


def label_with_engine(body: str, engine_port: str) -> str:
    """Add engine="<port>" to every sample line so N engines can share one exposition."""
    labelled: list[str] = []
    for line in body.splitlines():
        match = SAMPLE_LINE.match(line) if line and not line.startswith("#") else None
        if match is None:
            labelled.append(line)
            continue
        existing_labels: str = match.group("labels") or ""
        merged_labels: str = (
            existing_labels[:-1] + f',engine="{engine_port}"}}' if existing_labels else f'{{engine="{engine_port}"}}'
        )
        labelled.append(f"{match.group('name')}{merged_labels}{match.group('rest')}")
    return "\n".join(labelled)


def fetch_engine_metrics(target: str) -> str | None:
    engine_port: str = target.rsplit(":", 1)[-1]
    try:
        with urllib.request.urlopen(f"{target}/metrics", timeout=FETCH_TIMEOUT_SECONDS) as response:
            body: str = response.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError, ValueError) as error:
        _log(f"engine {target} unreachable: {error!r}")
        return None
    return label_with_engine(body, engine_port)


def collect() -> tuple[bytes, int]:
    """Every reachable engine's metrics, plus how many answered.

    A dead engine is skipped rather than failing the whole scrape: on a multi-card node the surviving
    engines are still earning, and the reachable-count series is what says a card went quiet.
    """
    chunks: list[str] = []
    reachable: int = 0
    for target in TARGETS:
        body: str | None = fetch_engine_metrics(target)
        if body is None:
            continue
        reachable += 1
        chunks.append(body)
    chunks.append(
        "# HELP engy_sidecar_engines_reachable Engines that answered the last scrape.\n"
        "# TYPE engy_sidecar_engines_reachable gauge\n"
        f"engy_sidecar_engines_reachable {reachable}\n"
        "# HELP engy_sidecar_engines_configured Engines this container was told to scrape.\n"
        "# TYPE engy_sidecar_engines_configured gauge\n"
        f"engy_sidecar_engines_configured {len(TARGETS)}\n"
    )
    return ("\n".join(chunks) + "\n").encode("utf-8"), reachable


def read_log_tail(max_bytes: int) -> bytes:
    """The last `max_bytes` of the miner log, starting at the first whole line.

    Reads once, into one buffer: this can be several MB and the server threads one connection per
    client, so a slice-off-the-partial-line would double the peak for every concurrent reader.
    """
    try:
        with open(LOG_FILE, "rb") as handle:
            size: int = os.fstat(handle.fileno()).st_size
            if size > max_bytes:
                handle.seek(size - max_bytes)
                handle.readline()
            return handle.read()
    except OSError as error:
        return f"log unavailable: {error!r}\n".encode()


def requested_tail_bytes(query: str) -> int:
    tail_values: list[str] = urllib.parse.parse_qs(query).get("tail", [])
    if tail_values and tail_values[0].isdigit():
        return min(int(tail_values[0]), LOG_TAIL_MAX_BYTES)
    return LOG_TAIL_DEFAULT_BYTES


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        return  # otherwise one access-log line per scrape, forever

    def _reply(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def do_GET(self) -> None:  # noqa: N802
        route, _, query = self.path.partition("?")
        if route not in ("/metrics", "/logs"):
            self._reply(404, b"not found\n", "text/plain")
            return
        if not self._authorized():
            self._reply(401, b"unauthorized\n", "text/plain")
            return
        if route == "/logs":
            self._reply(200, read_log_tail(requested_tail_bytes(query)), "text/plain")
            return
        body, reachable = collect()
        # 503 when nothing answered: an empty 200 reads as "this node earns zero", which is a very
        # different alert from "the scrape could not reach the engines".
        self._reply(200 if reachable else 503, body, "text/plain; version=0.0.4")


def main() -> None:
    if not TOKEN:
        _log("METRICS_TOKEN is required — refusing to expose an unauthenticated metrics port.")
        raise SystemExit(1)
    if not TARGETS:
        _log("ENGY_METRICS_TARGETS is empty — nothing to scrape.")
        raise SystemExit(1)
    _log(f"serving :{PORT}/metrics for {len(TARGETS)} engine(s)")
    http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
