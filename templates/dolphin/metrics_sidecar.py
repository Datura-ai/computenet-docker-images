"""Metrics sidecar for the Dolphin filler: proxies vLLM's /metrics from its
unix socket onto TCP :9101 so the platform's published-port machinery can
expose it to the lium-stats scraper.

Design constraints (DAH-2468):
- stdlib only, must never interfere with the worker; a crash is fine — the
  entrypoint restart loop brings it back (with backoff).
- Verbatim pass-through of the vLLM Prometheus text (no parsing at the edge),
  plus appended dolphin_sidecar_* series. vLLM down still answers 200 with
  the sidecar series only, so the scraper can tell "worker dead" from
  "sidecar dead" from "machine dead".

Multi-engine (DAH-2465): one container may run N worker instances, one per GPU
bundle, so N vLLM engines answer on N unix sockets. Every engine is scraped and
all bodies are concatenated, each series tagged with the engine's own
`dolphin_engine` label. That label is what keeps N engines from collapsing into
one label set — the lium-stats ETL sums its counters ACROSS label sets
(DESIGN.md 244-249), so tagging is all that is needed for the machine total to
stay correct with no ETL change. Picking one engine (the pre-DAH-2465 "first
good response wins") would have silently published 1/N of the tokens.
- Fail closed: without METRICS_TOKEN every request gets 503 — this port is
  published to the internet, never serve it unauthenticated.
- Total upstream budget per request stays under the scraper's client timeout
  even when falling through several stale sockets.
- Read-only: the sidecar observes and republishes, it never acts on the worker.
  Acting is watchdog.py's job; this file only exposes the state files it writes
  (one per GPU bundle in split mode) as dolphin_watchdog_* series, so the
  restarts reach the scraper.
"""

import glob
import hmac
import http.client
import http.server
import json
import os
import socket
import sys
import time

from dataclasses import dataclass

PORT = int(os.environ.get("METRICS_PORT", "9101"))
TOKEN = os.environ.get("METRICS_TOKEN", "")
SOCKET_GLOB = os.environ.get("METRICS_SOCKET_GLOB", "/tmp/dp-*/v.sock")
# Written every tick by watchdog.py; absent when the watchdog is disabled or not shipped.
# NOT under DOLPHIN_HOME: since lium-io#1161 that directory is a cache volume the platform
# mounts into EVERY filler container on the node, so a state file there is one file shared by
# every watchdog on the host — each overwriting the others' counters, and each inheriting a
# neighbour's last_restart_timestamp on startup, which suppresses its own kill for a grace
# period. /tmp is the container's own filesystem (the engine's unix socket lives there for the
# same reason), so a state file belongs to exactly one watchdog and dies with its container.
# Split mode runs one watchdog — and one state file — per GPU bundle, so the default is a
# glob; DOLPHIN_WATCHDOG_STATE pins a single file when the caller knows which one it wants,
# and SINGLE_ENGINE_STATE_PATH is where an unscoped watchdog writes.
SINGLE_ENGINE_STATE_PATH = "/tmp/dolphin_watchdog_state.json"
WATCHDOG_STATE_PATH = os.environ.get("DOLPHIN_WATCHDOG_STATE", "")
WATCHDOG_STATE_GLOB = os.environ.get(
    "DOLPHIN_WATCHDOG_STATE_GLOB", "/tmp/dolphin_watchdog_state*.json"
)
# How many engines the entrypoint spawned. Exported so a missing engine reads as a gap
# (up < expected) instead of as a smaller token number that looks like a quiet machine.
# 0 means "unknown" — the single-worker image does not set it.
ENGINES_EXPECTED = int(os.environ.get("DOLPHIN_ENGINES_EXPECTED", "0") or "0")
SIDECAR_VERSION = 2
# One deadline covers ALL engines, so a fixed 4 s silently drops the tail once a node runs many
# of them: 8 engines x a slow /metrics would exhaust it and the last engines would vanish from
# the body — the very undercount this fan-out exists to prevent. Grow with the engine count but
# stay under the scraper's 8 s client timeout.
TOTAL_BUDGET_S = min(4.0 + 0.4 * max(0, ENGINES_EXPECTED - 1), 7.0)
CONNECT_TIMEOUT_S = 1.0
MAX_BODY_BYTES = 5 * 1024 * 1024
LOG_INTERVAL_S = 10.0
# Prometheus text exposition format version — NOT the image version, which it once
# coincided with. Do not bump this when bumping the image tag.
PROM_CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"

_last_ok_ts: float = 0.0
_last_socket: str = ""
_last_error: str | None = None
_last_log_ts: float = 0.0


def _optional_float(value: object) -> float | None:
    return None if value is None else float(value)


@dataclass(frozen=True)
class WatchdogState:
    """What watchdog.py writes every tick. Declared here because three parties read these
    names — the sidecar below, the watchdog itself after its own restart, and the tests —
    and a key renamed on one side only makes the whole dolphin_watchdog_* group disappear,
    which on a dashboard is indistinguishable from a watchdog that was never installed.
    In split mode one of these is written per GPU bundle, which is what gpus + engine_socket
    are for: telling N states apart and labelling them."""

    updated: float
    # Widest gap a healthy watchdog may leave between writes; the watchdog owns the number
    # because only it knows how long its slowest tick (the one that kills an engine) takes.
    max_write_gap_s: float
    restarts_total: int
    last_restart_timestamp: float
    stall_seconds: float
    # None when the engine did not answer this tick. requests_running is what tells an idle
    # queue apart from a wedge, so a high stall_seconds cannot be read without it.
    requests_running: float | None
    generated_tokens: float | None
    # Split mode only (both None in the single-engine image). engine_socket None means a
    # watchdog that is running but cannot see its engine — guarding nothing.
    gpus: str | None
    engine_socket: str | None

    @classmethod
    def read(cls, path: str) -> "WatchdogState | None":
        # None for every shape we cannot use: absent, unparsable, or written by something
        # else. Callers turn that into silence, never into invented zeros.
        try:
            with open(path) as fh:
                raw = json.load(fh)
            return cls(
                updated=float(raw["updated"]),
                max_write_gap_s=float(raw["max_write_gap_s"]),
                restarts_total=int(raw["restarts_total"]),
                last_restart_timestamp=float(raw["last_restart_timestamp"]),
                stall_seconds=float(raw["stall_seconds"]),
                requests_running=_optional_float(raw["requests_running"]),
                generated_tokens=_optional_float(raw["generated_tokens"]),
                gpus=raw["gpus"],
                engine_socket=raw["engine_socket"],
            )
        except (OSError, ValueError, TypeError, KeyError):
            return None


def _log(msg: str) -> None:
    # rate-limited: a crash-looping upstream must not flood container logs
    global _last_log_ts
    now = time.monotonic()
    if now - _last_log_ts >= LOG_INTERVAL_S:
        _last_log_ts = now
        print(f"[sidecar] {msg}", file=sys.stderr, flush=True)


@dataclass(frozen=True)
class EngineMetrics:
    """One engine's /metrics body together with the socket it came from. The socket is what
    names the engine's dolphin_engine label, so the two must not travel separately."""

    socket_path: str
    body: bytes


class UdsHTTPConnection(http.client.HTTPConnection):
    """HTTPConnection over an AF_UNIX socket path."""

    def __init__(self, path: str, timeout: float) -> None:
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self._path)
        self.sock = sock


def discover_sockets() -> list[str]:
    # newest mtime first: stale /tmp/dp-*/v.sock files survive worker restarts
    paths = glob.glob(SOCKET_GLOB)
    def mtime(p: str) -> float:
        try:
            return os.stat(p).st_mtime
        except OSError:
            return 0.0
    return sorted(paths, key=mtime, reverse=True)


def fetch_one_engine(path: str, deadline: float) -> bytes | None:
    # One engine's /metrics, inside the caller's shared deadline. None means this socket did
    # not deliver; the caller decides whether that ends the scrape or just skips one engine.
    global _last_ok_ts, _last_socket, _last_error
    conn = UdsHTTPConnection(path, timeout=min(CONNECT_TIMEOUT_S, deadline - time.monotonic()))
    try:
        conn.connect()
        conn.sock.settimeout(max(0.1, deadline - time.monotonic()))
        conn.request("GET", "/metrics")
        resp = conn.getresponse()
        if resp.status != 200:
            _last_error = f"{path}: HTTP {resp.status}"
            return None
        body = resp.read(MAX_BODY_BYTES + 1)
        if len(body) > MAX_BODY_BYTES:
            _last_error = f"{path}: body over {MAX_BODY_BYTES} bytes"
            return None
        _last_ok_ts = time.time()
        _last_socket = path
        _last_error = None
        return body
    except (OSError, http.client.HTTPException) as e:
        # a stale socket may host a non-HTTP listener, or vllm can die
        # mid-response (IncompleteRead) — the caller falls through to the next socket;
        # a crash here would defeat the 200 fail-open the scraper relies on
        _last_error = f"{path}: {e}"
        return None
    finally:
        try:
            conn.close()
        except Exception:
            pass


def fetch_vllm_metrics(sockets: list[str]) -> bytes | None:
    # try each socket within one shared deadline; first good response wins
    global _last_error
    deadline = time.monotonic() + TOTAL_BUDGET_S
    for path in sockets:
        if time.monotonic() >= deadline:
            _last_error = "budget exhausted"
            return None
        body = fetch_one_engine(path, deadline)
        if body is not None:
            return body
    return None


def engine_id(socket_path: str) -> str:
    # /tmp/dp-4f2a/v.sock -> "dp-4f2a". The worker names the directory, so this is stable for
    # the life of an engine and changes when it respawns — which is the honest behavior: a
    # respawned engine has fresh counters and must not be summed onto the old label set.
    name = os.path.basename(os.path.dirname(socket_path))
    return name or socket_path


@dataclass(frozen=True)
class LabelSplice:
    """Where a label goes in one exposition line, and what must precede it there.

    `name{a="1"} 5` splices before the closing brace behind a comma; `name 5` splices right
    after the metric name, and the caller wraps it in braces itself.
    """

    position: int
    separator: bytes


def _label_splice_point(line: bytes) -> LabelSplice | None:
    # None for a line whose label set never closes: it cannot be spliced without corrupting it.
    end = 0
    while end < len(line) and line[end] not in b"{ \t":
        end += 1
    if end >= len(line) or line[end] != ord("{"):
        return LabelSplice(position=end, separator=b"")
    # Scan for the brace that closes the label set. Label values are quoted and may themselves
    # contain braces or escaped quotes, so a plain rfind/index would cut in the wrong place.
    i = end + 1
    in_quotes = False
    while i < len(line):
        char = line[i]
        if in_quotes:
            if char == ord("\\"):
                i += 2
                continue
            if char == ord('"'):
                in_quotes = False
        elif char == ord('"'):
            in_quotes = True
        elif char == ord("}"):
            return LabelSplice(position=i, separator=b",")
        i += 1
    return None


def tag_series(body: bytes, engine_name: str) -> bytes:
    # Comments are dropped — the caller emits one deduplicated set for the whole response,
    # since HELP/TYPE are per metric name and repeating them once per engine would make the
    # exposition invalid.
    label = b'dolphin_engine="' + engine_name.encode() + b'"'
    out: list[bytes] = []
    for line in body.split(b"\n"):
        stripped = line.strip()
        if not stripped or stripped.startswith(b"#"):
            continue
        splice = _label_splice_point(stripped)
        if splice is None:
            continue  # unparseable line: better dropped than emitted corrupt
        head, tail = stripped[: splice.position], stripped[splice.position :]
        if splice.separator:
            out.append(head + splice.separator + label + tail)
        else:
            out.append(head + b"{" + label + b"}" + tail)
    return b"\n".join(out) + b"\n" if out else b""


def comment_lines(body: bytes) -> list[bytes]:
    return [line.strip() for line in body.split(b"\n") if line.strip().startswith(b"#")]


def _comment_family(comment: bytes) -> bytes:
    # "# TYPE vllm:foo histogram" -> b"vllm:foo"; anything unexpected -> b""
    parts = comment.split()
    return parts[2] if len(parts) >= 3 and parts[1] in (b"HELP", b"TYPE") else b""


def _metric_name(line: bytes) -> bytes:
    end = 0
    while end < len(line) and line[end] not in b"{ \t":
        end += 1
    return line[:end]


def _family_of(name: bytes, families: set[bytes]) -> bytes:
    # A histogram's samples are named <family>_bucket/_sum/_count, so the sample name alone
    # would split one family into three. Map back onto a declared family when one matches.
    if name in families:
        return name
    for suffix in (b"_bucket", b"_sum", b"_count", b"_created", b"_total"):
        if name.endswith(suffix) and name[: -len(suffix)] in families:
            return name[: -len(suffix)]
    return name


def merge_engine_bodies(engines: list[EngineMetrics]) -> bytes:
    # Concatenating whole bodies would interleave metric families, which makes the exposition
    # invalid. Tag each engine's samples, then regroup so every family's HELP/TYPE and all of
    # its samples (from every engine) stay contiguous.
    comments: dict[bytes, list[bytes]] = {}
    samples: dict[bytes, list[bytes]] = {}
    order: list[bytes] = []
    tagged_bodies: list[bytes] = []

    for engine in engines:
        tagged_bodies.append(tag_series(engine.body, engine_id(engine.socket_path)))
        for comment in comment_lines(engine.body):
            family = _comment_family(comment)
            if not family:
                continue
            family_comments = comments.setdefault(family, [])
            if comment not in family_comments:
                family_comments.append(comment)

    declared = set(comments)
    for tagged in tagged_bodies:
        for line in tagged.split(b"\n"):
            if not line:
                continue
            family = _family_of(_metric_name(line), declared)
            if family not in samples:
                order.append(family)
                samples[family] = []
            samples[family].append(line)

    out: list[bytes] = []
    for family in order:
        out.extend(comments.get(family, []))
        out.extend(samples[family])
    return b"\n".join(out) + b"\n" if out else b""


def fetch_all_engines(sockets: list[str]) -> list[EngineMetrics]:
    # Every engine within ONE shared deadline, so N engines cannot stretch the response past
    # the scraper's timeout. Engines that do not answer are simply absent from the result and
    # show up as up < expected. Stale socket files fail to connect and drop out the same way.
    global _last_error
    results: list[EngineMetrics] = []
    deadline = time.monotonic() + TOTAL_BUDGET_S
    for path in sockets:
        if time.monotonic() >= deadline:
            _last_error = "budget exhausted"
            break
        body = fetch_one_engine(path, deadline)
        if body is not None:
            results.append(EngineMetrics(socket_path=path, body=body))
    return results


def sidecar_series(sockets_found: int, proxy_ok: bool, engines_up: int = 0) -> bytes:
    # proxy_ok is THE engine-liveness discriminator for the scraper: stale
    # socket files can exist while the engine is dead, so sockets_found alone
    # cannot distinguish "vllm down" from "vllm schema changed".
    # engines_up vs engines_expected is the multi-worker equivalent: with N engines behind one
    # port, a dead engine only makes the token total smaller, which is indistinguishable from a
    # quiet machine. The pair makes the gap explicit. expected 0 = single-worker image.
    return (
        f"dolphin_sidecar_up 1\n"
        f"dolphin_sidecar_proxy_ok {int(proxy_ok)}\n"
        f"dolphin_sidecar_sockets_found {sockets_found}\n"
        f"dolphin_sidecar_last_proxy_ok_timestamp {int(_last_ok_ts)}\n"
        f"dolphin_sidecar_version {SIDECAR_VERSION}\n"
        f"dolphin_engines_up {engines_up}\n"
        f"dolphin_engines_expected {ENGINES_EXPECTED}\n"
    ).encode()


def watchdog_state_paths() -> list[str]:
    # Globbed per request, not at import: in split mode the files appear as each bundle's
    # watchdog starts, and a list captured at boot would miss them.
    if WATCHDOG_STATE_PATH:
        return [WATCHDOG_STATE_PATH]
    return sorted(glob.glob(WATCHDOG_STATE_GLOB))


def watchdog_samples(state: WatchdogState) -> list[tuple[str, str]]:
    age_s = time.time() - state.updated
    values = [
        # Three missed writes mean it is gone. The bound comes from the file rather than from
        # the poll interval, because the tick that kills an engine blocks far longer than a poll.
        ("dolphin_watchdog_up", str(int(age_s <= 3 * state.max_write_gap_s))),
        ("dolphin_watchdog_restarts_total", str(state.restarts_total)),
        ("dolphin_watchdog_last_restart_timestamp", str(int(state.last_restart_timestamp))),
        ("dolphin_watchdog_stall_seconds", f"{state.stall_seconds:.0f}"),
    ]
    if state.gpus:
        # Split mode only. A watchdog that cannot identify its own engine is running and
        # guarding nothing — indistinguishable from a healthy one without this series.
        values.append(("dolphin_watchdog_engine_found", str(int(bool(state.engine_socket)))))
    return values


def watchdog_series() -> bytes:
    # Empty when there is no watchdog at all — better than zeros, which would claim a
    # healthy watchdog that does not exist. A watchdog that ran and died is a different
    # story and must be visible, so a stale state file reports up 0 with its last numbers.
    #
    # With one watchdog per bundle every state is published, labelled by the cards it owns.
    # Samples are grouped by metric name rather than by state: emitting one bundle's whole
    # block after another's would split each family in two, which is invalid exposition —
    # the same reason merge_engine_bodies() regroups the engine bodies.
    grouped: dict[str, list[str]] = {}
    order: list[str] = []
    for path in watchdog_state_paths():
        state = WatchdogState.read(path)
        if state is None:
            continue
        # Unlabelled with a single engine: the shipped fleet's series must not change shape.
        label = f'{{dolphin_watchdog_gpus="{state.gpus}"}}' if state.gpus else ""
        for name, value in watchdog_samples(state):
            if name not in grouped:
                grouped[name] = []
                order.append(name)
            grouped[name].append(f"{name}{label} {value}")
    if not order:
        return b""
    return ("\n".join(line for name in order for line in grouped[name]) + "\n").encode()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "dolphin-sidecar"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        pass  # per-request access logging is pure noise on a 60s scrape

    def _reply(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        got = self.headers.get("Authorization", "")
        return hmac.compare_digest(got, f"Bearer {TOKEN}")

    def do_GET(self) -> None:  # noqa: N802
        if not TOKEN:
            # fail closed: an unset token must never mean an open port
            self._reply(503, b"METRICS_TOKEN not configured\n", "text/plain")
            _log("refusing request: METRICS_TOKEN is not set")
            return
        if not self._authorized():
            self._reply(401, b"unauthorized\n", "text/plain")
            return
        if self.path == "/metrics":
            self._get_metrics()
        elif self.path == "/health":
            self._get_health()
        else:
            self._reply(404, b"not found\n", "text/plain")

    def do_POST(self) -> None:  # noqa: N802
        self._reply(405, b"method not allowed\n", "text/plain")

    def _get_metrics(self) -> None:
        sockets = discover_sockets()
        engines = fetch_all_engines(sockets)
        if not engines:
            body = b""
            if sockets:
                _log(f"no responsive vllm socket ({len(sockets)} candidates): {_last_error}")
        elif len(engines) == 1 and ENGINES_EXPECTED <= 1:
            # Single-worker path stays byte-identical to the pre-DAH-2465 contract: the whole
            # fleet runs this today, and a label added here would change every shipped series
            # for no gain. Tagging starts where it is actually needed — at two engines.
            body = engines[0].body
            if not body.endswith(b"\n"):
                body += b"\n"
        else:
            # A split container tags from the first engine on, not from the second: keying off
            # how many answered right now would drop the label for every scrape a sibling
            # spends restarting, and a series whose label set changes is a different series to
            # the scraper — the survivor would read as gone and its relabelled self as a
            # counter starting from zero.
            body = merge_engine_bodies(engines)
        if ENGINES_EXPECTED and len(engines) < ENGINES_EXPECTED:
            # No error is the normal transient right after a restart: the engine's socket does
            # not exist yet, so there was nothing to fail. Saying "None" there reads like a bug
            # to whoever is looking at this during an incident.
            reason = f": {_last_error}" if _last_error else " (no error — engine not up yet)"
            _log(f"only {len(engines)}/{ENGINES_EXPECTED} engines answered{reason}")
        out = body + sidecar_series(len(sockets), proxy_ok=bool(engines), engines_up=len(engines))
        self._reply(200, out + watchdog_series(), PROM_CONTENT_TYPE)

    def _get_health(self) -> None:
        sockets = discover_sockets()
        payload = {
            "socket": _last_socket or None,
            "sockets_found": len(sockets),
            "last_ok": int(_last_ok_ts),
            "error": _last_error,
            "sidecar_version": SIDECAR_VERSION,
        }
        self._reply(200, json.dumps(payload).encode() + b"\n", "application/json")


def main() -> None:
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    print(f"[sidecar] serving on :{PORT} (version {SIDECAR_VERSION})", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
