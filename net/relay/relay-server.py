#!/usr/bin/env python3
"""
AgentoNet Relay Server
======================
A minimal TCP pipe for NAT traversal. Routes incoming HTTP requests
to the right device without ever reading or storing content.

Design principles:
  - Stateless: no database, no disk writes
  - Blind:     never inspects content, only headers for routing
  - Open:      fully open source, self-hostable on any $5 VPS
  - Fast:      async I/O, handles thousands of concurrent tunnels

Deploy:
  python3 relay-server.py --port 443 --domain relay.agentos.dev

The relay does TWO things:
  1. Accepts persistent WebSocket connections from devices (tunnel registration)
  2. Accepts HTTP requests from users and forwards them to the right device tunnel
"""

import asyncio
import json
import logging
import time
import argparse
import hashlib
from collections import defaultdict

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [relay] %(levelname)s %(message)s'
)
log = logging.getLogger('relay')

# ── Connection Registry ───────────────────────────────────────────────────────

class NodeRegistry:
    """Tracks which devices are currently connected via their persistent tunnel."""

    def __init__(self):
        # node_id → asyncio.Queue (for forwarding requests)
        self._nodes = {}
        # node_id → last_seen timestamp
        self._last_seen = {}

    def register(self, node_id: str, request_queue: asyncio.Queue):
        self._nodes[node_id] = request_queue
        self._last_seen[node_id] = time.time()
        log.info(f"node registered: {node_id} ({len(self._nodes)} total)")

    def unregister(self, node_id: str):
        self._nodes.pop(node_id, None)
        log.info(f"node disconnected: {node_id} ({len(self._nodes)} total)")

    def is_online(self, node_id: str) -> bool:
        return node_id in self._nodes

    def get_queue(self, node_id: str):
        return self._nodes.get(node_id)

    def last_seen(self, node_id: str) -> float:
        return self._last_seen.get(node_id, 0)

    def online_count(self) -> int:
        return len(self._nodes)


registry = NodeRegistry()

# ── Access stats (in-memory, resets on restart — intentional) ─────────────────

access_counts = defaultdict(int)   # cid → count
access_times  = defaultdict(list)  # cid → [timestamp, ...]

def record_access(node_id: str, cid: str):
    access_counts[cid] += 1
    access_times[cid].append(time.time())
    # Keep only last 100 timestamps per CID
    if len(access_times[cid]) > 100:
        access_times[cid] = access_times[cid][-100:]


# ── HTTP Server ───────────────────────────────────────────────────────────────

async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    """
    Handle an incoming HTTP request from a user wanting to access content.
    Parse the node_id from the URL, forward to the device tunnel.
    """
    peer = writer.get_extra_info('peername')
    try:
        # Read HTTP request headers
        raw_headers = b""
        while True:
            line = await asyncio.wait_for(reader.readline(), timeout=10.0)
            raw_headers += line
            if line in (b"\r\n", b"\n", b""):
                break

        if not raw_headers:
            writer.close()
            return

        headers_text = raw_headers.decode('utf-8', errors='replace')
        first_line = headers_text.split('\r\n')[0].split('\n')[0]
        parts = first_line.split(' ')
        if len(parts) < 2:
            await send_error(writer, 400, "Bad Request")
            return

        method, path = parts[0], parts[1]

        # ── Route: /register (device registration) ───────────────────────────
        if path == '/register':
            await handle_register(reader, writer, raw_headers, peer)
            return

        # ── Route: /status (health check) ────────────────────────────────────
        if path in ('/status', '/health'):
            await send_json(writer, {
                "status": "ok",
                "nodes_online": registry.online_count(),
                "uptime": time.time()
            })
            return

        # ── Route: /pub/<node_id>/<cid>/<filename> ───────────────────────────
        # ── Route: /sel/<node_id>/<cid>/<token>/<filename> ───────────────────
        # ── Route: /prv/<node_id>/<cid>/<bundle>/<filename> ──────────────────
        path_parts = [p for p in path.split('/') if p]
        if len(path_parts) < 3:
            await send_error(writer, 404, "Not Found")
            return

        mode    = path_parts[0]   # pub | sel | prv
        node_id = path_parts[1]
        cid     = path_parts[2]

        if mode not in ('pub', 'sel', 'prv'):
            await send_error(writer, 404, "Not Found")
            return

        # Check if device is online
        if not registry.is_online(node_id):
            last = registry.last_seen(node_id)
            ago  = int(time.time() - last) if last else None
            await send_offline_page(writer, node_id, cid, ago)
            return

        # Forward request to device tunnel
        record_access(node_id, cid)
        q = registry.get_queue(node_id)
        if q is None:
            await send_error(writer, 502, "Device Disconnected")
            return

        # Create a future for the device to reply on
        reply_queue = asyncio.Queue()
        await q.put({
            "method":      method,
            "path":        path,
            "headers":     headers_text,
            "client_ip":   str(peer[0]) if peer else "unknown",
            "reply_queue": reply_queue,
            "body_reader": reader,
        })

        # Wait for device to start sending response (timeout: 30s)
        try:
            response = await asyncio.wait_for(reply_queue.get(), timeout=30.0)
        except asyncio.TimeoutError:
            await send_error(writer, 504, "Device Timeout")
            return

        # Stream response back to client — relay is just a pipe here
        writer.write(response["headers"].encode())
        await writer.drain()

        # Stream body
        body_reader = response.get("body_reader")
        if body_reader:
            while True:
                chunk = await asyncio.wait_for(body_reader.read(65536), timeout=60.0)
                if not chunk:
                    break
                writer.write(chunk)
                await writer.drain()

    except asyncio.TimeoutError:
        pass
    except Exception as e:
        log.debug(f"client error from {peer}: {e}")
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def handle_register(reader, writer, raw_headers, peer):
    """
    Device opens a persistent connection here.
    We keep it alive and use it to forward incoming requests.
    """
    # Read JSON body with node_id
    body_len = 0
    for line in raw_headers.decode().split('\r\n'):
        if line.lower().startswith('content-length:'):
            body_len = int(line.split(':')[1].strip())

    body = b""
    if body_len > 0:
        body = await asyncio.wait_for(reader.read(min(body_len, 4096)), timeout=5.0)

    try:
        data = json.loads(body)
        node_id = data.get("node_id", "")
        if not node_id or len(node_id) > 64:
            await send_error(writer, 400, "Invalid node_id")
            return
    except json.JSONDecodeError:
        await send_error(writer, 400, "Invalid JSON")
        return

    # Send 200 OK — keep connection open
    writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\n\r\nREADY\n")
    await writer.drain()

    # Register this node
    request_queue = asyncio.Queue(maxsize=100)
    registry.register(node_id, request_queue)

    try:
        # Process forwarded requests from the queue
        while True:
            req = await asyncio.wait_for(request_queue.get(), timeout=60.0)

            # Send the forwarded request to the device over this connection
            # Device reads it, fetches the local file, sends back the response
            req_json = json.dumps({
                "method":    req["method"],
                "path":      req["path"],
                "client_ip": req["client_ip"],
            })
            writer.write(f"REQUEST {len(req_json)}\n".encode())
            writer.write(req_json.encode())
            writer.write(b"\n")
            await writer.drain()

            # Read response header from device
            resp_header_line = await asyncio.wait_for(reader.readline(), timeout=10.0)
            if not resp_header_line.startswith(b"RESPONSE"):
                req["reply_queue"].put_nowait({"headers": "HTTP/1.1 502 Bad Gateway\r\n\r\n", "body_reader": None})
                continue

            # Read HTTP headers from device
            http_headers = b""
            while True:
                line = await asyncio.wait_for(reader.readline(), timeout=5.0)
                http_headers += line
                if line in (b"\r\n", b"\n"):
                    break

            # Tell the client handler it can stream from this reader
            req["reply_queue"].put_nowait({
                "headers":     http_headers.decode(),
                "body_reader": reader,
            })

            # Wait until client is done reading
            await req["reply_queue"].join()

    except asyncio.TimeoutError:
        pass  # Device went quiet — normal keepalive timeout
    except Exception as e:
        log.debug(f"device tunnel error ({node_id}): {e}")
    finally:
        registry.unregister(node_id)
        try:
            writer.close()
        except Exception:
            pass


# ── HTTP response helpers ─────────────────────────────────────────────────────

async def send_json(writer, data: dict, status: int = 200):
    body = json.dumps(data, indent=2).encode()
    resp = (
        f"HTTP/1.1 {status} OK\r\n"
        f"Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Access-Control-Allow-Origin: *\r\n"
        f"\r\n"
    ).encode() + body
    writer.write(resp)
    await writer.drain()
    writer.close()


async def send_error(writer, code: int, msg: str):
    body = f"<h1>{code} {msg}</h1>".encode()
    resp = (
        f"HTTP/1.1 {code} {msg}\r\n"
        f"Content-Type: text/html\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"\r\n"
    ).encode() + body
    writer.write(resp)
    await writer.drain()
    writer.close()


async def send_offline_page(writer, node_id: str, cid: str, ago_seconds):
    ago_str = f"{ago_seconds}s ago" if ago_seconds else "unknown"
    body = f"""<!DOCTYPE html>
<html>
<head><title>Content Offline — AgentoNet</title>
<style>body{{font-family:system-ui;max-width:600px;margin:4em auto;color:#333}}
h1{{color:#e44}}small{{color:#999}}</style></head>
<body>
<h1>This content is temporarily offline</h1>
<p>The device serving this content is not currently reachable.</p>
<p><small>Node: {node_id[:8]}... &nbsp;|&nbsp; Last seen: {ago_str}</small></p>
<p><small>CID: {cid}</small></p>
<hr>
<p><small>Served by <a href="https://github.com/agentos/relay">AgentoNet relay</a>
— content is never stored on this server.</small></p>
</body></html>""".encode()

    resp = (
        f"HTTP/1.1 503 Service Unavailable\r\n"
        f"Content-Type: text/html\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Retry-After: 60\r\n"
        f"\r\n"
    ).encode() + body
    writer.write(resp)
    await writer.drain()
    writer.close()


# ── Main ──────────────────────────────────────────────────────────────────────

async def main(host: str, port: int):
    server = await asyncio.start_server(handle_client, host, port)
    log.info(f"AgentoNet relay listening on {host}:{port}")
    log.info("Content is never stored — this relay is just a pipe.")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="AgentoNet Relay Server")
    parser.add_argument("--host",   default="0.0.0.0",          help="Bind address")
    parser.add_argument("--port",   default=8888, type=int,      help="Listen port")
    args = parser.parse_args()
    asyncio.run(main(args.host, args.port))
