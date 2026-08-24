#!/bin/sh
# distributed-search.sh — Agentic OS distributed node search engine
#
# How it works:
#   1. Each node maintains a local index of its content (files, shares, certs, notes)
#   2. On "publish", it signs a Nostr catalog event (kind 30100) and sends to relays
#   3. On "search <query>", it searches locally AND queries Nostr relays for matching
#      catalog events from other nodes
#   4. Results show node ID, content name, type, hash, and how to fetch
#
# Depends on: nostr-publish.sh, gen-identity.sh (already in initramfs)
# Install to: /usr/local/bin/distributed-search.sh

AGENTIC_DIR="/usr/share/agentic"
SEARCH_DIR="$AGENTIC_DIR/search"
INDEX_FILE="$SEARCH_DIR/local-index.json"
CATALOG_FILE="$SEARCH_DIR/catalog.jsonl"    # other nodes' catalogs
RELAY_CACHE="$SEARCH_DIR/relay-cache.jsonl" # raw relay events
NODE_ID_FILE="$AGENTIC_DIR/identity/node.id"
SIGN_KEY_FILE="$AGENTIC_DIR/identity/node.key"

# Nostr relays to query
RELAYS="wss://relay.damus.io wss://nos.lol wss://relay.nostr.band"

# Nostr kind for Agentic OS catalog events (30100 = addressable, one-per-node)
CATALOG_KIND=30100
# Kind for individual content announcements
CONTENT_KIND=30101

mkdir -p "$SEARCH_DIR"

# ── Helpers ───────────────────────────────────────────────────────────────────

log()  { echo "[search] $*" >&2; }
ts()   { date +%s; }
sha256() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
sha256str() { printf '%s' "$1" | sha256sum 2>/dev/null | cut -d' ' -f1; }

node_id() {
    cat "$NODE_ID_FILE" 2>/dev/null || echo "unknown-$(hostname)"
}

# Sign a string with our ed25519 key (using openssl if available)
sign_hex() {
    msg="$1"
    key="$SIGN_KEY_FILE"
    if [ ! -f "$key" ]; then echo ""; return; fi
    # Try openssl pkeyutl
    if command -v openssl >/dev/null 2>&1; then
        printf '%s' "$msg" | openssl dgst -sha256 -sign "$key" 2>/dev/null | \
            od -A n -t x1 | tr -d ' \n'
    else
        # Fallback: use sha256 of msg+key as a deterministic pseudo-sig
        sha256str "$(cat $key 2>/dev/null)$msg"
    fi
}

# Simple JSON string escape
json_esc() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n'
}

# ── Index a single file/item ──────────────────────────────────────────────────
index_item() {
    path="$1"
    type="$2"   # file | share | cert | note
    name="$3"
    desc="$4"

    [ -z "$path" ] && return

    if [ -f "$path" ]; then
        hash=$(sha256 "$path")
        size=$(stat -c %s "$path" 2>/dev/null || echo 0)
    else
        hash=$(sha256str "$path")
        size=0
    fi

    timestamp=$(ts)
    nid=$(node_id)

    printf '{"ts":%s,"node":"%s","type":"%s","name":"%s","path":"%s","hash":"%s","size":%s,"desc":"%s"}\n' \
        "$timestamp" "$nid" "$type" "$(json_esc "$name")" \
        "$(json_esc "$path")" "$hash" "$size" "$(json_esc "$desc")" \
        >> "$INDEX_FILE"

    echo "$hash"
}

# ── Scan local content and build index ───────────────────────────────────────
cmd_index() {
    log "scanning local content..."
    # Clear old index
    : > "$INDEX_FILE"

    nid=$(node_id)
    count=0

    # 1. Shared files in agentic share directory
    if [ -d "$AGENTIC_DIR/shares" ]; then
        for f in "$AGENTIC_DIR/shares"/*; do
            [ -f "$f" ] || continue
            name=$(basename "$f")
            index_item "$f" "share" "$name" "Shared file" > /dev/null
            count=$((count+1))
        done
    fi

    # 2. Certified files
    if [ -d "$AGENTIC_DIR/certs" ]; then
        for cert in "$AGENTIC_DIR/certs"/*.cert; do
            [ -f "$cert" ] || continue
            name=$(basename "$cert" .cert)
            # Read original file path from cert
            orig=$(grep "^FILE:" "$cert" 2>/dev/null | head -1 | cut -d: -f2-)
            index_item "$orig" "cert" "$name" "Certified content" > /dev/null
            count=$((count+1))
        done
    fi

    # 3. Notes (each note as a searchable item)
    if [ -f "$AGENTIC_DIR/notes.txt" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            hash=$(sha256str "$line")
            timestamp=$(ts)
            printf '{"ts":%s,"node":"%s","type":"note","name":"note-%s","path":"notes.txt","hash":"%s","size":%s,"desc":"%s"}\n' \
                "$timestamp" "$nid" "$hash" "$hash" "${#line}" "$(json_esc "${line%${line#?????????}}")" \
                >> "$INDEX_FILE"
            count=$((count+1))
        done < "$AGENTIC_DIR/notes.txt"
    fi

    # 4. Memory entries
    if [ -f "$AGENTIC_DIR/memory.txt" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            hash=$(sha256str "$line")
            timestamp=$(ts)
            printf '{"ts":%s,"node":"%s","type":"memory","name":"mem-%s","path":"memory.txt","hash":"%s","size":%s,"desc":"%s"}\n' \
                "$timestamp" "$nid" "$hash" "$hash" "${#line}" "$(json_esc "${line%${line#?????????}}")" \
                >> "$INDEX_FILE"
            count=$((count+1))
        done < "$AGENTIC_DIR/memory.txt"
    fi

    # 5. User tools
    if [ -d "$AGENTIC_DIR/tools" ]; then
        for tool in "$AGENTIC_DIR/tools"/*.sh; do
            [ -f "$tool" ] || continue
            name=$(basename "$tool" .sh)
            index_item "$tool" "tool" "$name" "Custom AI tool" > /dev/null
            count=$((count+1))
        done
    fi

    log "indexed $count items from node $nid"
    echo "$count"
}

# ── Publish catalog to Nostr ─────────────────────────────────────────────────
cmd_publish() {
    [ ! -f "$INDEX_FILE" ] && cmd_index > /dev/null

    nid=$(node_id)
    count=$(wc -l < "$INDEX_FILE" 2>/dev/null || echo 0)
    timestamp=$(ts)

    # Build summary of content types
    files=$(grep -c '"type":"share"'  "$INDEX_FILE" 2>/dev/null || echo 0)
    certs=$(grep -c '"type":"cert"'   "$INDEX_FILE" 2>/dev/null || echo 0)
    notes=$(grep -c '"type":"note"'   "$INDEX_FILE" 2>/dev/null || echo 0)
    tools=$(grep -c '"type":"tool"'   "$INDEX_FILE" 2>/dev/null || echo 0)

    # Build Nostr event content
    content=$(printf '{"node":"%s","ts":%s,"items":%s,"shares":%s,"certs":%s,"notes":%s,"tools":%s,"version":"1"}' \
        "$nid" "$timestamp" "$count" "$files" "$certs" "$notes" "$tools")

    # Compute event ID: sha256 of canonical serialization
    serial=$(printf '[0,"%s",%s,%s,[["d","%s"],["t","agentic-os"]],"%s"]' \
        "$nid" "$timestamp" "$CATALOG_KIND" "$nid" "$(json_esc "$content")")
    event_id=$(sha256str "$serial")

    # Sign
    sig=$(sign_hex "$event_id")

    # Build Nostr event JSON
    event=$(printf '{"id":"%s","pubkey":"%s","created_at":%s,"kind":%s,"tags":[["d","%s"],["t","agentic-os"],["shares","%s"],["certs","%s"],["notes","%s"]],"content":"%s","sig":"%s"}' \
        "$event_id" "$nid" "$timestamp" "$CATALOG_KIND" \
        "$nid" "$files" "$certs" "$notes" \
        "$(json_esc "$content")" "${sig:-0000}")

    log "publishing catalog to Nostr (node=$nid, items=$count)..."

    # Write to Nostr queue
    mkdir -p "$AGENTIC_DIR/nostr"
    echo "$event" >> "$AGENTIC_DIR/nostr/queue.jsonl"

    # Try to flush via ws client
    if command -v python3 >/dev/null 2>&1 && [ -f "/usr/local/bin/nostr-ws.py" ]; then
        python3 /usr/local/bin/nostr-ws.py flush 2>/dev/null && \
            log "published to Nostr relays" || \
            log "queued (will publish when network available)"
    else
        log "queued for publish (no python3 or nostr-ws.py)"
    fi

    # Also publish individual content items (first 20 to avoid flooding)
    n=0
    while IFS= read -r item && [ $n -lt 20 ]; do
        itype=$(printf '%s' "$item" | grep -o '"type":"[^"]*"' | cut -d'"' -f4)
        iname=$(printf '%s' "$item" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
        ihash=$(printf '%s' "$item" | grep -o '"hash":"[^"]*"' | cut -d'"' -f4)
        idesc=$(printf '%s' "$item" | grep -o '"desc":"[^"]*"' | cut -d'"' -f4)

        cts=$(ts)
        cevent_id=$(sha256str "${nid}${cts}${ihash}")
        cevent=$(printf '{"id":"%s","pubkey":"%s","created_at":%s,"kind":%s,"tags":[["d","%s"],["t","agentic-os"],["t","%s"],["hash","%s"]],"content":"%s","sig":"%s"}' \
            "$cevent_id" "$nid" "$cts" "$CONTENT_KIND" \
            "$ihash" "$itype" "$ihash" \
            "$(json_esc "{\"name\":\"$iname\",\"type\":\"$itype\",\"hash\":\"$ihash\",\"desc\":\"$idesc\",\"node\":\"$nid\"}")" \
            "${sig:-0000}")
        echo "$cevent" >> "$AGENTIC_DIR/nostr/queue.jsonl"
        n=$((n+1))
    done < "$INDEX_FILE"

    log "queued $n content announcements"
    echo "Published: $count items ($files shares, $certs certs, $notes notes, $tools tools)"
}

# ── Search local index ────────────────────────────────────────────────────────
search_local() {
    query="$1"
    [ ! -f "$INDEX_FILE" ] && return

    # Case-insensitive grep on the JSON
    grep -i "$query" "$INDEX_FILE" 2>/dev/null | while IFS= read -r line; do
        itype=$(printf '%s' "$line" | grep -o '"type":"[^"]*"' | cut -d'"' -f4)
        iname=$(printf '%s' "$line" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
        ihash=$(printf '%s' "$line" | grep -o '"hash":"[^"]*"' | cut -d'"' -f4)
        ipath=$(printf '%s' "$line" | grep -o '"path":"[^"]*"' | cut -d'"' -f4)
        isize=$(printf '%s' "$line" | grep -o '"size":[0-9]*' | cut -d: -f2)
        idesc=$(printf '%s' "$line" | grep -o '"desc":"[^"]*"' | cut -d'"' -f4)
        inode=$(printf '%s' "$line" | grep -o '"node":"[^"]*"' | cut -d'"' -f4)
        printf "  [LOCAL] %-8s %-30s %s bytes  node=%s\n" \
            "$itype" "$iname" "$isize" "${inode:-self}"
        printf "          hash=%s\n" "$ihash"
        [ -n "$idesc" ] && printf "          %s\n" "$idesc"
    done
}

# ── Query Nostr relays for other nodes' content ───────────────────────────────
search_nostr() {
    query="$1"

    # Build a Nostr REQ filter for agentic-os tagged events
    filter=$(printf '{"kinds":[%s,%s],"#t":["agentic-os"],"limit":50}' \
        "$CATALOG_KIND" "$CONTENT_KIND")

    req=$(printf '["REQ","search-%s",%s]' "$(ts)" "$filter")

    # Try to fetch via python3 WebSocket client
    if command -v python3 >/dev/null 2>&1 && [ -f "/usr/local/bin/nostr-ws.py" ]; then
        # Write a temporary query script
        tmp_script="/tmp/nostr-query-$$.py"
        cat > "$tmp_script" << 'PYEOF'
import sys, json, socket, ssl, hashlib, base64, os, time

RELAYS = [
    ("relay.damus.io",     443, True),
    ("nos.lol",            443, True),
    ("relay.nostr.band",   443, True),
]

def ws_handshake(sock, host):
    key = base64.b64encode(os.urandom(16)).decode()
    req = (f"GET / HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
           f"Sec-WebSocket-Version: 13\r\n\r\n")
    sock.send(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        resp += sock.recv(1024)
    return b"101" in resp

def ws_send(sock, msg):
    data = msg.encode()
    n = len(data)
    mask = os.urandom(4)
    header = b'\x81'
    if n < 126:
        header += bytes([0x80 | n])
    else:
        header += bytes([0x80 | 126, n >> 8, n & 0xff])
    header += mask
    masked = bytes(data[i] ^ mask[i % 4] for i in range(n))
    sock.send(header + masked)

def ws_recv(sock, timeout=5):
    sock.settimeout(timeout)
    results = []
    deadline = time.time() + timeout
    try:
        while time.time() < deadline:
            b = sock.recv(2)
            if not b: break
            fin = b[0] & 0x80
            opcode = b[0] & 0x0f
            mask_bit = b[1] & 0x80
            length = b[1] & 0x7f
            if length == 126:
                length = int.from_bytes(sock.recv(2), 'big')
            elif length == 127:
                length = int.from_bytes(sock.recv(8), 'big')
            payload = b""
            while len(payload) < length:
                chunk = sock.recv(min(4096, length - len(payload)))
                if not chunk: break
                payload += chunk
            if opcode == 8: break
            try:
                msg = json.loads(payload.decode())
                if isinstance(msg, list) and msg[0] == "EVENT":
                    results.append(msg[2])
                elif isinstance(msg, list) and msg[0] == "EOSE":
                    break
            except: pass
    except: pass
    return results

query = sys.argv[1] if len(sys.argv) > 1 else ""
filter_str = '{"kinds":[30100,30101],"#t":["agentic-os"],"limit":50}'
req_msg = f'["REQ","q1",{filter_str}]'

all_events = []
for host, port, use_ssl in RELAYS:
    try:
        raw = socket.create_connection((host, port), timeout=5)
        if use_ssl:
            ctx = ssl.create_default_context()
            sock = ctx.wrap_socket(raw, server_hostname=host)
        else:
            sock = raw
        if ws_handshake(sock, host):
            ws_send(sock, req_msg)
            events = ws_recv(sock, timeout=4)
            all_events.extend(events)
            sock.close()
    except Exception as e:
        pass

seen_nodes = set()
for ev in all_events:
    try:
        content = json.loads(ev.get("content", "{}"))
        node = content.get("node", ev.get("pubkey", "?"))
        if node in seen_nodes: continue
        seen_nodes.add(node)
        # Match query
        ev_str = json.dumps(ev).lower()
        if query and query.lower() not in ev_str:
            continue
        kind = ev.get("kind", 0)
        if kind == 30100:
            # Catalog event
            items  = content.get("items", "?")
            shares = content.get("shares", 0)
            certs  = content.get("certs", 0)
            notes  = content.get("notes", 0)
            tools  = content.get("tools", 0)
            print(f"  [NODE]  {node[:16]}...  items={items}  shares={shares} certs={certs} notes={notes} tools={tools}")
        elif kind == 30101:
            iname = content.get("name", "?")
            itype = content.get("type", "?")
            ihash = content.get("hash", "?")
            idesc = content.get("desc", "")
            print(f"  [REMOTE] {itype:<8} {iname:<30} node={node[:12]}")
            print(f"           hash={ihash}")
            if idesc: print(f"           {idesc}")
    except:
        pass

if not all_events:
    print("  (no results from relays — check network or try again later)")
PYEOF
        python3 "$tmp_script" "$query" 2>/dev/null
        rm -f "$tmp_script"
    else
        # Fallback: search cached relay data
        if [ -f "$CATALOG_FILE" ]; then
            grep -i "$query" "$CATALOG_FILE" 2>/dev/null | head -10 | while IFS= read -r line; do
                node=$(printf '%s' "$line" | grep -o '"node":"[^"]*"' | cut -d'"' -f4)
                items=$(printf '%s' "$line" | grep -o '"items":[0-9]*' | cut -d: -f2)
                printf "  [CACHED] node=%-20s items=%s\n" "$node" "$items"
            done
        else
            echo "  (python3 not available — install for live relay search)"
        fi
    fi
}

# ── Main search command ───────────────────────────────────────────────────────
cmd_search() {
    query="$1"
    [ -z "$query" ] && { echo "Usage: search <query>"; exit 1; }

    nid=$(node_id)
    echo "══════════════════════════════════════════════════"
    echo "  Agentic OS — Distributed Search"
    echo "  Query: \"$query\""
    echo "  Node:  ${nid:-unknown}"
    echo "══════════════════════════════════════════════════"
    echo ""

    echo "── Local results ──────────────────────────────────"
    local_results=$(search_local "$query")
    if [ -n "$local_results" ]; then
        echo "$local_results"
    else
        echo "  (no local matches)"
    fi
    echo ""

    echo "── Network results (Nostr relays) ─────────────────"
    search_nostr "$query"
    echo ""
    echo "══════════════════════════════════════════════════"
}

# ── Show this node's catalog ──────────────────────────────────────────────────
cmd_catalog() {
    nid=$(node_id)
    echo "Node: $nid"
    echo ""
    if [ ! -f "$INDEX_FILE" ]; then
        echo "No index yet. Run: distributed-search.sh index"
        return
    fi
    total=$(wc -l < "$INDEX_FILE")
    echo "Total items: $total"
    echo ""
    printf "%-8s %-32s %s\n" "TYPE" "NAME" "HASH"
    printf "%-8s %-32s %s\n" "────" "────────────────────────────────" "────────"
    while IFS= read -r line; do
        itype=$(printf '%s' "$line" | grep -o '"type":"[^"]*"' | cut -d'"' -f4)
        iname=$(printf '%s' "$line" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
        ihash=$(printf '%s' "$line" | grep -o '"hash":"[^"]*"' | cut -d'"' -f4)
        printf "%-8s %-32s %.16s...\n" "$itype" "$iname" "$ihash"
    done < "$INDEX_FILE"
}

# ── Discover active nodes on Nostr ────────────────────────────────────────────
cmd_discover() {
    echo "Querying Nostr relays for active Agentic OS nodes..."
    echo ""
    search_nostr ""
}

# ── Fetch content from a remote node ─────────────────────────────────────────
cmd_fetch() {
    hash="$1"
    [ -z "$hash" ] && { echo "Usage: distributed-search.sh fetch <hash>"; exit 1; }

    # Check local first
    if [ -f "$INDEX_FILE" ]; then
        line=$(grep "\"hash\":\"$hash\"" "$INDEX_FILE" 2>/dev/null | head -1)
        if [ -n "$line" ]; then
            path=$(printf '%s' "$line" | grep -o '"path":"[^"]*"' | cut -d'"' -f4)
            echo "Found locally: $path"
            return
        fi
    fi

    # Would need to contact the remote node via AgentoNet
    echo "Content not found locally."
    echo "To fetch from a remote node:"
    echo "  agentic-shared.sh fetch $hash"
}

# ── Auto-index and publish (run periodically) ─────────────────────────────────
cmd_sync() {
    log "starting sync..."
    cmd_index > /dev/null
    cmd_publish
    log "sync complete"
}

# ── Entry point ───────────────────────────────────────────────────────────────
CMD="${1:-help}"
shift 2>/dev/null

case "$CMD" in
    index)    cmd_index ;;
    publish)  cmd_publish ;;
    search)   cmd_search "$1" ;;
    catalog)  cmd_catalog ;;
    discover) cmd_discover ;;
    fetch)    cmd_fetch "$1" ;;
    sync)     cmd_sync ;;
    help|*)
        cat << 'HELP'
distributed-search.sh — Agentic OS node discovery & content search

Commands:
  index              Scan local content (shares, certs, notes, tools) and build index
  publish            Sign and publish your catalog to Nostr relays
  sync               Index + publish in one step (run at boot or on a timer)
  search <query>     Search local index + live query Nostr relays for other nodes
  catalog            Show what this node has indexed
  discover           List all active Agentic OS nodes found on Nostr
  fetch <hash>       Locate content by hash (local first, then remote)

How nodes find each other:
  - Each node publishes a signed Nostr event (kind 30100) with its catalog
  - Content items are announced as kind 30101 events
  - All events tagged with ["t","agentic-os"] for relay filtering
  - search/discover queries relay.damus.io, nos.lol, relay.nostr.band

Examples:
  distributed-search.sh sync
  distributed-search.sh search "climate data"
  distributed-search.sh discover
  distributed-search.sh fetch abc123def456...
HELP
        ;;
esac
