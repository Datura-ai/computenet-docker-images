"""Expose the engy container's token counters and miner log on :9101 for the platform.

Same contract as the Dolphin sidecar (bearer token, fail-closed, port 9101), different plumbing:
sglang serves Prometheus metrics over HTTP rather than a unix socket, and an engy container runs ONE
ENGINE PER GPU. So this fans out to every engine and stamps each series with the engine's port — the
node total is a sum in the query, and a single wedged card stays visible on its own.

  ENGY_METRICS_TARGETS=http://127.0.0.1:8000,http://127.0.0.1:8001 METRICS_TOKEN=… python3 metrics_sidecar.py

Two routes, both behind the same bearer token:
  /metrics        every engine's Prometheus exposition stamped with the engine port, plus each
                  miner's event-loop-lag series read off disk (see loop_probe.py)
  /logs?tail=N    the tail of the miner's log, because on a miner's host the container's stdout goes
                  to a docker pipe we cannot reach, and that log is the only record of WHY a routed
                  request failed

Without METRICS_TOKEN it refuses to start: an unauthenticated port on a miner's host would publish
our token throughput, and now our logs, to whoever scans it.
"""

import hmac
import http.client
import http.server
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PORT: int = int(os.environ.get("METRICS_PORT", "9101"))
TOKEN: str = os.environ.get("METRICS_TOKEN", "")
TARGETS: list[str] = [t.strip() for t in os.environ.get("ENGY_METRICS_TARGETS", "").split(",") if t.strip()]
# ONE deadline for the whole fan-out, not per engine. A fixed per-target timeout silently drops
# the tail once a node runs many engines: 8 cards x a slow /metrics is 40s sequentially, long past
# any scraper's patience, so the last engines vanish from the body — the exact undercount this
# fan-out exists to prevent. Shape borrowed from templates/dolphin.
TOTAL_BUDGET_SECONDS: float = min(4.0 + 0.4 * max(0, len(TARGETS) - 1), 7.0)
# A stale port can host a non-HTTP listener and sglang can die mid-response; cap what we read.
MAX_BODY_BYTES: int = 5 * 1024 * 1024
UNREACHABLE_LOG_INTERVAL_SECONDS: float = 300.0
# The miner's log, tee'd to disk by the entrypoint. Served on /logs so a failure can be read without
# SSH into the container and without host access to `docker logs`, which we never have on a miner box.
LOG_FILE: str = os.environ.get("ENGY_LOG_FILE", "/opt/engy/logs/miner.log")
LOG_TAIL_DEFAULT_BYTES: int = 262144
LOG_TAIL_MAX_BYTES: int = 8388608
# Where the miners drop their event-loop-lag expositions (loop_probe.py). Read from disk rather than
# scraped over a port: the miner has no listener, and adding one to the process whose loop we are
# measuring would make the measurement depend on the thing being measured.
PROBE_DIR: str = os.environ.get("ENGY_PROBE_DIR", "")
MAX_PROBE_BYTES: int = 65536

# A Prometheus sample line: name, optional {labels}, then the value. HELP/TYPE lines and blanks pass
# through untouched — rewriting them would break the exposition format.
SAMPLE_LINE = re.compile(r"^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)(?P<labels>\{.*\})?(?P<rest>\s+.+)$")


_last_unreachable_log: dict[str, float] = {}


def _log(message: str) -> None:
    print(f"[engy-metrics] {message}", file=sys.stderr, flush=True)


def _log_unreachable(target: str, error: BaseException) -> None:
    """Rate-limited: a crash-looping engine must not flood the log we now serve over /logs."""
    now: float = time.monotonic()
    if now - _last_unreachable_log.get(target, 0.0) < UNREACHABLE_LOG_INTERVAL_SECONDS:
        return
    _last_unreachable_log[target] = now
    _log(f"engine {target} unreachable: {error!r}")


def label_with_engine(body: str, engine_port: str) -> str:
    """Add engy_engine="<port>" to every sample line so N engines can share one exposition.

    Namespaced on purpose: sglang already labels its own samples engine_type=, and a bare `engine`
    key colliding with one of its own would make the exposition invalid.
    """
    labelled: list[str] = []
    for line in body.splitlines():
        match = SAMPLE_LINE.match(line) if line and not line.startswith("#") else None
        if match is None:
            labelled.append(line)
            continue
        existing_labels: str = match.group("labels") or ""
        merged_labels: str = (
            existing_labels[:-1] + f',engy_engine="{engine_port}"}}'
            if existing_labels
            else f'{{engy_engine="{engine_port}"}}'
        )
        labelled.append(f"{match.group('name')}{merged_labels}{match.group('rest')}")
    return "\n".join(labelled)


def fetch_engine_metrics(target: str, deadline: float) -> str | None:
    engine_port: str = target.rsplit(":", 1)[-1]
    remaining: float = deadline - time.monotonic()
    if remaining <= 0:
        _log_unreachable(target, TimeoutError("scrape budget spent before this engine was reached"))
        return None
    try:
        with urllib.request.urlopen(f"{target}/metrics", timeout=remaining) as response:
            raw: bytes = response.read(MAX_BODY_BYTES + 1)
    # http.client.HTTPException is NOT an OSError, and urllib re-raises it unwrapped: a stale port
    # hosting a non-HTTP listener, or sglang dying mid-response, would kill the handler thread and
    # the scraper would see a connection reset instead of a body.
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as error:
        _log_unreachable(target, error)
        return None
    if len(raw) > MAX_BODY_BYTES:
        _log_unreachable(target, ValueError(f"body over {MAX_BODY_BYTES} bytes"))
        return None
    return label_with_engine(raw.decode("utf-8", "replace"), engine_port)


def metric_family(sample_name: str) -> str:
    """The family a sample belongs to; histogram and counter suffixes share one HELP/TYPE block."""
    for suffix in ("_bucket", "_sum", "_count", "_created", "_total"):
        if sample_name.endswith(suffix):
            return sample_name[: -len(suffix)]
    return sample_name


def merge_engine_bodies(bodies: list[str]) -> str:
    """Regroup N engines' samples so each family's HELP/TYPE and all of its samples stay contiguous.

    Concatenating whole bodies repeats every HELP/TYPE once per engine and interleaves families.
    Prometheus rejects a second HELP for a metric name, so on a multi-GPU node the WHOLE scrape was
    invalid, not one series. Measured on the 8-card prod node: 499 HELP lines for 65 families.
    """
    comments: dict[str, list[str]] = {}
    samples: dict[str, list[str]] = {}
    families_in_order: list[str] = []
    for body in bodies:
        for line in body.splitlines():
            if not line.strip():
                continue
            if line.startswith("#"):
                parts: list[str] = line.split(maxsplit=3)
                if len(parts) >= 3 and parts[1] in ("HELP", "TYPE"):
                    family: str = metric_family(parts[2])
                    if family not in families_in_order:
                        families_in_order.append(family)
                    if line not in comments.setdefault(family, []):
                        comments[family].append(line)
                continue
            match = SAMPLE_LINE.match(line)
            if match is None:
                continue
            family = metric_family(match.group("name"))
            if family not in families_in_order:
                families_in_order.append(family)
            samples.setdefault(family, []).append(line)
    merged: list[str] = []
    for family in families_in_order:
        merged.extend(comments.get(family, []))
        merged.extend(samples.get(family, []))
    return "\n".join(merged)


def read_probe_bodies() -> list[str]:
    """Every miner's loop-lag exposition. A miner that died leaves its last file behind on purpose —
    it carries its own written-at timestamp, and a frozen series says more than a vanished one."""
    if not PROBE_DIR:
        return []
    try:
        names: list[str] = sorted(os.listdir(PROBE_DIR))
    except OSError as error:
        _log_unreachable(PROBE_DIR, error)
        return []
    bodies: list[str] = []
    for name in names:
        if not name.endswith(".prom"):
            continue                                   # skips the .tmp a concurrent write is using
        path: str = os.path.join(PROBE_DIR, name)
        try:
            with open(path, "rb") as handle:
                raw: bytes = handle.read(MAX_PROBE_BYTES)
        except OSError as error:
            _log_unreachable(path, error)
            continue
        bodies.append(raw.decode("utf-8", "replace"))
    return bodies


def collect() -> tuple[bytes, int]:
    """Every reachable engine's metrics, plus how many answered.

    A dead engine is skipped rather than failing the whole scrape: on a multi-card node the surviving
    engines are still earning, and the reachable-count series is what says a card went quiet.
    """
    deadline: float = time.monotonic() + TOTAL_BUDGET_SECONDS
    bodies: list[str] = []
    for target in TARGETS:
        body: str | None = fetch_engine_metrics(target, deadline)
        if body is not None:
            bodies.append(body)
    own_series: str = (
        "# HELP engy_sidecar_engines_reachable Engines that answered the last scrape.\n"
        "# TYPE engy_sidecar_engines_reachable gauge\n"
        f"engy_sidecar_engines_reachable {len(bodies)}\n"
        "# HELP engy_sidecar_engines_configured Engines this container was told to scrape.\n"
        "# TYPE engy_sidecar_engines_configured gauge\n"
        f"engy_sidecar_engines_configured {len(TARGETS)}\n"
    )
    merged: str = merge_engine_bodies(bodies + read_probe_bodies() + [own_series])
    return (merged + "\n").encode("utf-8"), len(bodies)


def read_log_tail(max_bytes: int) -> bytes:
    """The last `max_bytes` of the miner log, starting at the first whole line.

    Reads once, into one buffer: this can be several MB and the server threads one connection per
    client, so a slice-off-the-partial-line would double the peak for every concurrent reader.
    """
    try:
        with open(LOG_FILE, "rb") as handle:
            size: int = os.fstat(handle.fileno()).st_size
            start: int = max(0, size - max_bytes)
            handle.seek(start)
            if start:
                handle.readline()
            tail: bytes = handle.read()
            if tail or not start:
                return tail
            # The whole window sat inside ONE unterminated line, so skipping the partial line ate
            # everything. Real logs do this: sglang and huggingface progress bars redraw with \r, and
            # a single such line was measured at 11.9KB on a live node. A mid-line fragment beats
            # answering an empty body.
            handle.seek(start)
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
        # Constant-time, like templates/dolphin: a plain == leaks the token one byte at a time to
        # anyone who can time this port, and it now guards our logs rather than just counters.
        return hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {TOKEN}")

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
