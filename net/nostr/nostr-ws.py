#!/usr/bin/env python3
"""
nostr-ws.py — Nostr WebSocket publisher for Agentic OS

Publishes signed Nostr events to relays via real WebSocket connections.
This companion to nostr-publish.sh handles the actual ws:// transport
that shell/wget can't do natively.

Usage:
  nostr-ws.py publish <event_json>
  nostr-ws.py flush   — send all events in /usr/share/agentic/nostr/queue.jsonl
  nostr-ws.py status  — test relay connectivity

Relays:
  wss://relay.damus.io
  wss://nos.lol
  wss://relay.nostr.band
"""

import sys
import json
import ssl
import socket
import struct
import hashlib
import base64
import os
import time

NOSTR_DIR = "/usr/share/agentic/nostr"
QUEUE_FILE = os.path.join(NOSTR_DIR, "queue.jsonl")
PUBLISHED_FILE = os.path.join(NOSTR_DIR, "published.jsonl")
FAILED_FILE = os.path.join(NOSTR_DIR, "failed.jsonl")

RELAYS = [
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.nostr.band",
    "wss://nostr.wine",
]

# ── Minimal WebSocket client (no external deps) ────────────────────────────────

def ws_handshake_key():
    """Generate a random WebSocket key."""
    raw = os.urandom(16)
    return base64.b64encode(raw).decode()

def ws_connect(url, timeout=10):
    """Connect to a ws:// or wss:// URL. Returns (sock, ssl_sock)."""
    if url.startswith("wss://"):
        scheme = "wss"
        url_rest = url[6:]
    elif url.startswith("ws://"):
        scheme = "ws"
        url_rest = url[5:]
    else:
        raise ValueError(f"unsupported scheme: {url}")

    if "/" in url_rest:
        host, path = url_rest.split("/", 1)
        path = "/" + path
    else:
        host = url_rest
        path = "/"

    port = 443 if scheme == "wss" else 80
    if ":" in host:
        host, port_s = host.rsplit(":", 1)
        port = int(port_s)

    sock = socket.create_connection((host, port), timeout=timeout)

    if scheme == "wss":
        ctx = ssl.create_default_context()
        conn = ctx.wrap_socket(sock, server_hostname=host)
    else:
        conn = sock

    # WebSocket HTTP upgrade
    key = ws_handshake_key()
    handshake = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n"
        f"\r\n"
    )
    conn.sendall(handshake.encode())

    # Read HTTP response
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = conn.recv(1024)
        if not chunk:
            raise ConnectionError("connection closed during handshake")
        resp += chunk

    header = resp.split(b"\r\n\r\n")[0].decode(errors="replace")
    if "101 Switching Protocols" not in header:
        raise ConnectionError(f"WebSocket upgrade failed:\n{header[:200]}")

    return conn

def ws_send(conn, text):
    """Send a WebSocket text frame."""
    data = text.encode("utf-8")
    length = len(data)
    mask = os.urandom(4)

    header = bytearray([0x81])  # FIN + text opcode

    if length <= 125:
        header.append(0x80 | length)
    elif length <= 65535:
        header.append(0x80 | 126)
        header += struct.pack(">H", length)
    else:
        header.append(0x80 | 127)
        header += struct.pack(">Q", length)

    header += mask

    masked = bytearray(data[i] ^ mask[i % 4] for i in range(length))
    conn.sendall(bytes(header) + bytes(masked))

def ws_recv(conn, timeout=5):
    """Read a WebSocket frame. Returns text or None."""
    conn.settimeout(timeout)
    try:
        raw = conn.recv(2)
        if len(raw) < 2:
            return None
        opcode = raw[0] & 0x0F
        length = raw[1] & 0x7F

        if length == 126:
            raw2 = conn.recv(2)
            length = struct.unpack(">H", raw2)[0]
        elif length == 127:
            raw2 = conn.recv(8)
            length = struct.unpack(">Q", raw2)[0]

        payload = b""
        while len(payload) < length:
            chunk = conn.recv(length - len(payload))
            if not chunk:
                break
            payload += chunk

        if opcode == 1:  # text
            return payload.decode("utf-8", errors="replace")
        elif opcode == 9:  # ping → send pong
            conn.sendall(bytes([0x8A, 0x00]))
            return None
    except (socket.timeout, OSError):
        return None

def ws_close(conn):
    try:
        conn.sendall(bytes([0x88, 0x00]))
        conn.close()
    except Exception:
        pass

# ── Publish event to a single relay ────────────────────────────────────────────

def publish_to_relay(relay_url, event_json, timeout=10):
    """Returns (success: bool, message: str)."""
    try:
        conn = ws_connect(relay_url, timeout=timeout)
    except Exception as e:
        return False, f"connect failed: {e}"

    try:
        msg = json.dumps(["EVENT", event_json])
        ws_send(conn, msg)

        # Wait for OK response
        deadline = time.time() + 5
        while time.time() < deadline:
            resp = ws_recv(conn, timeout=2)
            if resp:
                try:
                    parsed = json.loads(resp)
                    if isinstance(parsed, list) and len(parsed) >= 3:
                        if parsed[0] == "OK":
                            success = bool(parsed[2])
                            msg_text = parsed[3] if len(parsed) > 3 else ""
                            ws_close(conn)
                            return success, msg_text
                        elif parsed[0] == "NOTICE":
                            print(f"  [nostr] notice from {relay_url}: {parsed[1]}", flush=True)
                except json.JSONDecodeError:
                    pass

        ws_close(conn)
        return True, "sent (no OK received)"  # Many relays don't send OK

    except Exception as e:
        ws_close(conn)
        return False, f"send failed: {e}"

# ── Commands ───────────────────────────────────────────────────────────────────

def cmd_publish(event_json_str):
    """Publish a single event JSON string to all relays."""
    try:
        event = json.loads(event_json_str)
    except json.JSONDecodeError as e:
        print(f"[nostr] invalid JSON: {e}")
        return False

    event_id = event.get("id", "?")[:16]
    print(f"[nostr] publishing event {event_id}... ", flush=True)

    published = False
    for relay in RELAYS:
        success, msg = publish_to_relay(relay, event)
        if success:
            print(f"  ✓ {relay}" + (f" ({msg})" if msg else ""))
            published = True
        else:
            print(f"  ✗ {relay}: {msg}")

    return published

def cmd_flush():
    """Send all queued events."""
    os.makedirs(NOSTR_DIR, exist_ok=True)

    if not os.path.exists(QUEUE_FILE):
        print("[nostr] queue is empty")
        return

    with open(QUEUE_FILE, "r") as f:
        events = [line.strip() for line in f if line.strip()]

    if not events:
        print("[nostr] queue is empty")
        return

    print(f"[nostr] flushing {len(events)} event(s)...")
    published = []
    failed = []

    for event_str in events:
        ok = cmd_publish(event_str)
        if ok:
            published.append(event_str)
        else:
            failed.append(event_str)

    # Save results
    if published:
        with open(PUBLISHED_FILE, "a") as f:
            for e in published:
                f.write(e + "\n")

    if failed:
        with open(FAILED_FILE, "a") as f:
            for e in failed:
                f.write(e + "\n")
        print(f"[nostr] {len(failed)} event(s) failed — saved to {FAILED_FILE}")

    # Clear queue (only failed ones stay)
    if failed:
        with open(QUEUE_FILE, "w") as f:
            for e in failed:
                f.write(e + "\n")
    else:
        os.remove(QUEUE_FILE)

    print(f"[nostr] done: {len(published)} published, {len(failed)} failed")

def cmd_status():
    """Check relay connectivity."""
    print("[nostr] checking relay connectivity...")
    for relay in RELAYS:
        try:
            conn = ws_connect(relay, timeout=5)
            ws_close(conn)
            print(f"  ✓ {relay}")
        except Exception as e:
            print(f"  ✗ {relay}: {e}")

    # Queue status
    if os.path.exists(QUEUE_FILE):
        with open(QUEUE_FILE) as f:
            queued = sum(1 for l in f if l.strip())
        print(f"\n  Queued events: {queued}")
    if os.path.exists(PUBLISHED_FILE):
        with open(PUBLISHED_FILE) as f:
            published = sum(1 for l in f if l.strip())
        print(f"  Published:     {published}")

# ── Entry point ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: nostr-ws.py <publish <event_json>|flush|status>")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "publish":
        if len(sys.argv) < 3:
            print("Usage: nostr-ws.py publish '<event_json>'")
            sys.exit(1)
        ok = cmd_publish(sys.argv[2])
        sys.exit(0 if ok else 1)

    elif cmd == "flush":
        cmd_flush()

    elif cmd == "status":
        cmd_status()

    else:
        print(f"unknown command: {cmd}")
        print("Usage: nostr-ws.py <publish|flush|status>")
        sys.exit(1)
