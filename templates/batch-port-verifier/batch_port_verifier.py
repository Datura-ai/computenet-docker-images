"""Batch HTTP port verifier - starts multiple HTTP servers on different ports"""
from __future__ import annotations

import asyncio
import os

from aiohttp import web

# Configuration
HOST = "0.0.0.0"
API_PORT = int(os.environ.get("API_PORT", "19999"))

# Global state: stores active servers (AppRunner and TCPSite)
ACTIVE_SERVERS: dict[int, tuple[web.AppRunner, web.TCPSite]] = {}


async def port_handler(port: int, secret: str, request: web.Request) -> web.Response:
    """HTTP handler for each port - returns port and secret"""
    return web.Response(text=f"{port}_{secret}\n")


async def start_single_http_server(port: int, secret: str) -> tuple[web.AppRunner, web.TCPSite]:
    """Starts a single HTTP server on specified port"""
    app = web.Application()
    # Add handler for any path
    app.router.add_get("/{tail:.*}", lambda req: port_handler(port, secret, req))

    runner = web.AppRunner(app, access_log=None)
    await runner.setup()

    site = web.TCPSite(runner, HOST, port)
    await site.start()

    print(f"HTTP server started on port {port}")
    return runner, site


async def stop_single_http_server(port: int) -> None:
    """Stops a single HTTP server"""
    server_tuple = ACTIVE_SERVERS.pop(port, None)
    if server_tuple:
        runner, site = server_tuple
        await site.stop()
        await runner.cleanup()
        print(f"Port {port} closed")


# --- API HTTP request handlers ---


async def health_check(request: web.Request) -> web.Response:
    """GET /health - Health check"""
    return web.json_response({"status": "ok"})


async def start_ports(request: web.Request) -> web.Response:
    """POST /start-ports - Starts HTTP servers on multiple ports"""
    try:
        data = await request.json()
        ports = data.get("ports", [])
        secret = data.get("secret", "")

        if not ports:
            return web.json_response({"error": "No ports provided"}, status=400)
        if len(ports) > 1000:
            return web.json_response(
                {"error": "Too many ports requested. Maximum is 1000."}, status=400
            )

        ports_to_start = [p for p in ports if p not in ACTIVE_SERVERS]

        if not ports_to_start:
            return web.json_response(
                {
                    "status": "servers_started",
                    "requested": len(ports),
                    "started": 0,
                    "failed": 0,
                    "failed_ports": [],
                    "active_ports": sorted(list(ACTIVE_SERVERS.keys())),
                }
            )

        tasks = [start_single_http_server(p, secret) for p in ports_to_start]
        results = await asyncio.gather(*tasks, return_exceptions=True)

        started_count = 0
        failed_ports = []
        for i, res in enumerate(results):
            port = ports_to_start[i]

            if isinstance(res, tuple):
                ACTIVE_SERVERS[port] = res
                started_count += 1
            else:
                failed_ports.append(port)
                print(f"Failed to start on port {port}: {res}")

        return web.json_response(
            {
                "status": "servers_started",
                "requested": len(ports),
                "started": started_count,
                "failed": len(failed_ports),
                "failed_ports": sorted(failed_ports),
                "active_ports": sorted(list(ACTIVE_SERVERS.keys())),
            }
        )
    except Exception as e:
        return web.json_response({"error": str(e)}, status=400)


async def stop_ports(request: web.Request) -> web.Response:
    """POST /stop-ports - Stops HTTP servers"""
    try:
        data = await request.json()
        ports = data.get("ports", [])
        if not ports:
            return web.json_response({"error": "No ports provided"}, status=400)

        ports_to_stop = [p for p in ports if p in ACTIVE_SERVERS]
        not_found_count = len(ports) - len(ports_to_stop)

        tasks = [stop_single_http_server(p) for p in ports_to_stop]
        results = await asyncio.gather(*tasks, return_exceptions=True)

        failed_count = sum(1 for res in results if isinstance(res, Exception))
        stopped_count = len(tasks) - failed_count

        return web.json_response(
            {
                "status": "servers_stopped",
                "requested": len(ports),
                "stopped": stopped_count,
                "not_found": not_found_count,
                "failed": failed_count,
                "active_ports": sorted(list(ACTIVE_SERVERS.keys())),
            }
        )
    except Exception as e:
        return web.json_response({"error": str(e)}, status=400)


def main() -> None:
    """Configures and runs API HTTP server"""
    app = web.Application()
    app.router.add_get("/health", health_check)
    app.router.add_post("/start-ports", start_ports)
    app.router.add_post("/stop-ports", stop_ports)

    print(f"Starting API HTTP Server on {HOST}:{API_PORT}")
    print("Endpoints:")
    print("  GET  /health - Health check")
    print('  POST /start-ports - Start HTTP servers (JSON: {"ports": [...], "secret": "..."})')
    print('  POST /stop-ports - Stop HTTP servers (JSON: {"ports": [...]})')

    web.run_app(app, host=HOST, port=API_PORT, access_log=None)


if __name__ == "__main__":
    main()
