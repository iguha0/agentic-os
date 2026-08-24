#!/usr/bin/env python3
"""
AgentoNet DHT Search Node
=========================
A lightweight distributed index for public content.
Stores METADATA ONLY — never files, never private content.

Each record is:  { cid, node_id, relay_url, title, type, size_kb, tags, published, sig }
Records gossip between nodes. Expire after 30 days.
Search fans out to N peers and collects results.

Self-hostable. Bootstrap nodes run by the project.
Anyone can run this to strengthen the network.

Usage:
  python3 dht-node.py --port 8889 --bootstrap dht1.agentos.dev:8889
"""

import asyncio
import json
import time
import hashlib
import logging
import argparse
from collections import OrderedDict

log = logging.getLogger('dht')
logging.basicConfig(level=logging.INFO, format='%(asctime)s [dht] %(message)s')

MAX_RECORDS  = 50_000          # max records this node stores
RECORD_TTL   = 30 * 86400      # 30 days in seconds
GOSSIP_PEERS = 3               # fan-out for gossip
SEARCH_PEERS = 5               # fan-out for search queries


# ── Record Store ──────────────────────────────────────────────────────────────

class RecordStore:
    """In-memory store with LRU eviction and TTL expiry."""

    def __init__(self, max_records: int = MAX_RECORDS):
        self._records = OrderedDict()   # cid → record dict
        self._max     = max_records

    def put(self, record: dict) -> bool:
        """Store a record. Returns True if accepted, False if rejected."""
        cid = record.get("cid", "")
        if not cid or len(cid) > 128:
            return False

        # Validate required fields
        required = ("cid", "node_id", "relay_url", "title", "published")
        if not all(k in record for k in required):
            return False

        # Reject expired records
        if time.time() - record["published"] > RECORD_TTL:
            return False

        # Reject future timestamps (clock skew tolerance: 5 min)
        if record["published"] > time.time() + 300:
            return False

        # LRU eviction
        if len(self._records) >= self._max:
            self._records.popitem(last=False)

        self._records[cid] = record
        self._records.move_to_end(cid)
        return True

    def get(self, cid: str):
        return self._records.get(cid)

    def search(self, query: str, type_filter: str = None, limit: int = 20) -> list:
        """
        Simple keyword search over titles and tags.
        In production: TF-IDF or embeddings-based semantic search.
        """
        results = []
        query_terms = query.lower().split()
        now = time.time()

        for cid, rec in reversed(self._records.items()):
            # Skip expired
            if now - rec["published"] > RECORD_TTL:
                continue

            # Type filter
            if type_filter and not rec.get("type", "").startswith(type_filter):
                continue

            # Score: count term matches in title + tags (tags may be csv string or list)
            tags = rec.get("tags", [])
            if isinstance(tags, str):
                tags = [t for t in tags.split(",") if t]
            text = (rec.get("title", "") + " " + " ".join(tags)).lower()
            score = sum(1 for term in query_terms if term in text)
            if score > 0:
                results.append((score, rec))

        # Sort by score desc, then by recency
        results.sort(key=lambda x: (-x[0], -x[1]["published"]))
        return [r for _, r in results[:limit]]

    def count(self) -> int:
        return len(self._records)

    def all_records(self) -> list:
        """Return all non-expired records (for gossip)."""
        now = time.time()
        return [r for r in self._records.values()
                if now - r["published"] <= RECORD_TTL]


store = RecordStore()


# ── Peer Registry ─────────────────────────────────────────────────────────────

class PeerRegistry:
    def __init__(self):
        self._peers = {}    # "host:port" → last_seen

    def add(self, host: str, port: int):
        key = f"{host}:{port}"
        self._peers[key] = time.time()

    def get_peers(self, n: int = 10) -> list:
        # Return n most recently seen peers
        sorted_peers = sorted(self._peers.items(), key=lambda x: -x[1])
        return [p[0] for p in sorted_peers[:n]]

    def count(self) -> int:
        return len(self._peers)


peers = PeerRegistry()


# ── HTTP API ──────────────────────────────────────────────────────────────────

async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    peer_addr = writer.get_extra_info('peername')
    try:
        raw = b""
        while True:
            line = await asyncio.wait_for(reader.readline(), timeout=5.0)
            raw += line
            if line in (b"\r\n", b"\n", b""):
                break

        text = raw.decode('utf-8', errors='replace')
        first = text.split('\n')[0].strip()
        parts = first.split(' ')
        if len(parts) < 2:
            return

        method, path = parts[0], parts[1].split('?')[0]
        query_string = parts[1].split('?')[1] if '?' in parts[1] else ""

        # Read body
        body = b""
        for line in text.split('\r\n'):
            if line.lower().startswith('content-length:'):
                blen = int(line.split(':')[1].strip())
                body = await asyncio.wait_for(reader.read(min(blen, 65536)), timeout=5.0)
                break

        # Register peer
        if peer_addr:
            peers.add(peer_addr[0], peer_addr[1])

        # ── Routes ──────────────────────────────────────────────────────────

        # POST /publish — accept a new share record
        if method == "POST" and path == "/publish":
            try:
                record = json.loads(body)
            except json.JSONDecodeError:
                await respond(writer, 400, {"error": "invalid JSON"})
                return

            if store.put(record):
                # Gossip to peers asynchronously
                asyncio.create_task(gossip_record(record))
                await respond(writer, 200, {"status": "accepted", "cid": record.get("cid")})
            else:
                await respond(writer, 400, {"error": "record rejected"})
            return

        # GET /search?q=...&type=...&limit=...
        if method == "GET" and path == "/search":
            params = {}
            for kv in query_string.split('&'):
                if '=' in kv:
                    k, v = kv.split('=', 1)
                    params[k] = v.replace('+', ' ')

            q     = params.get('q', '').strip()
            ftype = params.get('type', None)
            limit = min(int(params.get('limit', 20)), 100)

            if not q:
                await respond(writer, 400, {"error": "q required"})
                return

            results = store.search(q, type_filter=ftype, limit=limit)
            await respond(writer, 200, {"results": results, "count": len(results)})
            return

        # GET /record/<cid>
        if method == "GET" and path.startswith("/record/"):
            cid = path[8:]
            rec = store.get(cid)
            if rec:
                await respond(writer, 200, rec)
            else:
                await respond(writer, 404, {"error": "not found"})
            return

        # GET /status
        if method == "GET" and path in ("/status", "/health"):
            await respond(writer, 200, {
                "status":  "ok",
                "records": store.count(),
                "peers":   peers.count(),
                "time":    int(time.time()),
            })
            return

        # POST /gossip — receive gossiped records from another node
        if method == "POST" and path == "/gossip":
            try:
                batch = json.loads(body)
                if isinstance(batch, list):
                    accepted = sum(1 for r in batch if store.put(r))
                    await respond(writer, 200, {"accepted": accepted})
                else:
                    await respond(writer, 400, {"error": "expected array"})
            except json.JSONDecodeError:
                await respond(writer, 400, {"error": "invalid JSON"})
            return

        # GET /peers — return known peers (for bootstrapping)
        if method == "GET" and path == "/peers":
            await respond(writer, 200, {"peers": peers.get_peers(20)})
            return

        await respond(writer, 404, {"error": "not found"})

    except asyncio.TimeoutError:
        pass
    except Exception as e:
        log.debug(f"handler error: {e}")
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


async def respond(writer, status: int, data: dict):
    body = json.dumps(data, indent=2).encode()
    status_text = {200: "OK", 400: "Bad Request", 404: "Not Found"}.get(status, "Unknown")
    resp = (
        f"HTTP/1.1 {status} {status_text}\r\n"
        f"Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Access-Control-Allow-Origin: *\r\n"
        f"\r\n"
    ).encode() + body
    writer.write(resp)
    await writer.drain()


# ── Gossip ────────────────────────────────────────────────────────────────────

async def gossip_record(record: dict):
    """Spread a new record to GOSSIP_PEERS random peers."""
    peer_list = peers.get_peers(GOSSIP_PEERS)
    for peer in peer_list:
        host, port = peer.rsplit(':', 1)
        try:
            await push_to_peer(host, int(port), [record])
        except Exception:
            pass


async def push_to_peer(host: str, port: int, records: list):
    """POST a batch of records to a peer's /gossip endpoint."""
    body = json.dumps(records).encode()
    req  = (
        f"POST /gossip HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"\r\n"
    ).encode() + body

    r, w = await asyncio.wait_for(
        asyncio.open_connection(host, port), timeout=5.0)
    w.write(req)
    await w.drain()
    await asyncio.wait_for(r.readline(), timeout=3.0)
    w.close()


async def periodic_gossip():
    """Every 5 minutes, share all records with a few peers."""
    while True:
        await asyncio.sleep(300)
        all_recs = store.all_records()
        if not all_recs:
            continue
        for peer in peers.get_peers(3):
            host, port = peer.rsplit(':', 1)
            try:
                await push_to_peer(host, int(port), all_recs[:500])
                log.debug(f"gossiped {min(len(all_recs), 500)} records to {peer}")
            except Exception:
                pass


async def bootstrap(bootstrap_hosts: list):
    """Fetch peers from bootstrap nodes on startup."""
    for addr in bootstrap_hosts:
        host, port = addr.rsplit(':', 1)
        try:
            req = f"GET /peers HTTP/1.1\r\nHost: {host}\r\n\r\n".encode()
            r, w = await asyncio.wait_for(
                asyncio.open_connection(host, int(port)), timeout=5.0)
            w.write(req)
            await w.drain()
            # Skip HTTP headers
            while True:
                line = await asyncio.wait_for(r.readline(), timeout=3.0)
                if line in (b"\r\n", b"\n"):
                    break
            body = await asyncio.wait_for(r.read(4096), timeout=3.0)
            w.close()
            data = json.loads(body)
            for peer in data.get("peers", []):
                h, p = peer.rsplit(':', 1)
                peers.add(h, int(p))
            log.info(f"bootstrapped from {addr}: {len(data.get('peers', []))} peers")
        except Exception as e:
            log.debug(f"bootstrap {addr} failed: {e}")


# ── Main ──────────────────────────────────────────────────────────────────────

async def main(host: str, port: int, bootstrap_hosts: list):
    if bootstrap_hosts:
        await bootstrap(bootstrap_hosts)

    server = await asyncio.start_server(handle, host, port)
    asyncio.create_task(periodic_gossip())
    log.info(f"AgentoNet DHT node listening on {host}:{port}")
    log.info(f"Records: {store.count()} | Peers: {peers.count()}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="AgentoNet DHT Node")
    parser.add_argument("--host",      default="0.0.0.0")
    parser.add_argument("--port",      default=8889, type=int)
    parser.add_argument("--bootstrap", default="", help="Comma-separated host:port bootstrap nodes")
    args = parser.parse_args()

    bootstrap_list = [b.strip() for b in args.bootstrap.split(',') if b.strip()]
    asyncio.run(main(args.host, args.port, bootstrap_list))
