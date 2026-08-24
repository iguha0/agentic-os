#!/usr/bin/env python3
"""
AgentoNet Relay v2 ("blind pipe")
=================================
NAT-traversal relay for PryzentOS. Devices behind NAT register a tunnel;
anyone fetches their content through this relay without the relay ever
understanding or storing it.

Protocol (deliberately line-based so busybox wget can be a client):

  Device:
    POST /register              body: <node_id>            -> {"ok":true}
    GET  /poll/<node>?wait=30   long-poll                  -> text lines:
                                     REQ <reqid> <method> <path>
                                     (empty = nothing pending)
    POST /respond/<node>        body:
                                     RESP <reqid> <status> <content-type>\n
                                     <raw response bytes>

  Fetcher (curl/wget/browser):
    ANY  /f/<node>/<path...>    forwarded to device        -> device's response

  Ops:
    GET  /status                registry stats
    GET  /who/<node>            online/offline + last seen

Design rules (docs/AGENTONET.md):
  - stateless-ish: memory only, restart loses routes (devices re-poll)
  - blind: never inspects content beyond routing metadata
  - self-hostable: stdlib only, single file, runs on a $5 VPS
"""

import argparse
import asyncio
import base64
import collections
import logging
import time

logging.basicConfig(level=logging.INFO,
                    format='%(asctime)s [relay] %(levelname)s %(message)s')
log = logging.getLogger('relay')

POLL_DEFAULT_WAIT = 5      # short-poll seconds (device re-polls fast)
FETCH_TIMEOUT     = 35     # give up forwarding after this many seconds
MAX_BODY          = 64 * 1024 * 1024   # 64 MB cap per response


class Node:
    __slots__ = ("pending", "last_seen", "served")

    def __init__(self):
        self.pending: collections.deque = collections.deque()
        self.last_seen = time.time()
        self.served = 0


class RelayState:
    def __init__(self):
        self.nodes: dict[str, Node] = {}
        self.responses: dict[str, tuple[int, str, bytes]] = {}
        self.events: dict[str, asyncio.Event] = {}
        self.total_fetches = 0
        self.notes: dict[str, bytes] = {}   # debug scratch: device posts state here

    def node(self, nid: str) -> Node:
        if nid not in self.nodes:
            self.nodes[nid] = Node()
        return self.nodes[nid]

    def new_request(self, nid: str, method: str, path: str) -> str:
        rid = f"{int(time.time()*1000):x}-{id(self):x}-{self.total_fetches:x}"
        n = self.node(nid)
        n.pending.append((rid, method, path))
        self.total_fetches += 1
        return rid

    def complete(self, rid: str, status: int, ctype: str, body: bytes):
        self.responses[rid] = (status, ctype, body[:MAX_BODY])
        ev = self.events.pop(rid, None)
        if ev:
            ev.set()

    async def wait_response(self, rid: str, timeout: float):
        ev = self.events.setdefault(rid, asyncio.Event())
        try:
            await asyncio.wait_for(ev.wait(), timeout=timeout)
        except asyncio.TimeoutError:
            pass
        finally:
            self.events.pop(rid, None)
            resp = self.responses.pop(rid, None)
            # stale entry cleanup if device never answered
            if resp and not ev.is_set():
                return None
            return resp


state = RelayState()


def parse_request(reader: asyncio.StreamReader):
    """Read one HTTP/1.x request head. Returns (method, path, headers)."""

    async def _inner():
        line = await reader.readline()
        if not line:
            return None
        try:
            method, path, _ = line.decode('latin1').strip().split(" ", 2)
        except ValueError:
            return None
        headers = {}
        while True:
            h = await reader.readline()
            if h in (b"\r\n", b"\n", b""):
                break
            if b":" in h:
                k, v = h.split(b":", 1)
                headers[k.strip().lower().decode()] = v.strip().decode()
        return method.upper(), path, headers

    return asyncio.wait_for(_inner(), timeout=30)


async def read_body(reader: asyncio.StreamReader, headers: dict) -> bytes:
    n = int(headers.get("content-length", "0") or 0)
    if n <= 0:
        return b""
    if n > MAX_BODY:
        raise ValueError("body too large")
    return await reader.readexactly(n)


def http_response(status: int, ctype: str, body: bytes, extra="") -> bytes:
    text = {200: "OK", 400: "Bad Request", 404: "Not Found",
            408: "Timeout", 502: "Bad Gateway", 413: "Too Large"}.get(status, "?")
    head = (
        f"HTTP/1.1 {status} {text}\r\n"
        f"Content-Type: {ctype}\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Access-Control-Allow-Origin: *\r\n"
        f"{extra}"
        f"\r\n"
    ).encode()
    return head + body


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    peer = writer.get_extra_info('peername')
    try:
        req = await parse_request(reader)
        if not req:
            return
        method, path, headers = req
        path = path.split("?", 1)[0]          # strip query string from routing

        # ── ops ──────────────────────────────────────────────────────────
        if method == "GET" and path == "/status":
            online = sum(1 for n in state.nodes.values()
                         if time.time() - n.last_seen < POLL_DEFAULT_WAIT * 4)
            body = f'{{"nodes_known":{len(state.nodes)},"nodes_online":{online},"fetches":{state.total_fetches}}}'
            writer.write(http_response(200, "application/json", body.encode()))
            await writer.drain()
            return

        parts = [p for p in path.split("/") if p]

        # ── device: register ─────────────────────────────────────────────
        if method == "POST" and len(parts) == 1 and parts[0] == "register":
            body_bytes = await read_body(reader, headers)
            nid = body_bytes.decode().strip()[:64]
            if not nid:
                writer.write(http_response(400, "application/json", b'{"error":"node_id required"}'))
            else:
                n = state.node(nid)
                n.last_seen = time.time()
                log.info(f"registered: {nid}")
                writer.write(http_response(200, "application/json", b'{"ok":true}'))
            await writer.drain()
            return

        # ── device: long-poll ────────────────────────────────────────────
        if method == "GET" and len(parts) == 2 and parts[0] == "poll":
            nid = parts[1]
            wait_s = POLL_DEFAULT_WAIT
            if "wait=" in path:
                try:
                    wait_s = max(1, min(int(path.split("wait=")[1].split("&")[0]), 55))
                except ValueError:
                    pass
            n = state.node(nid)
            deadline = time.time() + wait_s
            while time.time() < deadline:
                if n.pending:
                    break
                await asyncio.sleep(0.25)
            n.last_seen = time.time()
            lines = "".join(f"REQ {rid} {m} {p}\n" for rid, m, p in list(n.pending))
            n.pending.clear()
            writer.write(http_response(200, "text/plain", lines.encode()))
            await writer.drain()
            return

        # ── device: respond ──────────────────────────────────────────────
        if method == "POST" and len(parts) == 2 and parts[0] == "respond":
            nid = parts[1]
            state.node(nid).last_seen = time.time()
            log.info(f"[dbg] respond entering nid={nid} cl={headers.get('content-length')}")
            body_bytes = await read_body(reader, headers)
            log.info(f"[dbg] respond body={len(body_bytes)}B head={body_bytes[:40]!r}")
            if not body_bytes.startswith(b"RESP "):
                writer.write(http_response(400, "text/plain", b"bad RESP frame"))
                await writer.drain()
                return
            head_line, _, payload = body_bytes.partition(b"\n")
            toks = head_line.decode(errors="replace").split(" ")
            rid = toks[1] if len(toks) > 1 else ""
            status_s = toks[2] if len(toks) > 2 else "200"
            ctype = (toks[3] if len(toks) > 3 else "text/plain").split(";")[0].strip() or "application/octet-stream"
            if len(toks) > 4 and toks[4] == "B64":
                try:
                    payload = base64.b64decode(payload)
                except Exception:
                    log.warning(f"bad b64 payload for {rid}")
                    payload = b""
            state.complete(rid, int(status_s) if status_s.isdigit() else 200, ctype, payload)
            log.info(f"[dbg] completed {rid} status={status_s} bytes={len(payload)}")
            log.debug(f"respond {rid} <- {nid} ({len(payload)}B)")
            writer.write(http_response(200, "text/plain", b"ok"))
            await writer.drain()
            return

        # ── debug scratch: device posts state for host-side tests ────────
        if method == "POST" and len(parts) == 2 and parts[0] == "note":
            body_bytes = await read_body(reader, headers)
            state.notes[parts[1]] = body_bytes[:65536]
            writer.write(http_response(200, "text/plain", b"ok"))
            await writer.drain()
            return

        if method == "GET" and len(parts) == 2 and parts[0] == "note":
            val = state.notes.get(parts[1])
            if val is None:
                writer.write(http_response(404, "text/plain", b"no note"))
            else:
                writer.write(http_response(200, "application/octet-stream", val))
            await writer.drain()
            return

        # ── fetcher: forward through tunnel ──────────────────────────────
        if len(parts) >= 2 and parts[0] == "f":
            nid, subpath = parts[1], "/" + "/".join(parts[2:])
            body_bytes = await read_body(reader, headers)
            rid = state.new_request(nid, method, subpath)
            log.info(f"fetch {method} {subpath} -> {nid} ({rid})")
            log.debug(f"[dbg] waiter armed for {rid}")
            resp = await state.wait_response(rid, FETCH_TIMEOUT)
            if resp is None:
                who = state.nodes.get(nid)
                offline = not who or time.time() - who.last_seen > POLL_DEFAULT_WAIT * 4
                if offline:
                    seen_ago = int(time.time() - who.last_seen) if who else -1
                    msg = "node %s offline (last seen %ss ago)" % (nid, seen_ago)
                    code = 502
                else:
                    msg = "device did not answer in time"
                    code = 408
                writer.write(http_response(code, "text/plain", msg.encode()))
            else:
                status, ctype, payload = resp
                state.node(nid).served += 1
                writer.write(http_response(status, ctype, payload))
            await writer.drain()
            return

        # ── fetcher: presence check ──────────────────────────────────────
        if method == "GET" and len(parts) == 2 and parts[0] == "who":
            nid = parts[1]
            who = state.nodes.get(nid)
            delta = int(time.time() - who.last_seen) if who else -1
            online = bool(who) and delta < POLL_DEFAULT_WAIT * 2
            writer.write(http_response(
                200, "application/json",
                f'{{"node":"{nid}","online":{str(online).lower()},"last_seen_ago":{delta}}}').encode())
            await writer.drain()
            return

        writer.write(http_response(404, "text/plain", b"unknown route"))
        await writer.drain()

    except asyncio.IncompleteReadError as e:
        log.warning(f"[dbg] incomplete read: {e!r} partial={getattr(e,'partial',b'')!r}")
    except (asyncio.TimeoutError, ConnectionResetError):
        pass
    except ValueError as e:
        try:
            writer.write(http_response(413, "text/plain", str(e).encode()))
            await writer.drain()
        except Exception:
            pass
    except Exception as e:
        log.warning(f"handler error from {peer}: {e}")
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def main():
    ap = argparse.ArgumentParser(description="AgentoNet relay (blind pipe)")
    ap.add_argument("--port", type=int, default=7075)
    ap.add_argument("--host", default="127.0.0.1")
    args = ap.parse_args()

    server = await asyncio.start_server(handle, args.host, args.port)
    log.info(f"AgentoNet relay listening on {args.host}:{args.port}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
